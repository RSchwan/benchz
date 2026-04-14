const std = @import("std");
const perf = @import("perf.zig");
const PerfCounter = perf.PerfCounter;
const RawCounts = perf.RawCounts;
const Error = perf.Error;

const KPC_CLASS_FIXED: u32 = 0;
const KPC_CLASS_CONFIGURABLE: u32 = 1;
const KPC_CLASS_FIXED_MASK: u32 = 1 << KPC_CLASS_FIXED;
const KPC_CLASS_CONFIGURABLE_MASK: u32 = 1 << KPC_CLASS_CONFIGURABLE;
const KPC_MAX_COUNTERS: u32 = 32;

/// Event names from /usr/share/kpep/<name>.plist
/// Multiple names per counter for cross-architecture support (Apple Silicon vs Intel).
const event_names = std.enums.EnumArray(PerfCounter, []const [*:0]const u8).init(.{
    .cycles = &.{ "FIXED_CYCLES", "CPU_CLK_UNHALTED.THREAD", "CPU_CLK_UNHALTED.CORE" },
    .instructions = &.{ "FIXED_INSTRUCTIONS", "INST_RETIRED.ANY" },
    .branches = &.{ "INST_BRANCH", "BR_INST_RETIRED.ALL_BRANCHES" },
    .branch_misses = &.{ "BRANCH_MISPRED_NONSPEC", "BRANCH_MISPREDICT", "BR_MISP_RETIRED.ALL_BRANCHES" },
    .cache_misses_l1d = &.{ "L1D_CACHE_MISS_LD_NONSPEC", "L1D_CACHE_MISS_LD", "L1D.REPLACEMENT" },
    .cache_misses_l1i = &.{ "L1I_CACHE_MISS_DEMAND", "ICACHE.MISSES" },
    .cache_misses_llc = &.{ "L2_CACHE_MISS_DATA", "LONGEST_LAT_CACHE.MISS", "MEM_LOAD_RETIRED.L3_MISS" },
    .tlb_misses_l1d = &.{ "L1D_TLB_MISS", "L1D_TLB_MISS_NONSPEC", "DTLB_LOAD_MISSES.MISS_CAUSES_A_WALK" },
    .tlb_misses_l1i = &.{ "L1I_TLB_MISS_DEMAND", "ITLB_MISSES.MISS_CAUSES_A_WALK" },
});

const KpepEvent = opaque {};
const KpepDb = opaque {};
const KpepConfig = opaque {};

const KpcConfigT = u64;

pub fn maxSimultaneousCounters() Error!usize {
    try loadFrameworks();
    const fixed = kpc_get_counter_count.?(KPC_CLASS_FIXED_MASK);
    const configurable = kpc_get_counter_count.?(KPC_CLASS_CONFIGURABLE_MASK);
    return fixed + configurable;
}

