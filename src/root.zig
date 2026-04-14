const std = @import("std");

const Allocator = std.mem.Allocator;
const Clock = std.Io.Clock;
const Duration = std.Io.Duration;

pub const perf = @import("perf.zig");
pub const PerfCounter = perf.PerfCounter;
pub const PerfCounts = perf.PerfCounts;

pub const ContextOptions = struct {
    perf_counters: []const PerfCounter = &perf.default_counters,
};

pub const Options = struct {
    unit: []const u8 = "op",
    clock: Clock = .awake,
    clock_resolution_multiple: u32 = 1000,
    min_run_time: Duration = Duration.fromMilliseconds(1),
    min_iterations: u64 = 1,
    max_iterations: u64 = 10_000_000,
    samples: u64 = 11,
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

pub const Context = struct {
    allocator: Allocator,
    perf_state: ?perf.PerfState = null,
    perf_counters: []const PerfCounter = &.{},

    // Calibration data (computed once in init, reused for all runs).
    measure_overhead: perf.RawCounts = perf.RawCounts.initFill(null),
    baseline_per_iter: PerfCounts = PerfCounts.initFill(null),

    pub fn init(allocator: Allocator, opts: ContextOptions) (Error || Allocator.Error)!Context {
        var ctx = Context{
            .allocator = allocator,
            .perf_counters = opts.perf_counters,
        };

        if (opts.perf_counters.len > 0) {
            ctx.perf_state = perf.PerfState.init(opts.perf_counters) catch |err| switch (err) {
                error.PermissionDenied => {
                    std.debug.print("warning: perf counters unavailable (permission denied, try running with sudo)\n", .{});
                    ctx.perf_counters = &.{};
                    return ctx;
                },
                else => return err,
            };

            try ctx.calibrate();
        }

        return ctx;
    }

    pub fn deinit(self: *Context) void {
        if (self.perf_state) |*ps| ps.deinit();
        self.perf_state = null;
    }

    fn calibrate(self: *Context) Error!void {
        var ps = &(self.perf_state orelse return);
        const counters = self.perf_counters;
        const calibration_iters: u64 = 10_000;

        // Measurement overhead: empty readBefore/readAfterRaw.
        for (0..perf.calibration_runs) |_| {
            try ps.readBefore();
            try ps.readAfterRaw();
            for (counters) |c| {
                const val = ps.raw_counts.get(c) orelse continue;
                const cur = self.measure_overhead.get(c);
                if (cur == null or val < cur.?) self.measure_overhead.set(c, val);
            }
        }

        // Loop baseline: noop loop with fixed iteration count.
        var baseline = perf.RawCounts.initFill(null);
        for (0..perf.calibration_runs) |_| {
            try ps.readBefore();
            try runIterations(calibration_iters, noop, .{});
            try ps.readAfterRaw();
            for (counters) |c| {
                const val = ps.raw_counts.get(c) orelse continue;
                const cur = baseline.get(c);
                if (cur == null or val < cur.?) baseline.set(c, val);
            }
        }

        // Per-iteration baseline for non-cycle counters.
        const cal_f: f64 = @floatFromInt(calibration_iters);
        for (counters) |c| {
            const base: f64 = @floatFromInt(baseline.get(c) orelse continue);
            const oh: f64 = if (self.measure_overhead.get(c)) |v| @floatFromInt(v) else 0;
            self.baseline_per_iter.set(c, @max(0, (base - oh) / cal_f));
        }
    }

    pub fn run(self: *Context, name: []const u8, func: anytype, args: anytype, opts: Options) (Error || Allocator.Error)!Result {
        if (opts.samples == 0) return error.InvalidSampleCount;

        checkFuncAndArgs(@TypeOf(func), @TypeOf(args));

        // convert args to concrete types, e.g., comptime_int to u64
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
            const durations_ns = try self.allocator.alloc(i96, opts.samples);
            defer self.allocator.free(durations_ns);

            durations_ns[0] = duration_ns;
            for (1..opts.samples) |i| {
                const start = opts.clock.now(io);
                try runIterations(iterations, func, params);
                const end = opts.clock.now(io);
                durations_ns[i] = start.durationTo(end).toNanoseconds();
            }

            std.mem.sort(i96, durations_ns, {}, std.sort.asc(i96));

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
            min_ns = mean_ns;
            max_ns = mean_ns;
            median_ns = mean_ns;
            std_ns = 0;
        }

        // Perf counter measurement (after timing samples so caches are warm).
        var perf_counts = PerfCounts.initFill(null);
        if (self.perf_state) |*ps| {
            try ps.readBefore();
            try runIterations(iterations, func, params);
            try ps.readAfterRaw();

            const iter_f: f64 = @floatFromInt(iterations);
            for (self.perf_counters) |counter| {
                const raw_val: f64 = @floatFromInt(ps.raw_counts.get(counter) orelse continue);
                const oh: f64 = if (self.measure_overhead.get(counter)) |v| @floatFromInt(v) else 0;
                if (counter == .cycles) {
                    // No correction for cycles — pipelining makes any
                    // baseline subtraction inaccurate, and raw values
                    // are already close to true per-iteration cost.
                    perf_counts.set(counter, @max(0, (raw_val - oh) / iter_f));
                } else {
                    const loop_oh = self.baseline_per_iter.get(counter) orelse 0;
                    perf_counts.set(counter, @max(0, (raw_val - oh) / iter_f - loop_oh));
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
};

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
