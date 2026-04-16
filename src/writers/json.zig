//! JSON formatter for benchmark results.
//!
//! Supports both streaming (via the `Writer` interface) and batch output.
//! Streaming writes results immediately — no buffering needed since
//! the baseline is always the first result in a group.
const Json = @This();

const std = @import("std");
const IoWriter = std.Io.Writer;
const Result = @import("../result.zig");
const Writer = @import("../writer.zig");
const Report = @import("../report.zig");
const PerfCounter = @import("../perf.zig").PerfCounter;

writer: Writer,
out: *IoWriter,
started: bool = false,
first_group: bool = true,
first_result: bool = true,

const vtable: Writer.VTable = .{
    .startGroup = Json.startGroup,
    .addResult = Json.addResult,
    .endGroup = Json.endGroup,
    .finish = Json.finish,
};

pub fn init(out: *IoWriter) Json {
    return .{
        .writer = .{ .vtable = &vtable },
        .out = out,
    };
}

/// Batch-write a completed report as JSON.
pub fn writeReport(report: *const Report, out: *IoWriter) IoWriter.Error!void {
    try out.writeAll("{\"groups\":[");
    var first_group = true;
    for (report.groups.items) |group| {
        if (!first_group) try out.writeByte(',');
        try writeGroupJson(out, group);
        first_group = false;
    }
    if (report.active_group) |group| {
        if (!first_group) try out.writeByte(',');
        try writeGroupJson(out, group);
    }
    try out.writeAll("]}\n");
}

fn writeGroupJson(out: *IoWriter, group: *const Report.Group) IoWriter.Error!void {
    try out.writeAll("{");
    if (group.name) |n| {
        try out.writeAll("\"name\":");
        try writeJsonString(out, n);
    } else {
        try out.writeAll("\"name\":null");
    }
    try out.writeAll(",\"results\":[");
    for (group.results.items, 0..) |result, i| {
        if (i > 0) try out.writeByte(',');
        try writeResultJson(out, result, group.baseline);
    }
    try out.writeAll("]}");
}

fn writeResultJson(out: *IoWriter, result: Result, baseline: ?Result) IoWriter.Error!void {
    try out.writeAll("{\"name\":");
    try writeJsonString(out, result.name);
    try out.print(",\"mean_ns\":{d:.2}", .{result.mean_ns});
    try out.print(",\"min_ns\":{d:.2}", .{result.min_ns});
    try out.print(",\"max_ns\":{d:.2}", .{result.max_ns});
    try out.print(",\"median_ns\":{d:.2}", .{result.median_ns});
    try out.print(",\"std_ns\":{d:.2}", .{result.std_ns});
    try out.print(",\"iterations\":{d}", .{result.iterations});
    try out.print(",\"samples\":{d}", .{result.samples});

    if (baseline) |b| {
        const is_bl = std.mem.eql(u8, result.name, b.name);
        if (is_bl) {
            try out.writeAll(",\"is_baseline\":true");
        } else {
            const pct = (result.mean_ns - b.mean_ns) / b.mean_ns * 100.0;
            try out.print(",\"vs_baseline_pct\":{d:.1}", .{pct});
        }
    }

    var has_perf = false;
    for (std.enums.values(PerfCounter)) |counter| {
        if (result.perf.get(counter) != null) {
            has_perf = true;
            break;
        }
    }
    if (has_perf) {
        try out.writeAll(",\"perf\":{");
        var first = true;
        for (std.enums.values(PerfCounter)) |counter| {
            if (result.perf.get(counter)) |value| {
                if (!first) try out.writeByte(',');
                try out.print("\"{s}\":{d:.2}", .{ @tagName(counter), value });
                first = false;
            }
        }
        try out.writeByte('}');
    }

    try out.writeByte('}');
}

fn writeJsonString(out: *IoWriter, s: []const u8) IoWriter.Error!void {
    try out.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\t' => try out.writeAll("\\t"),
            else => try out.writeByte(c),
        }
    }
    try out.writeByte('"');
}

// -- Streaming Writer implementation --

