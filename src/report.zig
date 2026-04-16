//! Collects benchmark results with optional grouping.
//!
//! All results belong to a group. Unnamed groups (name = null) are created
//! implicitly when calling `add` or `addBaseline` without an explicit group.
//! Named groups are created with `addGroup`.
const Report = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Result = @import("result.zig");
const Writer = @import("writer.zig");

pub const Group = struct {
    name: ?[]const u8,
    baseline: ?Result = null,
    results: std.ArrayList(Result),
    stream: ?*Writer,
    allocator: Allocator,

    pub fn addBaseline(self: *Group, result: Result) (Writer.Error || Allocator.Error)!void {
        std.debug.assert(self.results.items.len == 0); // baseline must be first in group
        self.baseline = result;
        try self.results.append(self.allocator, result);
        if (self.stream) |w| try w.addResult(result, null, true);
    }

    pub fn add(self: *Group, result: Result) (Writer.Error || Allocator.Error)!void {
        try self.results.append(self.allocator, result);
        if (self.stream) |w| try w.addResult(result, self.baseline, false);
    }
};

groups: std.ArrayList(*Group),
active_group: ?*Group = null,
stream: ?*Writer,
allocator: Allocator,

pub fn init(allocator: Allocator) Report {
    return .{
        .groups = .empty,
        .stream = null,
        .allocator = allocator,
    };
}

