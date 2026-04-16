//! Interface for streaming benchmark results to an output sink.
//!
//! Implementations receive events as benchmarks complete, enabling
//! progressive output for formats that support it (e.g. Markdown, CSV).
//! Formats that require all data upfront (e.g. JSON) may buffer internally
//! and write everything on `finish`.
const Writer = @This();

const std = @import("std");
const Result = @import("result.zig");

vtable: *const VTable,

pub const Error = error{ WriteFailed, OutOfMemory };

pub const VTable = struct {
    startGroup: *const fn (w: *Writer, name: ?[]const u8) Error!void,
    addResult: *const fn (w: *Writer, result: Result, baseline: ?Result, is_baseline: bool) Error!void,
    endGroup: *const fn (w: *Writer) Error!void,
    finish: *const fn (w: *Writer) Error!void,
};

pub fn startGroup(w: *Writer, name: ?[]const u8) Error!void {
    return w.vtable.startGroup(w, name);
}

pub fn addResult(w: *Writer, result: Result, baseline: ?Result, is_baseline: bool) Error!void {
    return w.vtable.addResult(w, result, baseline, is_baseline);
}

pub fn endGroup(w: *Writer) Error!void {
    return w.vtable.endGroup(w);
}

pub fn finish(w: *Writer) Error!void {
    return w.vtable.finish(w);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const PerfCounts = Result.PerfCounts;

fn testResult(name: []const u8) Result {
    return .{
        .name = name,
        .iterations = 1000,
        .samples = 11,
        .min_ns = 1.0,
        .max_ns = 5.0,
        .mean_ns = 2.5,
        .median_ns = 2.3,
        .std_ns = 0.5,
        .perf = PerfCounts.initFill(null),
    };
}

const TestWriter = struct {
    writer: Writer,
    calls: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    const vtable: VTable = .{
        .startGroup = @This().startGroup,
        .addResult = @This().addResult,
        .endGroup = @This().endGroup,
        .finish = @This().finish,
    };

    fn init(allocator: std.mem.Allocator) TestWriter {
        return .{
            .writer = .{ .vtable = &vtable },
            .calls = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestWriter) void {
        self.calls.deinit(self.allocator);
    }

    fn startGroup(w: *Writer, _: ?[]const u8) Writer.Error!void {
        const self: *TestWriter = @alignCast(@fieldParentPtr("writer", w));
        try self.calls.append(self.allocator, "startGroup");
    }

    fn addResult(w: *Writer, _: Result, _: ?Result, _: bool) Writer.Error!void {
        const self: *TestWriter = @alignCast(@fieldParentPtr("writer", w));
        try self.calls.append(self.allocator, "addResult");
    }

    fn endGroup(w: *Writer) Writer.Error!void {
        const self: *TestWriter = @alignCast(@fieldParentPtr("writer", w));
        try self.calls.append(self.allocator, "endGroup");
    }

    fn finish(w: *Writer) Writer.Error!void {
        const self: *TestWriter = @alignCast(@fieldParentPtr("writer", w));
        try self.calls.append(self.allocator, "finish");
    }
};

test "vtable dispatch calls correct methods" {
    var tw = TestWriter.init(testing.allocator);
    defer tw.deinit();

    try tw.writer.startGroup(null);
    try tw.writer.addResult(testResult("a"), null, false);
    try tw.writer.endGroup();
    try tw.writer.startGroup("group1");
    try tw.writer.addResult(testResult("b"), null, true);
    try tw.writer.addResult(testResult("c"), testResult("b"), false);
    try tw.writer.endGroup();
    try tw.writer.finish();

    try testing.expectEqual(@as(usize, 8), tw.calls.items.len);
    try testing.expectEqualStrings("startGroup", tw.calls.items[0]);
    try testing.expectEqualStrings("addResult", tw.calls.items[1]);
    try testing.expectEqualStrings("endGroup", tw.calls.items[2]);
    try testing.expectEqualStrings("startGroup", tw.calls.items[3]);
    try testing.expectEqualStrings("addResult", tw.calls.items[4]);
    try testing.expectEqualStrings("addResult", tw.calls.items[5]);
    try testing.expectEqualStrings("endGroup", tw.calls.items[6]);
    try testing.expectEqualStrings("finish", tw.calls.items[7]);
}