fn startGroup(w: *Writer, name: ?[]const u8) Writer.Error!void {
    const self: *Json = @alignCast(@fieldParentPtr("writer", w));
    if (!self.started) {
        self.out.writeAll("{\"groups\":[") catch return error.WriteFailed;
        self.started = true;
    }
    if (!self.first_group) self.out.writeByte(',') catch return error.WriteFailed;
    self.first_group = false;
    self.first_result = true;

    self.out.writeAll("{") catch return error.WriteFailed;
    if (name) |n| {
        self.out.writeAll("\"name\":") catch return error.WriteFailed;
        writeJsonString(self.out, n) catch return error.WriteFailed;
    } else {
        self.out.writeAll("\"name\":null") catch return error.WriteFailed;
    }
    self.out.writeAll(",\"results\":[") catch return error.WriteFailed;
}

fn addResult(w: *Writer, result: Result, baseline: ?Result, is_baseline: bool) Writer.Error!void {
    const self: *Json = @alignCast(@fieldParentPtr("writer", w));
    if (!self.first_result) self.out.writeByte(',') catch return error.WriteFailed;
    self.first_result = false;
    // When this is the baseline, pass the result as its own baseline so
    // writeResultJson emits "is_baseline":true.
    const effective_baseline = if (is_baseline) result else baseline;
    writeResultJson(self.out, result, effective_baseline) catch return error.WriteFailed;
    self.out.flush() catch return error.WriteFailed;
}

fn endGroup(w: *Writer) Writer.Error!void {
    const self: *Json = @alignCast(@fieldParentPtr("writer", w));
    self.out.writeAll("]}") catch return error.WriteFailed;
    self.out.flush() catch return error.WriteFailed;
}

fn finish(w: *Writer) Writer.Error!void {
    const self: *Json = @alignCast(@fieldParentPtr("writer", w));
    if (!self.started) {
        self.out.writeAll("{\"groups\":[") catch return error.WriteFailed;
    }
    self.out.writeAll("]}\n") catch return error.WriteFailed;
    self.out.flush() catch return error.WriteFailed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const PerfCounts = Result.PerfCounts;

fn testResult(name: []const u8, mean_ns: f64) Result {
    return .{
        .name = name,
        .iterations = 1000,
        .samples = 11,
        .min_ns = 1.0,
        .max_ns = 5.0,
        .mean_ns = mean_ns,
        .median_ns = 2.3,
        .std_ns = 0.5,
        .perf = PerfCounts.initFill(null),
    };
}

test "batch: basic json output" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResult("noop", 1.23));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"groups\":["));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"name\":null"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"name\":\"noop\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"mean_ns\":1.23"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"iterations\":1000"));
}

test "batch: named group with baseline" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    const group = try report.addGroup("hashing");
    try group.addBaseline(testResult("sha256", 200.0));
    try group.add(testResult("blake3", 100.0));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"name\":\"hashing\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"is_baseline\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"vs_baseline_pct\":-50.0"));
}

test "batch: perf counters in json" {
    var buf: [8192]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    var perf = PerfCounts.initFill(null);
    perf.set(.cycles, 4.5);
    perf.set(.instructions, 12.3);
    try report.add(.{
        .name = "bench1",
        .iterations = 1000,
        .samples = 11,
        .min_ns = 1.0,
        .max_ns = 5.0,
        .mean_ns = 10.0,
        .median_ns = 2.3,
        .std_ns = 0.5,
        .perf = perf,
    });
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"perf\":{"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"cycles\":4.50"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"instructions\":12.30"));
}

test "streaming: fully streamed output" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var json = Json.init(&out);
    var report = Report.initWithWriter(testing.allocator, &json.writer);
    defer report.deinit();

    const group = try report.addGroup("test");
    try group.addBaseline(testResult("base", 100.0));
    try group.add(testResult("fast", 50.0));
    try report.finish();

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"groups\":["));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"name\":\"test\""));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"is_baseline\":true"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"vs_baseline_pct\":-50.0"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "]}\n"));
}

test "batch: json string escaping" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResult("name\"with\\special", 1.0));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "name\\\"with\\\\special"));
}
