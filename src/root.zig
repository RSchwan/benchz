const std = @import("std");

const Allocator = std.mem.Allocator;
const Clock = std.Io.Clock;
const Duration = std.Io.Duration;

pub const perf = @import("perf.zig");
pub const PerfCounter = perf.PerfCounter;
pub const PerfCounts = perf.PerfCounts;

pub const Options = struct {
    unit: []const u8 = "op",
    clock: Clock = .awake,
    clock_resolution_multiple: u32 = 1000,
    min_run_time: Duration = Duration.fromMilliseconds(1),
    min_iterations: u64 = 1,
    max_iterations: u64 = 10_000_000,
    samples: u64 = 11,
    perf_counters: []const PerfCounter = &perf.default_counters,
};

pub const Result = struct {
    name: []const u8,
    unit: []const u8,

    iterations: u64,
    samples: u64,

    min_ns: f64,
    max_ns: f64,
    mean_ns: f64,
    median_ns: f64,
    std_ns: f64,

    perf: PerfCounts = PerfCounts.initFill(null),
};

pub const Error = error{InvalidSampleCount} || perf.Error;

pub fn run(allocator: Allocator, name: []const u8, func: anytype, args: anytype, opts: Options) (Error || Allocator.Error)!Result {
    if (opts.samples == 0) return error.InvalidSampleCount;

    checkFuncAndArgs(@TypeOf(func), @TypeOf(args));

    const Params = std.meta.ArgsTuple(unwrapPointerType(@TypeOf(func)));
    const params_len = @typeInfo(unwrapPointerType(@TypeOf(func))).@"fn".params.len;
    var params: Params = undefined;
    inline for (0..params_len) |i| {
        params[i] = args[i];
    }

    var threaded_io: std.Io.Threaded = .init_single_threaded;
    const io = threaded_io.io();

    var min_run_time_ns = opts.min_run_time.toNanoseconds();
    if (opts.clock.resolution(io)) |clock_resolution| {
        min_run_time_ns = @max(min_run_time_ns, clock_resolution.toNanoseconds() * opts.clock_resolution_multiple);
    } else |_| {}

    // Calibration: determine iteration count
    var iterations = opts.min_iterations;
    var duration_ns: i96 = 0;
    while (true) {
        const start = opts.clock.now(io);
        try runIterations(iterations, func, params);
        const end = opts.clock.now(io);
        duration_ns = start.durationTo(end).toNanoseconds();

        if (duration_ns >= min_run_time_ns or iterations >= opts.max_iterations) break;

        if (duration_ns == 0) {
            iterations = @min(iterations *| 100, opts.max_iterations);
        } else {
            const ratio = @as(f64, @floatFromInt(min_run_time_ns)) / @as(f64, @floatFromInt(duration_ns));
            const multiplier = @as(u64, @intFromFloat(@min(std.math.ceil(ratio), @as(f64, @floatFromInt(opts.max_iterations)))));
            iterations = @min(iterations *| @max(multiplier, 2), opts.max_iterations);
        }
    }

    // Timing samples
    var min_ns: f64 = undefined;
    var max_ns: f64 = undefined;
    var mean_ns: f64 = undefined;
    var median_ns: f64 = undefined;
    var std_ns: f64 = undefined;

    if (opts.samples > 1) {
        const durations_ns = try allocator.alloc(i96, opts.samples);
        defer allocator.free(durations_ns);

        durations_ns[0] = duration_ns;
        for (1..opts.samples) |i| {
            const start = opts.clock.now(io);
            try runIterations(iterations, func, params);
            const end = opts.clock.now(io);
            durations_ns[i] = start.durationTo(end).toNanoseconds();
        }

        std.mem.sortUnstable(i96, durations_ns, {}, std.sort.asc(i96));

        var durations_sum: i96 = 0;
        for (durations_ns) |duration| durations_sum += duration;
        mean_ns = @as(f64, @floatFromInt(durations_sum)) / @as(f64, @floatFromInt(iterations * opts.samples));

        median_ns = blk: {
            const mid = durations_ns.len / 2;
            if (durations_ns.len % 2 == 0) {
                break :blk @as(f64, @floatFromInt(durations_ns[mid - 1] + durations_ns[mid])) / @as(f64, @floatFromInt(iterations * 2));
            } else {
                break :blk @as(f64, @floatFromInt(durations_ns[mid])) / @as(f64, @floatFromInt(iterations));
            }
        };

        var sum: f64 = 0;
        for (durations_ns) |duration| {
            const diff = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(iterations)) - mean_ns;
            sum += diff * diff;
        }
        std_ns = @sqrt(sum / @as(f64, @floatFromInt(opts.samples - 1)));

        min_ns = @as(f64, @floatFromInt(durations_ns[0])) / @as(f64, @floatFromInt(iterations));
        max_ns = @as(f64, @floatFromInt(durations_ns[opts.samples - 1])) / @as(f64, @floatFromInt(iterations));
    } else {
        mean_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(iterations));
        median_ns = mean_ns;
        std_ns = 0;
        min_ns = mean_ns;
        max_ns = mean_ns;
    }

    // Perf counter measurement
    var perf_counts = PerfCounts.initFill(null);
    if (opts.perf_counters.len > 0) perf_blk: {
        const calibration_iters: u64 = 10_000;
        const groups = perf.groupCounters(opts.perf_counters) catch |err| {
            if (err == error.PermissionDenied) {
                std.log.warn("perf counters unavailable (permission denied, try running with sudo)", .{});
                break :perf_blk;
            }
            return err;
        };

        for (groups.slice()) |*group| {
            const counters = group.slice();

            var perf_state = perf.PerfState.init(counters) catch |err| {
                if (err == error.PermissionDenied) {
                    std.log.warn("perf counters unavailable (permission denied, try running with sudo)", .{});
                    break :perf_blk;
                }
                return err;
            };
            defer perf_state.deinit();

            // Calibrate: measurement overhead (empty readBefore/readAfterRaw), keeps lowest value.
            var measure_overhead = perf.RawCounts.initFill(null);
            for (0..perf.calibration_runs) |_| {
                try perf_state.readBefore();
                try perf_state.readAfterRaw();
                for (counters) |c| {
                    const val = perf_state.raw_counts.get(c) orelse continue;
                    const cur = measure_overhead.get(c);
                    if (cur == null or val < cur.?) measure_overhead.set(c, val);
                }
            }

            // Calibrate: loop baseline (noop loop with fixed iteration count), keeps lowest value.
            var baseline = perf.RawCounts.initFill(null);
            for (0..perf.calibration_runs) |_| {
                try perf_state.readBefore();
                try runIterations(calibration_iters, noop, .{});
                try perf_state.readAfterRaw();
                for (counters) |c| {
                    const val = perf_state.raw_counts.get(c) orelse continue;
                    const cur = baseline.get(c);
                    if (cur == null or val < cur.?) baseline.set(c, val);
                }
            }

            // Per-iteration baseline for non-cycle counters.
            var baseline_per_iter = PerfCounts.initFill(null);
            for (counters) |counter| {
                const base: f64 = @floatFromInt(baseline.get(counter) orelse continue);
                const measure_oh: f64 = if (measure_overhead.get(counter)) |v| @floatFromInt(v) else 0;
                const iter_f: f64 = @floatFromInt(iterations);
                baseline_per_iter.set(counter, @max(0, (base - measure_oh) / iter_f));
            }

            // Actual measurement (single pass).
            try perf_state.readBefore();
            try runIterations(iterations, func, params);
            try perf_state.readAfterRaw();

            // Correct and compute per-iteration values.
            for (counters) |counter| {
                const raw_val: f64 = @floatFromInt(perf_state.raw_counts.get(counter) orelse continue);
                const measure_oh: f64 = if (measure_overhead.get(counter)) |v| @floatFromInt(v) else 0;
                const iter_f: f64 = @floatFromInt(iterations);
                if (counter == .cycles) {
                    // Don't correct loop overhead for cycles, because the CPU pipelines the loop overhead into the function execution
                    perf_counts.set(counter, @max(0, (raw_val - measure_oh) / iter_f));
                } else {
                    const loop_oh = baseline_per_iter.get(counter) orelse 0;
                    perf_counts.set(counter, @max(0, (raw_val - measure_oh) / iter_f - loop_oh));
                }
            }
        }
    }

    return .{
        .name = name,
        .unit = opts.unit,
        .iterations = iterations,
        .samples = opts.samples,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .median_ns = median_ns,
        .std_ns = std_ns,
        .perf = perf_counts,
    };
}

