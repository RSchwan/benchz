//! Markdown table formatter for benchmark results.
//!
//! Supports both streaming (via the `Writer` interface) and batch output.
//! Unnamed groups are written as a flat table. Named groups get a heading
//! and their own table, with an optional "vs baseline" column.
//! Perf counter columns are included automatically when results contain them.
const Markdown = @This();

const std = @import("std");
const IoWriter = std.Io.Writer;
const Result = @import("../result.zig");
const Writer = @import("../writer.zig");
const Report = @import("../report.zig");
const PerfCounter = @import("../perf.zig").PerfCounter;

writer: Writer,
out: *IoWriter,
header_written: bool = false,
has_baseline: bool = false,
active_counters: ActiveCounters = ActiveCounters.initFill(false),

const ActiveCounters = std.enums.EnumArray(PerfCounter, bool);

const vtable: Writer.VTable = .{
    .startGroup = Markdown.startGroup,
    .addResult = Markdown.addResult,
    .endGroup = Markdown.endGroup,
    .finish = Markdown.finish,
};

pub fn init(out: *IoWriter) Markdown {
    return .{
        .writer = .{ .vtable = &vtable },
        .out = out,
    };
}

/// Batch-write a completed report.
pub fn writeReport(report: *const Report, out: *IoWriter) IoWriter.Error!void {
    for (report.groups.items) |group| {
        try writeGroup(out, group);
    }
    if (report.active_group) |group| {
        try writeGroup(out, group);
    }
}

fn writeGroup(out: *IoWriter, group: *const Report.Group) IoWriter.Error!void {
    if (group.name) |name| {
        try out.print("\n## {s}\n\n", .{name});
    }
    const has_baseline = group.baseline != null;
    const counters = detectCounters(group.results.items);
    try writeTableHeader(out, has_baseline, counters);
    for (group.results.items) |result| {
        const is_bl = if (group.baseline) |b| std.mem.eql(u8, result.name, b.name) else false;
        const baseline = if (is_bl) null else group.baseline;
        try writeResultRow(out, result, baseline, is_bl, has_baseline, counters);
    }
    try out.writeAll("\n");
}

fn detectCounters(results: []const Result) ActiveCounters {
    var counters = ActiveCounters.initFill(false);
    if (results.len == 0) return counters;
    const first = results[0];
    for (std.enums.values(PerfCounter)) |counter| {
        if (first.perf.get(counter) != null) {
            counters.set(counter, true);
        }
    }
    return counters;
}

// -- Streaming Writer implementation --

fn startGroup(w: *Writer, name: ?[]const u8) Writer.Error!void {
    const self: *Markdown = @alignCast(@fieldParentPtr("writer", w));
    self.header_written = false;
    self.has_baseline = false;
    self.active_counters = ActiveCounters.initFill(false);
    if (name) |n| {
        self.out.print("\n## {s}\n\n", .{n}) catch return error.WriteFailed;
    }
}

fn addResult(w: *Writer, result: Result, baseline: ?Result, is_baseline: bool) Writer.Error!void {
    const self: *Markdown = @alignCast(@fieldParentPtr("writer", w));
    if (is_baseline or baseline != null) self.has_baseline = true;
    if (!self.header_written) {
        // Detect perf counters from the first result
        for (std.enums.values(PerfCounter)) |counter| {
            if (result.perf.get(counter) != null) {
                self.active_counters.set(counter, true);
            }
        }
        writeTableHeader(self.out, self.has_baseline, self.active_counters) catch return error.WriteFailed;
        self.header_written = true;
    }
    writeResultRow(self.out, result, baseline, is_baseline, self.has_baseline, self.active_counters) catch return error.WriteFailed;
    self.out.flush() catch return error.WriteFailed;
}

fn endGroup(w: *Writer) Writer.Error!void {
    const self: *Markdown = @alignCast(@fieldParentPtr("writer", w));
    self.out.writeAll("\n") catch return error.WriteFailed;
    self.header_written = false;
}

fn finish(_: *Writer) Writer.Error!void {}

// -- Shared formatting helpers --

// Column widths (characters between pipes, excluding padding spaces)
const col_name = 30;
const col_time = 10;
const col_baseline = 11;
const col_iter = 10;
const col_perf = 10;

fn writeTableHeader(out: *IoWriter, has_baseline: bool, counters: ActiveCounters) IoWriter.Error!void {
    try out.print("| {s:<" ++ colw(col_name) ++ "} | {s:>" ++ colw(col_time) ++ "} | ", .{ "Benchmark", "time" });
    if (has_baseline) {
        try out.print("{s:>" ++ colw(col_baseline) ++ "} | ", .{"vs baseline"});
    }
    try out.print("{s:>" ++ colw(col_iter) ++ "} | ", .{"iterations"});
    for (std.enums.values(PerfCounter)) |counter| {
        if (counters.get(counter)) {
            try out.print("{s:>" ++ colw(col_perf) ++ "} | ", .{counterName(counter)});
        }
    }
    try out.writeByte('\n');

    // Separator row
    try out.writeByte('|');
    try writeRepeat(out, '-', col_name + 2);
    try out.writeByte('|');
    try writeRepeat(out, '-', col_time + 1);
    try out.writeAll(":|");
    if (has_baseline) {
        try writeRepeat(out, '-', col_baseline + 1);
        try out.writeAll(":|");
    }
    try writeRepeat(out, '-', col_iter + 1);
    try out.writeAll(":|");
    for (std.enums.values(PerfCounter)) |counter| {
        if (counters.get(counter)) {
            try writeRepeat(out, '-', col_perf + 1);
            try out.writeAll(":|");
        }
    }
    try out.writeByte('\n');
}