pub fn initWithWriter(allocator: Allocator, stream: *Writer) Report {
    return .{
        .groups = .empty,
        .stream = stream,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Report) void {
    for (self.groups.items) |g| {
        g.results.deinit(self.allocator);
        self.allocator.destroy(g);
    }
    self.groups.deinit(self.allocator);
    if (self.active_group) |g| {
        g.results.deinit(self.allocator);
        self.allocator.destroy(g);
    }
}

/// Add a baseline result. Creates an implicit unnamed group if needed.
pub fn addBaseline(self: *Report, result: Result) (Writer.Error || Allocator.Error)!void {
    const group = try self.ensureActiveGroup(null);
    try group.addBaseline(result);
}

/// Add a result. Creates an implicit unnamed group if needed.
pub fn add(self: *Report, result: Result) (Writer.Error || Allocator.Error)!void {
    const group = try self.ensureActiveGroup(null);
    try group.add(result);
}

/// Start a new named group.
pub fn addGroup(self: *Report, name: []const u8) (Writer.Error || Allocator.Error)!*Group {
    try self.finalizeActiveGroup();
    return try self.createGroup(name);
}

pub fn finish(self: *Report) (Writer.Error || Allocator.Error)!void {
    try self.finalizeActiveGroup();
    if (self.stream) |w| try w.finish();
}

fn ensureActiveGroup(self: *Report, name: ?[]const u8) (Writer.Error || Allocator.Error)!*Group {
    if (self.active_group) |group| {
        // If there's already an active unnamed group, reuse it
        if (group.name == null and name == null) return group;
        // Otherwise finalize it and create a new one
        try self.finalizeActiveGroup();
    }
    return try self.createGroup(name);
}

fn createGroup(self: *Report, name: ?[]const u8) (Writer.Error || Allocator.Error)!*Group {
    const group = try self.allocator.create(Group);
    group.* = .{
        .name = name,
        .results = .empty,
        .stream = self.stream,
        .allocator = self.allocator,
    };
    self.active_group = group;
    if (self.stream) |w| try w.startGroup(name);
    return group;
}

fn finalizeActiveGroup(self: *Report) (Writer.Error || Allocator.Error)!void {
    if (self.active_group) |group| {
        if (self.stream) |w| try w.endGroup();
        try self.groups.append(self.allocator, group);
        self.active_group = null;
    }
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

test "add creates implicit unnamed group" {
    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResult("a"));
    try report.add(testResult("b"));
    try report.finish();

    try testing.expectEqual(@as(usize, 1), report.groups.items.len);
    const g = report.groups.items[0];
    try testing.expect(g.name == null);
    try testing.expectEqual(@as(usize, 2), g.results.items.len);
}

test "addBaseline then add in implicit group" {
    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.addBaseline(testResult("base"));
    try report.add(testResult("a"));
    try report.finish();

    try testing.expectEqual(@as(usize, 1), report.groups.items.len);
    const g = report.groups.items[0];
    try testing.expect(g.name == null);
    try testing.expectEqualStrings("base", g.baseline.?.name);
    try testing.expectEqual(@as(usize, 2), g.results.items.len);
}

test "addGroup stores named group with results" {
    var report = Report.init(testing.allocator);
    defer report.deinit();

    const group = try report.addGroup("grp");
    try group.add(testResult("a"));
    try group.add(testResult("b"));
    try report.finish();

    try testing.expectEqual(@as(usize, 1), report.groups.items.len);
    const g = report.groups.items[0];
    try testing.expectEqualStrings("grp", g.name.?);
    try testing.expectEqual(@as(usize, 2), g.results.items.len);
    try testing.expect(g.baseline == null);
}

test "addGroup with baseline" {
    var report = Report.init(testing.allocator);
    defer report.deinit();

    const group = try report.addGroup("grp");
    try group.addBaseline(testResult("base"));
    try group.add(testResult("a"));
    try report.finish();

    const g = report.groups.items[0];
    try testing.expectEqual(@as(usize, 2), g.results.items.len);
    try testing.expectEqualStrings("base", g.baseline.?.name);
}

test "interleaved unnamed and named groups" {
    var report = Report.init(testing.allocator);
    defer report.deinit();

    try report.add(testResult("solo1"));
    const g1 = try report.addGroup("grp1");
    try g1.add(testResult("g1a"));
    try report.add(testResult("solo2"));
    try report.finish();

    try testing.expectEqual(@as(usize, 3), report.groups.items.len);
    try testing.expect(report.groups.items[0].name == null);
    try testing.expectEqualStrings("grp1", report.groups.items[1].name.?);
    try testing.expect(report.groups.items[2].name == null);
}

test "streaming: writer receives correct events" {
    const TestWriter = struct {
        writer: Writer,
        calls: std.ArrayList([]const u8),
        allocator: Allocator,

        const vtable: Writer.VTable = .{
            .startGroup = @This().startGroup,
            .addResult = @This().addResult,
            .endGroup = @This().endGroup,
            .finish = @This().finish,
        };

        fn create(allocator: Allocator) @This() {
            return .{
                .writer = .{ .vtable = &vtable },
                .calls = .empty,
                .allocator = allocator,
            };
        }

        fn destroy(self: *@This()) void {
            self.calls.deinit(self.allocator);
        }

        fn startGroup(w: *Writer, _: ?[]const u8) Writer.Error!void {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", w));
            try self.calls.append(self.allocator, "startGroup");
        }
        fn addResult(w: *Writer, _: Result, _: ?Result, _: bool) Writer.Error!void {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", w));
            try self.calls.append(self.allocator, "addResult");
        }
        fn endGroup(w: *Writer) Writer.Error!void {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", w));
            try self.calls.append(self.allocator, "endGroup");
        }
        fn finish(w: *Writer) Writer.Error!void {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", w));
            try self.calls.append(self.allocator, "finish");
        }
    };

    var tw = TestWriter.create(testing.allocator);
    defer tw.destroy();

    var report = Report.initWithWriter(testing.allocator, &tw.writer);
    defer report.deinit();

    try report.add(testResult("solo"));
    const group = try report.addGroup("grp");
    try group.addBaseline(testResult("base"));
    try group.add(testResult("other"));
    try report.finish();

    try testing.expectEqual(@as(usize, 8), tw.calls.items.len);
    try testing.expectEqualStrings("startGroup", tw.calls.items[0]); // implicit unnamed
    try testing.expectEqualStrings("addResult", tw.calls.items[1]);
    try testing.expectEqualStrings("endGroup", tw.calls.items[2]);
    try testing.expectEqualStrings("startGroup", tw.calls.items[3]); // named "grp"
    try testing.expectEqualStrings("addResult", tw.calls.items[4]); // baseline
    try testing.expectEqualStrings("addResult", tw.calls.items[5]);
    try testing.expectEqualStrings("endGroup", tw.calls.items[6]);
    try testing.expectEqualStrings("finish", tw.calls.items[7]);
}
