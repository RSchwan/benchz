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
        base *= base;
        exp /= 2;
    }
    return result;
}

pub fn main() !void {
    const noopResult = try benchz.run("noop", noop, .{}, .{});
    const addResult = try benchz.run("add", add, .{ 1, 2 }, .{});
    const powerNativeResult = try benchz.run("powerNaive(2, 60)", powerNaive, .{ 2, 60 }, .{});
    const powerFastResult = try benchz.run("powerFast(2, 60)", powerFast, .{ 2, 60 }, .{});

    const results = [_]benchz.Result{ noopResult, addResult, powerNativeResult, powerFastResult };

    for (results) |result| {
        std.debug.print("{s}: {} ({}) - {}\n", .{ result.name, result.mean_ns, result.std_ns, result.iterations });
    }
}
