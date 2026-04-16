//! CSV formatter for benchmark results.
//!
//! Supports both streaming (via the `Writer` interface) and batch output.
//! All columns are always included (group, benchmark, timing stats, all perf
//! counters) for consistent machine-parseable output.
const Csv = @This();

const std = @import("std");
const IoWriter = std.Io.Writer;
const Result = @import("../result.zig");
const Writer = @import("../writer.zig");
const Report = @import("../report.zig");
const PerfCounter = @import("../perf.zig").PerfCounter;

writer: Writer,
out: *IoWriter,
header_written: bool = false,
group_name: ?[]const u8 = null,

const vtable: Writer.VTable = .{
    .startGroup = Csv.startGroup,
    .addResult = Csv.addResult,
    .endGroup = Csv.endGroup,
    .finish = Csv.finish,
};

pub fn init(out: *IoWriter) Csv {
    return .{
        .writer = .{ .vtable = &vtable },
        .out = out,
    };
}

/// Batch-write a completed report.
pub fn writeReport(report: *const Report, out: *IoWriter) IoWriter.Error!void {
    try writeHeader(out);
    for (report.groups.items) |group| {
        try writeGroupRows(out, group);
    }
    if (report.active_group) |group| {
        try writeGroupRows(out, group);
    }
}

fn writeGroupRows(out: *IoWriter, group: *const Report.Group) IoWriter.Error!void {
    for (group.results.items) |result| {
        const is_bl = if (group.baseline) |b| std.mem.eql(u8, result.name, b.name) else false;
        const baseline = if (is_bl) null else group.baseline;
        try writeRow(out, group.name, result, baseline, is_bl);
    }
}

// -- Streaming Writer implementation --

fn startGroup(w: *Writer, name: ?[]const u8) Writer.Error!void {
    const self: *Csv = @alignCast(@fieldParentPtr("writer", w));
    self.group_name = name;
}

fn addResult(w: *Writer, result: Result, baseline: ?Result, is_baseline: bool) Writer.Error!void {
    const self: *Csv = @alignCast(@fieldParentPtr("writer", w));
    if (!self.header_written) {
        writeHeader(self.out) catch return error.WriteFailed;
        self.header_written = true;
    }
    writeRow(self.out, self.group_name, result, baseline, is_baseline) catch return error.WriteFailed;
    self.out.flush() catch return error.WriteFailed;
}

fn endGroup(_: *Writer) Writer.Error!void {}

fn finish(_: *Writer) Writer.Error!void {}

// -- Shared formatting helpers --

fn writeHeader(out: *IoWriter) IoWriter.Error!void {
    try out.writeAll("group,benchmark,mean_ns,min_ns,max_ns,median_ns,std_ns,vs_baseline,iterations,samples");
    for (std.enums.values(PerfCounter)) |counter| {
        try out.print(",{s}", .{@tagName(counter)});
    }
    try out.writeByte('\n');
}

fn writeRow(out: *IoWriter, group_name: ?[]const u8, result: Result, baseline: ?Result, is_baseline: bool) IoWriter.Error!void {
    if (group_name) |name| {
        try writeCsvField(out, name);
    }
    try out.writeByte(',');
    try writeCsvField(out, result.name);
    try out.print(",{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},", .{ result.mean_ns, result.min_ns, result.max_ns, result.median_ns, result.std_ns });

    if (is_baseline) {
        try out.writeAll("baseline");
    } else if (baseline) |b| {
        const pct = (result.mean_ns - b.mean_ns) / b.mean_ns * 100.0;
        const sign: []const u8 = if (pct >= 0) "+" else "";
        try out.print("{s}{d:.1}%", .{ sign, pct });
    }

    try out.print(",{d},{d}", .{ result.iterations, result.samples });

    for (std.enums.values(PerfCounter)) |counter| {
        try out.writeByte(',');
        if (result.perf.get(counter)) |value| {
            try out.print("{d:.2}", .{value});
        }
    }
    try out.writeByte('\n');
}

fn writeCsvField(out: *IoWriter, field: []const u8) IoWriter.Error!void {
    var needs_quote = false;
    for (field) |c| {
        if (c == ',' or c == '"' or c == '\n') {
            needs_quote = true;
            break;
        }
    }
    if (needs_quote) {
        try out.writeByte('"');
        for (field) |c| {
            if (c == '"') try out.writeByte('"');
            try out.writeByte(c);
        }
        try out.writeByte('"');
    } else {
        try out.writeAll(field);
    }
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

test "batch: all columns present in header" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResult("noop", 1.23));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "group,benchmark,mean_ns,min_ns,max_ns,median_ns,std_ns,vs_baseline,iterations,samples"));
    // All perf counter columns present even with no data
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "cycles"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "instructions"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "tlb_misses_l1i"));
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
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "hashing,sha256,200.00,"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "baseline"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "-50.0%"));
}

test "batch: perf counter values" {
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
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "4.50"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "12.30"));
}

test "batch: csv quoting" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResult("name,with,commas", 1.0));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"name,with,commas\""));
}

test "streaming: basic csv output" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var csv = Csv.init(&out);
    var report = Report.initWithWriter(testing.allocator, &csv.writer);
    defer report.deinit();

    try report.add(testResult("noop", 1.23));
    try report.add(testResult("add", 2.50));
    try report.finish();

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "group,benchmark,mean_ns"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, ",noop,1.23,"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, ",add,2.50,"));
}
