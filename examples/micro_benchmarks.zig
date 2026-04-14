const std = @import("std");
const benchz = @import("benchz");

fn noop() u8 {
    return 0;
}

fn add(a: u64, b: u64) u64 {
    return a + b;
}

fn powerNaive(x: u64, n: u64) u64 {
    var result: u64 = 1;
    for (0..n) |_| {
        result *= x;
    }
    return result;
}

fn powerFast(x: u64, n: u64) u64 {
    var result: u64 = 1;
    var base = x;
    var exp = n;
    while (exp > 0) {
        if (exp % 2 == 1) result *= base;
        base *%= base;
        exp /= 2;
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var bench = try benchz.Context.init(allocator, .{});
    defer bench.deinit();

    const noopResult = try bench.run("noop", noop, .{}, .{});
    const addResult = try bench.run("add", add, .{ 1, 2 }, .{});
    const powerNaiveResult = try bench.run("powerNaive(2, 60)", powerNaive, .{ 2, 60 }, .{});
    const powerFastResult = try bench.run("powerFast(2, 60)", powerFast, .{ 2, 60 }, .{});

    const results = [_]benchz.Result{ noopResult, addResult, powerNaiveResult, powerFastResult };

    for (results) |result| {
        std.debug.print("{s}: {d:.2} ns/op ± {d:.2} ({} iterations)\n", .{ result.name, result.mean_ns, result.std_ns, result.iterations });

        inline for (@typeInfo(benchz.PerfCounter).@"enum".fields) |field| {
            const counter: benchz.PerfCounter = @enumFromInt(field.value);
            if (result.perf.get(counter)) |value| {
                std.debug.print("  {s}: {d:.2}\n", .{ field.name, value });
            }
        }
    }
}