pub const BackendState = struct {
    counter_map: [KPC_MAX_COUNTERS]usize = .{0} ** KPC_MAX_COUNTERS,
    counters_before: [KPC_MAX_COUNTERS]u64 = .{0} ** KPC_MAX_COUNTERS,
    requested: []const PerfCounter = &.{},

    pub fn init(counters: []const PerfCounter) Error!BackendState {
        if (counters.len == 0) return .{};

        try loadFrameworks();

        var state = BackendState{};
        state.requested = counters;

        // Check root privileges
        var force_ctrs: c_int = 0;
        if (kpc_force_all_ctrs_get.?(&force_ctrs) != 0)
            return error.PermissionDenied;

        // Load PMC database for current CPU
        var db: ?*KpepDb = null;
        if (kpep_db_create.?(null, &db) != 0)
            return error.DatabaseLoadFailed;

        // Create config
        var config: ?*KpepConfig = null;
        if (kpep_config_create.?(db.?, &config) != 0)
            return error.ConfigCreateFailed;

        if (kpep_config_force_counters.?(config.?) != 0)
            return error.ConfigForceFailed;

        // Look up and add each event
        for (counters) |counter| {
            const names = event_names.get(counter);
            var ev = findEvent(db.?, names) orelse
                return error.EventNotFound;
            if (kpep_config_add_event.?(config.?, @ptrCast(&ev), 0, null) != 0)
                return error.EventAddFailed;
        }

        // Get KPC configuration
        var classes: u32 = 0;
        var reg_count: usize = 0;
        var regs: [KPC_MAX_COUNTERS]KpcConfigT = .{0} ** KPC_MAX_COUNTERS;
        if (kpep_config_kpc_classes.?(config.?, &classes) != 0)
            return error.ConfigQueryFailed;
        if (kpep_config_kpc_count.?(config.?, &reg_count) != 0)
            return error.ConfigQueryFailed;
        if (kpep_config_kpc_map.?(config.?, &state.counter_map, @sizeOf(@TypeOf(state.counter_map))) != 0)
            return error.ConfigQueryFailed;
        if (kpep_config_kpc.?(config.?, &regs, @sizeOf(@TypeOf(regs))) != 0)
            return error.ConfigQueryFailed;

        // Apply config to kernel
        if (kpc_force_all_ctrs_set.?(1) != 0)
            return error.KernelConfigFailed;

        if ((classes & KPC_CLASS_CONFIGURABLE_MASK) != 0 and reg_count > 0) {
            if (kpc_set_config.?(classes, &regs) != 0)
                return error.KernelConfigFailed;
        }

        // Start counting
        if (kpc_set_counting.?(classes) != 0)
            return error.CountingStartFailed;
        if (kpc_set_thread_counting.?(classes) != 0)
            return error.CountingStartFailed;

        return state;
    }

    pub fn deinit(self: *BackendState) void {
        if (self.requested.len == 0) return;

        _ = kpc_set_counting.?(0);
        _ = kpc_set_thread_counting.?(0);
        _ = kpc_force_all_ctrs_set.?(0);

        self.requested = &.{};
    }

    pub fn readBefore(self: *BackendState) Error!void {
        if (self.requested.len == 0) return;
        if (kpc_get_thread_counters.?(0, KPC_MAX_COUNTERS, &self.counters_before) != 0)
            return error.CounterReadFailed;
    }

    /// Read counters and return raw totals (not per-iteration).
    pub fn readAfterRaw(self: *BackendState) Error!RawCounts {
        var result = RawCounts.initFill(null);
        if (self.requested.len == 0) return result;

        var counters_after: [KPC_MAX_COUNTERS]u64 = .{0} ** KPC_MAX_COUNTERS;
        if (kpc_get_thread_counters.?(0, KPC_MAX_COUNTERS, &counters_after) != 0)
            return error.CounterReadFailed;

        for (self.requested, 0..) |counter, i| {
            const idx = self.counter_map[i];
            const delta = counters_after[idx] -% self.counters_before[idx];
            result.set(counter, delta);
        }

        return result;
    }
};

fn findEvent(db: *KpepDb, names: []const [*:0]const u8) ?*KpepEvent {
    for (names) |name| {
        var ev: ?*KpepEvent = null;
        if (kpep_db_event.?(db, name, &ev) == 0) {
            if (ev) |e| return e;
        }
    }
    return null;
}

// =============================================================================
// Dynamic framework loading
// =============================================================================

const KPERF_PATH = "/System/Library/PrivateFrameworks/kperf.framework/kperf";
const KPERFDATA_PATH = "/System/Library/PrivateFrameworks/kperfdata.framework/kperfdata";

var frameworks_loaded = false;

// kperf.framework function pointers
var kpc_force_all_ctrs_get: ?*const fn (*c_int) callconv(.c) c_int = null;
var kpc_force_all_ctrs_set: ?*const fn (c_int) callconv(.c) c_int = null;
var kpc_get_counter_count: ?*const fn (u32) callconv(.c) u32 = null;
var kpc_get_config_count: ?*const fn (u32) callconv(.c) u32 = null;
var kpc_set_config: ?*const fn (u32, [*]KpcConfigT) callconv(.c) c_int = null;
var kpc_get_thread_counters: ?*const fn (u32, u32, [*]u64) callconv(.c) c_int = null;
var kpc_set_counting: ?*const fn (u32) callconv(.c) c_int = null;
var kpc_set_thread_counting: ?*const fn (u32) callconv(.c) c_int = null;

