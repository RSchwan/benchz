const std = @import("std");

const Allocator = std.mem.Allocator;
const Threaded = std.Io.Threaded;
const Clock = std.Io.Clock;
const Duration = std.Io.Duration;

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
};

pub const Error = error{InvalidSampleCount};

pub fn run(allocator: Allocator, name: []const u8, func: anytype, args: anytype, opts: Options) (Error || Allocator.Error)!Result {
    checkFuncAndArgs(@TypeOf(func), @TypeOf(args));

    // convert types in args tuple to match actual function parameters
    // e.g. convert comptime_int to u64
    const Params = std.meta.ArgsTuple(unwrapPointerType(@TypeOf(func)));
    const paramsLength = @typeInfo(unwrapPointerType(@TypeOf(func))).@"fn".params.len;
    var params: Params = undefined;
    inline for (0..paramsLength) |i| {
        params[i] = args[i];
    }
    // clobber parameters to prevent constant folding
    std.mem.doNotOptimizeAway(&params);

    var threaded_io: std.Io.Threaded = .init_single_threaded;
    const io = threaded_io.io();

    var min_run_time_ns = opts.min_run_time.toNanoseconds();
    if (opts.clock.resolution(io)) |clock_resolution| {
        min_run_time_ns = @max(min_run_time_ns, clock_resolution.toNanoseconds() * opts.clock_resolution_multiple);
    } else |_| {}

    var iterations = opts.min_iterations;
    var duration_ns: i96 = 0;
    while (true) {
        const start = opts.clock.now(io);
        for (0..iterations) |_| {
            try execute(func, params);
        }
        const end = opts.clock.now(io);
        duration_ns = start.durationTo(end).toNanoseconds();

        if (duration_ns >= min_run_time_ns or iterations >= opts.max_iterations) break;

        if (duration_ns == 0) {
            iterations *= 100;
        } else {
            const ratio = @as(f64, @floatFromInt(min_run_time_ns)) / @as(f64, @floatFromInt(duration_ns));
            const multiplier = @as(u64, @intFromFloat(std.math.ceil(ratio)));
            if (multiplier <= 1) {
                iterations *= 2;
            } else {
                iterations *= multiplier;
            }
        }
        iterations = @min(iterations, opts.max_iterations);
    }

    if (opts.samples == 0) return error.InvalidSampleCount;

    if (opts.samples > 1) {
        const durations_ns = try allocator.alloc(i96, opts.samples);
        defer allocator.free(durations_ns);

        durations_ns[0] = duration_ns;
        for (1..opts.samples) |i| {
            const start = opts.clock.now(io);
            for (0..iterations) |_| {
                try execute(func, params);
            }
            const end = opts.clock.now(io);
            durations_ns[i] = start.durationTo(end).toNanoseconds();
        }

        // sort duration samples
        std.mem.sort(i96, durations_ns, {}, std.sort.asc(i96));

        var durations_sum: i96 = 0;
        for (durations_ns) |duration| durations_sum += duration;
        const mean_ns = @as(f64, @floatFromInt(durations_sum)) / @as(f64, @floatFromInt(iterations * opts.samples));

        const median_ns: f64 = blk: {
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
        const std_ns = @sqrt(sum / @as(f64, @floatFromInt(opts.samples - 1)));

        return .{
            .name = name,
            .unit = opts.unit,
            .iterations = iterations,
            .samples = opts.samples,
            .min_ns = @as(f64, @floatFromInt(durations_ns[0])) / @as(f64, @floatFromInt(iterations)),
            .max_ns = @as(f64, @floatFromInt(durations_ns[opts.samples - 1])) / @as(f64, @floatFromInt(iterations)),
            .mean_ns = mean_ns,
            .median_ns = median_ns,
            .std_ns = std_ns,
        };
    }

    const mean_ns = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(iterations));

    return .{
        .name = name,
        .unit = opts.unit,
        .iterations = iterations,
        .samples = 1,
        .min_ns = mean_ns,
        .max_ns = mean_ns,
        .mean_ns = mean_ns,
        .median_ns = mean_ns,
        .std_ns = 0,
    };
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

inline fn execute(func: anytype, args: anytype) !void {
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
