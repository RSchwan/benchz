const std = @import("std");
const builtin = @import("builtin");

const has_backend = builtin.os.tag == .macos or builtin.os.tag == .linux;
const backend = if (builtin.os.tag == .macos)
    @import("perf_kpc.zig")
else if (builtin.os.tag == .linux)
    @import("perf_linux.zig")
else
    struct {
        pub const Error = error{};
    };

pub const PerfCounter = enum {
    cycles,
    instructions,
    branches,
    branch_misses,
    cache_misses_l1d,
    cache_misses_l1i,
    cache_misses_llc,
    tlb_misses_l1d,
    tlb_misses_l1i,
};

/// Per-iteration averaged counter values. Null if the counter was not measured.
pub const PerfCounts = std.enums.EnumArray(PerfCounter, ?f64);

/// Raw counter values (totals, not per-iteration). Null if the counter was not measured.
pub const RawCounts = std.enums.EnumArray(PerfCounter, ?u64);

pub const Error = backend.Error || error{
    /// Performance counters are not supported on this platform.
    PerfUnsupported,
    /// Too many counters requested for available hardware/grouping slots.
    TooManyCounters,
};

/// Maximum number of counter groups (each group is one measurement pass).
const max_groups = 8;

/// Maximum number of counters in one group.
const max_per_group = 16;

/// Number of calibration iterations for measuring overhead and loop baseline.
pub const calibration_runs = 100;

/// Hardware PMU counter capacity, split by type.
/// Fixed counters are hardwired to specific events (e.g. cycles, instructions).
/// Configurable counters can be programmed to measure any supported event.
pub const CounterLimits = struct {
    fixed: usize,
    configurable: usize,
};

/// Whether a counter uses a fixed hardware slot or a configurable PMU register.
/// On macOS, this queries kpep for the actual mapping. On Linux, uses a heuristic.
pub fn isFixedCounter(counter: PerfCounter) Error!bool {
    if (builtin.os.tag == .macos) {
        return backend.isFixedCounter(counter);
    }
    // Linux: cycles and instructions typically use fixed PMU slots.
    return switch (counter) {
        .cycles, .instructions => true,
        else => false,
    };
}

/// A set of counters that can be measured simultaneously in a single pass.
/// Limited by the number of physical PMU slots available.
pub const CounterGroup = struct {
    counters: [max_per_group]PerfCounter = undefined,
    len: usize = 0,

    pub fn slice(self: *const CounterGroup) []const PerfCounter {
        return self.counters[0..self.len];
    }
};

/// Collection of counter groups. When more counters are requested than hardware
/// supports simultaneously, they are split across multiple groups (measurement passes).
pub const CounterGroups = struct {
    groups: [max_groups]CounterGroup = .{CounterGroup{}} ** max_groups,
    len: usize = 0,

    pub fn slice(self: *const CounterGroups) []const CounterGroup {
        return self.groups[0..self.len];
    }
};

/// Split counters into groups that fit hardware limits.
/// Respects the separate fixed and configurable counter limits.
pub fn groupCounters(counters: []const PerfCounter) Error!CounterGroups {
    if (counters.len == 0) return .{};
    if (!has_backend) {
        if (counters.len > 0) return error.PerfUnsupported;
        return .{};
    }

    const probed = try backend.maxSimultaneousCounters();
    // If probing returns zero (e.g. pinned events need elevated privileges),
    // fall back to typical x86 PMU layout: 3 fixed + 4 configurable.
    const limits: CounterLimits = if (probed.fixed == 0 and probed.configurable == 0)
        .{ .fixed = 3, .configurable = 4 }
    else
        probed;

    var result = CounterGroups{};
    var group = CounterGroup{};
    var fixed_used: usize = 0;
    var config_used: usize = 0;

    for (counters) |counter| {
        const is_fixed = try isFixedCounter(counter);
        const would_exceed = if (is_fixed)
            fixed_used >= limits.fixed
        else
            config_used >= limits.configurable;

        if (would_exceed and group.len > 0) {
            // Current group is full for this counter type, start a new group.
            if (result.len >= max_groups) return error.TooManyCounters;
            result.groups[result.len] = group;
            result.len += 1;
            group = CounterGroup{};
            fixed_used = 0;
            config_used = 0;
        }

        if (group.len >= max_per_group) return error.TooManyCounters;
        group.counters[group.len] = counter;
        group.len += 1;
        if (is_fixed) {
            fixed_used += 1;
        } else {
            config_used += 1;
        }
    }

    if (group.len > 0) {
        if (result.len >= max_groups) return error.TooManyCounters;
        result.groups[result.len] = group;
        result.len += 1;
    }

    return result;
}