fn writeResultRow(out: *IoWriter, result: Result, baseline: ?Result, is_baseline: bool, show_baseline_col: bool, counters: ActiveCounters) IoWriter.Error!void {
    var time_buf: [32]u8 = undefined;
    var time_writer = IoWriter.fixed(&time_buf);
    writeTime(&time_writer, result.mean_ns) catch {};
    const time_str = time_writer.buffered();

    try out.print("| {s:<" ++ colw(col_name) ++ "} | {s:>" ++ colw(col_time) ++ "} | ", .{ result.name, time_str });
    if (show_baseline_col) {
        if (is_baseline) {
            try out.print("{s:>" ++ colw(col_baseline) ++ "} | ", .{"(baseline)"});
        } else if (baseline) |b| {
            const pct = (result.mean_ns - b.mean_ns) / b.mean_ns * 100.0;
            var pct_buf: [32]u8 = undefined;
            var pct_writer = IoWriter.fixed(&pct_buf);
            const sign: []const u8 = if (pct >= 0) "+" else "";
            pct_writer.print("{s}{d:.1}%", .{ sign, pct }) catch {};
            try out.print("{s:>" ++ colw(col_baseline) ++ "} | ", .{pct_writer.buffered()});
        } else {
            try out.print("{s:>" ++ colw(col_baseline) ++ "} | ", .{""});
        }
    }
    try out.print("{d:>" ++ colw(col_iter) ++ "} | ", .{result.iterations});
    for (std.enums.values(PerfCounter)) |counter| {
        if (counters.get(counter)) {
            if (result.perf.get(counter)) |value| {
                try out.print("{d:>" ++ colw(col_perf) ++ ".2} | ", .{value});
            } else {
                try out.print("{s:>" ++ colw(col_perf) ++ "} | ", .{""});
            }
        }
    }
    try out.writeByte('\n');
}

fn writeTime(out: *IoWriter, ns: f64) IoWriter.Error!void {
    if (ns < 1_000) {
        try out.print("{d:.2} ns", .{ns});
    } else if (ns < 1_000_000) {
        try out.print("{d:.2} us", .{ns / 1_000});
    } else if (ns < 1_000_000_000) {
        try out.print("{d:.2} ms", .{ns / 1_000_000});
    } else {
        try out.print("{d:.2} s", .{ns / 1_000_000_000});
    }
}

fn counterName(counter: PerfCounter) []const u8 {
    return switch (counter) {
        .cycles => "cycles",
        .instructions => "instrs",
        .branches => "branches",
        .branch_misses => "br miss",
        .cache_misses_l1d => "L1d miss",
        .cache_misses_l1i => "L1i miss",
        .cache_misses_llc => "LLC miss",
        .tlb_misses_l1d => "TLBd miss",
        .tlb_misses_l1i => "TLBi miss",
    };
}

fn colw(comptime width: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{width});
}

fn writeRepeat(out: *IoWriter, byte: u8, count: usize) IoWriter.Error!void {
    for (0..count) |_| {
        try out.writeByte(byte);
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

fn testResultWithPerf(name: []const u8, mean_ns: f64) Result {
    var perf = PerfCounts.initFill(null);
    perf.set(.cycles, 4.5);
    perf.set(.instructions, 12.3);
    return .{
        .name = name,
        .iterations = 1000,
        .samples = 11,
        .min_ns = 1.0,
        .max_ns = 5.0,
        .mean_ns = mean_ns,
        .median_ns = 2.3,
        .std_ns = 0.5,
        .perf = perf,
    };
}

test "batch: unnamed group (ungrouped results)" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResult("noop", 1.23));
    try report.add(testResult("add", 2.50));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "| noop "));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "| add "));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "##"));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "vs baseline"));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "cycles"));
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
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "## hashing"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "vs baseline"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "(baseline)"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "-50.0%"));
}

test "batch: named group without baseline" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    const group = try report.addGroup("misc");
    try group.add(testResult("a", 1.0));
    try group.add(testResult("b", 2.0));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "## misc"));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "vs baseline"));
}

test "batch: perf counters shown as columns" {
    var buf: [8192]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResultWithPerf("bench1", 10.0));
    try report.add(testResultWithPerf("bench2", 20.0));
    try report.finish();

    try writeReport(&report, &out);

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "cycles"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "instrs"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "4.5"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "12.3"));
    // Counters not set should not appear
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "branches"));
}

test "streaming: unnamed group" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var md = Markdown.init(&out);
    var report = Report.initWithWriter(testing.allocator, &md.writer);
    defer report.deinit();

    try report.add(testResult("noop", 1.23));
    try report.add(testResult("add", 2.50));
    try report.finish();

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "| noop "));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "| add "));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "##"));
}

test "streaming: named group with baseline" {
    var buf: [4096]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var md = Markdown.init(&out);
    var report = Report.initWithWriter(testing.allocator, &md.writer);
    defer report.deinit();

    const group = try report.addGroup("hashing");
    try group.addBaseline(testResult("sha256", 200.0));
    try group.add(testResult("blake3", 100.0));
    try report.finish();

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "## hashing"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "(baseline)"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "-50.0%"));
}

test "streaming: perf counters detected from first result" {
    var buf: [8192]u8 = undefined;
    var out = IoWriter.fixed(&buf);

    var md = Markdown.init(&out);
    var report = Report.initWithWriter(testing.allocator, &md.writer);
    defer report.deinit();

    try report.add(testResultWithPerf("bench1", 10.0));
    try report.add(testResultWithPerf("bench2", 20.0));
    try report.finish();

    const output = out.buffered();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "cycles"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "instrs"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "4.5"));
}