// kperfdata.framework function pointers
var kpep_db_create: ?*const fn (?[*:0]const u8, *?*KpepDb) callconv(.c) c_int = null;
var kpep_db_free: ?*const fn (*KpepDb) callconv(.c) void = null;
var kpep_db_event: ?*const fn (*KpepDb, [*:0]const u8, *?*KpepEvent) callconv(.c) c_int = null;
var kpep_config_create: ?*const fn (*KpepDb, *?*KpepConfig) callconv(.c) c_int = null;
var kpep_config_free: ?*const fn (*KpepConfig) callconv(.c) void = null;
var kpep_config_add_event: ?*const fn (*KpepConfig, *?*KpepEvent, u32, ?*u32) callconv(.c) c_int = null;
var kpep_config_force_counters: ?*const fn (*KpepConfig) callconv(.c) c_int = null;
var kpep_config_kpc_classes: ?*const fn (*KpepConfig, *u32) callconv(.c) c_int = null;
var kpep_config_kpc_count: ?*const fn (*KpepConfig, *usize) callconv(.c) c_int = null;
var kpep_config_kpc_map: ?*const fn (*KpepConfig, [*]usize, usize) callconv(.c) c_int = null;
var kpep_config_kpc: ?*const fn (*KpepConfig, [*]KpcConfigT, usize) callconv(.c) c_int = null;

fn loadFrameworks() Error!void {
    if (frameworks_loaded) return;

    const kperf = std.c.dlopen(KPERF_PATH, .{ .LAZY = true }) orelse
        return error.FrameworkLoadFailed;
    const kperfdata = std.c.dlopen(KPERFDATA_PATH, .{ .LAZY = true }) orelse
        return error.FrameworkLoadFailed;

    inline for (.{
        .{ &kpc_force_all_ctrs_get, kperf, "kpc_force_all_ctrs_get" },
        .{ &kpc_force_all_ctrs_set, kperf, "kpc_force_all_ctrs_set" },
        .{ &kpc_get_counter_count, kperf, "kpc_get_counter_count" },
        .{ &kpc_get_config_count, kperf, "kpc_get_config_count" },
        .{ &kpc_set_config, kperf, "kpc_set_config" },
        .{ &kpc_get_thread_counters, kperf, "kpc_get_thread_counters" },
        .{ &kpc_set_counting, kperf, "kpc_set_counting" },
        .{ &kpc_set_thread_counting, kperf, "kpc_set_thread_counting" },
        .{ &kpep_db_create, kperfdata, "kpep_db_create" },
        .{ &kpep_db_free, kperfdata, "kpep_db_free" },
        .{ &kpep_db_event, kperfdata, "kpep_db_event" },
        .{ &kpep_config_create, kperfdata, "kpep_config_create" },
        .{ &kpep_config_free, kperfdata, "kpep_config_free" },
        .{ &kpep_config_add_event, kperfdata, "kpep_config_add_event" },
        .{ &kpep_config_force_counters, kperfdata, "kpep_config_force_counters" },
        .{ &kpep_config_kpc_classes, kperfdata, "kpep_config_kpc_classes" },
        .{ &kpep_config_kpc_count, kperfdata, "kpep_config_kpc_count" },
        .{ &kpep_config_kpc_map, kperfdata, "kpep_config_kpc_map" },
        .{ &kpep_config_kpc, kperfdata, "kpep_config_kpc" },
    }) |entry| {
        const ptr, const lib, const name = entry;
        const sym = std.c.dlsym(lib, name) orelse return error.SymbolLoadFailed;
        ptr.* = @ptrCast(sym);
    }

    frameworks_loaded = true;
}
