const std = @import("std");

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

pub const PerfCounts = std.enums.EnumArray(PerfCounter, ?f64);

/// Raw counter values (totals, not per-iteration).
pub const RawCounts = std.enums.EnumArray(PerfCounter, ?u64);

pub const Error = error{
    /// Performance counters are not supported on this platform.
    PerfUnsupported,
    /// Insufficient privileges.
    PermissionDenied,
    DatabaseLoadFailed,
    ConfigCreateFailed,
    ConfigForceFailed,
    EventNotFound,
    EventAddFailed,
    ConfigQueryFailed,
    KernelConfigFailed,
    CountingStartFailed,
    CounterReadFailed,
    FrameworkLoadFailed,
    SymbolLoadFailed,
    TooManyCounters,
    OpenFailed,
    IoctlFailed,
    ReadFailed,
};

const builtin = @import("builtin");
const has_backend = builtin.os.tag == .macos or builtin.os.tag == .linux;
const backend = if (builtin.os.tag == .macos)
    @import("perf_kpc.zig")
else if (builtin.os.tag == .linux)
    @import("perf_linux.zig")
else
    unreachable;

pub const default_counters = if (builtin.os.tag == .linux) [_]PerfCounter{
    .cycles,
    .instructions,
    .branches,
    .branch_misses,
} else [_]PerfCounter{};

/// Maximum number of counter groups (each group is one measurement pass).
const max_groups = 8;

/// Maximum number of counters in one group.
const max_per_group = 16;

pub const calibration_runs = 100;

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

pub const CounterGroup = struct {
    counters: [max_per_group]PerfCounter = undefined,
    len: usize = 0,

    pub fn slice(self: *const CounterGroup) []const PerfCounter {
        return self.counters[0..self.len];
    }
};

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

    const limits = try backend.maxSimultaneousCounters();

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
            result.groups[result.len] = group;
            result.len += 1;
            group = CounterGroup{};
            fixed_used = 0;
            config_used = 0;
        }

        group.counters[group.len] = counter;
        group.len += 1;
        if (is_fixed) {
            fixed_used += 1;
        } else {
            config_used += 1;
        }
    }

    if (group.len > 0) {
        result.groups[result.len] = group;
        result.len += 1;
    }

    return result;
}

pub const PerfState = struct {
    state: InnerState = .{},
    raw_counts: RawCounts = RawCounts.initFill(null),

    const InnerState = if (has_backend) backend.BackendState else struct {};

    pub fn init(counters: []const PerfCounter) Error!PerfState {
        if (has_backend) {
            return .{ .state = try backend.BackendState.init(counters) };
        }
        if (counters.len > 0) return error.PerfUnsupported;
        return .{};
    }

    pub fn deinit(self: *PerfState) void {
        if (has_backend) self.state.deinit();
    }

    pub fn readBefore(self: *PerfState) Error!void {
        if (has_backend) try self.state.readBefore();
    }

    /// Read counters and store raw totals (not per-iteration).
    pub fn readAfterRaw(self: *PerfState) Error!void {
        if (has_backend) {
            self.raw_counts = try self.state.readAfterRaw();
        }
    }
};