/// Platform-agnostic wrapper around the OS-specific perf backend.
/// Manages the lifecycle of hardware counter configuration and provides
/// readBefore/readAfter pairs for measuring counter deltas.
pub const PerfState = struct {
    state: InnerState = .{},

    const InnerState = if (has_backend) backend.BackendState else struct {};

    /// Configure and start counting the requested counters.
    pub fn init(counters: []const PerfCounter) Error!PerfState {
        if (has_backend) {
            return .{ .state = try backend.BackendState.init(counters) };
        }
        if (counters.len > 0) return error.PerfUnsupported;
        return .{};
    }

    /// Stop counting and release hardware counters.
    pub fn deinit(self: *PerfState) void {
        if (has_backend) self.state.deinit();
    }

    /// Snapshot counter values before the measured region.
    pub fn readBefore(self: *PerfState) Error!void {
        if (has_backend) try self.state.readBefore();
    }

    /// Read counters after the measured region and return raw deltas (totals, not per-iteration).
    pub fn readAfter(self: *PerfState) Error!RawCounts {
        if (has_backend) {
            return try self.state.readAfter();
        }
        return RawCounts.initFill(null);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "groupCounters: empty input returns empty groups" {
    const groups = try groupCounters(&.{});
    try testing.expectEqual(@as(usize, 0), groups.len);
    try testing.expectEqual(@as(usize, 0), groups.slice().len);
}

test "groupCounters: single counter" {
    if (!has_backend) return error.SkipZigTest;
    const counters = [_]PerfCounter{.cycles};
    const groups = groupCounters(&counters) catch |err| {
        if (err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
    try testing.expect(groups.len >= 1);

    var total: usize = 0;
    for (groups.slice()) |g| total += g.slice().len;
    try testing.expectEqual(@as(usize, 1), total);
    try testing.expectEqual(PerfCounter.cycles, groups.groups[0].counters[0]);
}

test "groupCounters: all counters are assigned to groups" {
    if (!has_backend) return error.SkipZigTest;

    const all = comptime std.enums.values(PerfCounter);
    const groups = groupCounters(all) catch |err| {
        if (err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
    try testing.expect(groups.len >= 1);

    var total: usize = 0;
    for (groups.slice()) |g| {
        try testing.expect(g.slice().len > 0);
        total += g.slice().len;
    }
    try testing.expectEqual(all.len, total);
}

test "CounterGroup.slice matches len" {
    var g = CounterGroup{};
    try testing.expectEqual(@as(usize, 0), g.slice().len);

    g.counters[0] = .cycles;
    g.counters[1] = .instructions;
    g.len = 2;
    try testing.expectEqual(@as(usize, 2), g.slice().len);
    try testing.expectEqual(PerfCounter.cycles, g.slice()[0]);
    try testing.expectEqual(PerfCounter.instructions, g.slice()[1]);
}

test "CounterGroups.slice matches len" {
    var gs = CounterGroups{};
    try testing.expectEqual(@as(usize, 0), gs.slice().len);

    gs.groups[0].counters[0] = .cycles;
    gs.groups[0].len = 1;
    gs.groups[1].counters[0] = .branches;
    gs.groups[1].len = 1;
    gs.len = 2;
    try testing.expectEqual(@as(usize, 2), gs.slice().len);
}

test "isFixedCounter: linux heuristic" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    try testing.expect(try isFixedCounter(.cycles));
    try testing.expect(try isFixedCounter(.instructions));
    try testing.expect(!try isFixedCounter(.branches));
    try testing.expect(!try isFixedCounter(.branch_misses));
    try testing.expect(!try isFixedCounter(.cache_misses_l1d));
}

test "isFixedCounter: macos queries kpep" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // Just verify it doesn't error out — the fixed/configurable classification
    // depends on the CPU, so we don't assert specific values.
    _ = isFixedCounter(.cycles) catch |err| {
        if (err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
}

test "PerfState: init/readBefore/readAfter/deinit round-trip" {
    if (!has_backend) return error.SkipZigTest;

    const counters = [_]PerfCounter{.cycles};
    var state = PerfState.init(&counters) catch |err| {
        if (err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
    defer state.deinit();

    try state.readBefore();

    // Do some work so counters are non-zero.
    var sum: u64 = 0;
    for (0..10_000) |i| sum +%= i;
    std.mem.doNotOptimizeAway(sum);

    const raw = try state.readAfter();
    const cycles = raw.get(.cycles);
    // With high perf_event_paranoid, the kernel may accept the event but
    // never schedule it (time_running == 0), returning null.
    if (cycles == null) return error.SkipZigTest;
    try testing.expect(cycles.? > 0);
}