fn noop() u8 {
    return 0;
}

fn checkFuncAndArgs(comptime FuncType: type, comptime ArgsType: type) void {
    if (@typeInfo(unwrapPointerType(FuncType)) != .@"fn") {
        @compileError("func must be a function or function pointer, found '" ++ @typeName(FuncType) ++ "'");
    }
    if (@typeInfo(ArgsType) != .@"struct" or !@typeInfo(ArgsType).@"struct".is_tuple) {
        @compileError("args must be a tuple, found '" ++ @typeName(ArgsType) ++ "'");
    }

    const params_len = @typeInfo(unwrapPointerType(FuncType)).@"fn".params.len;
    const args_len = @typeInfo(ArgsType).@"struct".fields.len;

    if (params_len != args_len) {
        @compileError(std.fmt.comptimePrint(
            "function expects {d} arguments, but args tuple has {d}",
            .{ params_len, args_len },
        ));
    }
}

fn unwrapPointerType(comptime T: type) type {
    if (@typeInfo(T) == .pointer) return @typeInfo(T).pointer.child;
    return T;
}

noinline fn runIterations(iterations: u64, func: anytype, args: anytype) !void {
    std.mem.doNotOptimizeAway(&args);
    for (0..iterations) |_| {
        try runFunc(func, args);
    }
}

inline fn runFunc(func: anytype, args: anytype) !void {
    const FnType = unwrapPointerType(@TypeOf(func));
    const return_type = @typeInfo(FnType).@"fn".return_type.?;

    if (@typeInfo(return_type) == .error_union) {
        const result = try @call(.auto, func, args);
        std.mem.doNotOptimizeAway(result);
    } else {
        const result = @call(.auto, func, args);
        std.mem.doNotOptimizeAway(result);
    }
}
