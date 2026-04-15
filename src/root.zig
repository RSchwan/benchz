const std = @import("std");

const Allocator = std.mem.Allocator;
const Clock = std.Io.Clock;
const Duration = std.Io.Duration;

pub const perf = @import("perf.zig");
pub const stats = @import("stats.zig");
pub const PerfCounter = perf.PerfCounter;
pub const PerfCounts = perf.PerfCounts;

/// Configuration for a benchmark run.
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

/// Output of a benchmark run, including timing statistics and optional perf counter values.
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

/// Benchmark a function by measuring its execution time and optional hardware perf counters.
///
/// 1. Calibrates iteration count so total runtime meets `min_run_time`.
/// 2. Collects timing samples, computing min/max/mean/median/stddev per iteration.
/// 3. If perf counters are requested, calibrates measurement overhead and loop baseline,
///    then measures the function and corrects for both.
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

    // Calibration: increase iterations until total runtime exceeds min_run_time.
    // Uses saturating multiply to avoid overflow when scaling up aggressively.
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
    const durations_ns = try allocator.alloc(i96, opts.samples);
    defer allocator.free(durations_ns);

    durations_ns[0] = duration_ns;
    for (1..opts.samples) |i| {
        const start = opts.clock.now(io);
        try runIterations(iterations, func, params);
        const end = opts.clock.now(io);
        durations_ns[i] = start.durationTo(end).toNanoseconds();
    }

    const timing = stats.Stats(i96).fromSlice(durations_ns).?;
    const iterations_f: f64 = @floatFromInt(iterations);
    const min_ns = timing.min / iterations_f;
    const max_ns = timing.max / iterations_f;
    const mean_ns = timing.mean / iterations_f;
    const median_ns = timing.median / iterations_f;
    const std_ns = timing.std / iterations_f;

    // Perf counter measurement — runs after timing samples so caches are warm.
    // If more counters are requested than hardware supports, they are split into
    // groups and measured in separate passes.
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

            // Calibrate: measurement overhead (empty readBefore/readAfter), keeps lowest value.
            var measure_overhead = perf.RawCounts.initFill(null);
            for (0..perf.calibration_runs) |_| {
                try perf_state.readBefore();
                const raw = try perf_state.readAfter();
                for (counters) |c| {
                    const val = raw.get(c) orelse continue;
                    const cur = measure_overhead.get(c);
                    if (cur == null or val < cur.?) measure_overhead.set(c, val);
                }
            }

            // Calibrate: loop baseline (noop loop with fixed iteration count), keeps lowest value.
            var baseline = perf.RawCounts.initFill(null);
            for (0..perf.calibration_runs) |_| {
                try perf_state.readBefore();
                try runIterations(calibration_iters, noop, .{});
                const raw = try perf_state.readAfter();
                for (counters) |c| {
                    const val = raw.get(c) orelse continue;
                    const cur = baseline.get(c);
                    if (cur == null or val < cur.?) baseline.set(c, val);
                }
            }

            // Per-iteration loop cost: (loop_baseline - measurement_overhead) / iterations.
            // This isolates the cost of the loop machinery itself (branch, counter increment).
            var baseline_per_iter = PerfCounts.initFill(null);
            for (counters) |counter| {
                const base: f64 = @floatFromInt(baseline.get(counter) orelse continue);
                const measure_oh: f64 = if (measure_overhead.get(counter)) |v| @floatFromInt(v) else 0;
                const iter_f: f64 = @floatFromInt(calibration_iters);
                baseline_per_iter.set(counter, @max(0, (base - measure_oh) / iter_f));
            }

            // Actual measurement (single pass).
            try perf_state.readBefore();
            try runIterations(iterations, func, params);
            const raw = try perf_state.readAfter();

            // Correct and compute per-iteration values.
            for (counters) |counter| {
                const raw_val: f64 = @floatFromInt(raw.get(counter) orelse continue);
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

/// Trivial function used as the loop baseline during perf calibration.
fn noop() u8 {
    return 0;
}

/// Compile-time validation that func is callable with the given args tuple.
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

/// Run the function for the given number of iterations.
/// Must be noinline to ensure consistent code generation across all call sites —
/// without this, the compiler may generate different loop code at each inline site,
/// causing inconsistent perf counter readings between benchmarks.
noinline fn runIterations(iterations: u64, func: anytype, args: anytype) !void {
    std.mem.doNotOptimizeAway(&args);
    for (0..iterations) |_| {
        try runFunc(func, args);
    }
}

/// Call the function once, preventing the compiler from optimizing away the result.
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

test {
    _ = perf;
    _ = stats;
}
