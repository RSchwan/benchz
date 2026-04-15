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

fn fibRecursive(n: u32) u64 {
    if (n <= 1) return n;
    return fibRecursive(n - 1) + fibRecursive(n - 2);
}

fn fibIterative(n: u32) u64 {
    if (n <= 1) return n;
    var a: u64 = 0;
    var b: u64 = 1;
    for (1..n) |_| {
        const tmp = a + b;
        a = b;
        b = tmp;
    }
    return b;
}

fn sequentialScan(buf: []const u8) u8 {
    var sum: u8 = 0;
    for (buf[0..4096]) |b| {
        sum +%= b;
    }
    return sum;
}

fn pointerChase(chain: []const u32) u32 {
    var idx: u32 = 0;
    for (0..1024) |_| {
        idx = chain[idx];
    }
    return idx;
}

/// Access memory at page-sized (4KB) strides across a large buffer.
/// Each access hits a different page, thrashing the TLB.
fn tlbThrash(buf: []const u8) u8 {
    var sum: u8 = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 4096) {
        sum +%= buf[i];
    }
    return sum;
}

/// Build a random pointer-chase chain.
fn buildChain(allocator: std.mem.Allocator, len: u32) ![]u32 {
    const chain = try allocator.alloc(u32, len);
    // Initialize as identity permutation
    for (chain, 0..) |*c, i| c.* = @intCast(i);
    // Shuffle into a single cycle: swap each element with a random later one
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    var i: u32 = 0;
    while (i < len - 1) : (i += 1) {
        const j = random.intRangeAtMost(u32, i + 1, len - 1);
        const tmp = chain[i];
        chain[i] = chain[j];
        chain[j] = tmp;
    }
    return chain;
}

fn printResults(results: []const benchz.Result) void {
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const opts: benchz.Options = .{ .perf_counters = &.{
        .cycles,
        .branches,
        .instructions,
        .branch_misses,
        .cache_misses_l1d,
        .cache_misses_l1i,
        .cache_misses_llc,
        .tlb_misses_l1d,
        .tlb_misses_l1i,
    } };

    // --- Arithmetic benchmarks ---
    std.debug.print("=== Arithmetic ===\n", .{});
    const arith_results = [_]benchz.Result{
        try benchz.run(allocator, "noop", noop, .{}, opts),
        try benchz.run(allocator, "add", add, .{ 1, 2 }, opts),
        try benchz.run(allocator, "powerNaive(2, 60)", powerNaive, .{ 2, 60 }, opts),
        try benchz.run(allocator, "powerFast(2, 60)", powerFast, .{ 2, 60 }, opts),
        try benchz.run(allocator, "fibRecursive(10)", fibRecursive, .{10}, opts),
        try benchz.run(allocator, "fibIterative(10)", fibIterative, .{10}, opts),
    };
    printResults(&arith_results);

    // --- Memory benchmarks ---
    std.debug.print("\n=== Memory ===\n", .{});

    // 64MB buffer for cache/TLB tests (well beyond L1/L2/LLC)
    const buf_size = 64 * 1024 * 1024;
    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);
    @memset(buf, 0xAB); // touch all pages

    // 16M-entry pointer chase (~64MB of u32)
    const chain_len: u32 = 16 * 1024 * 1024;
    const chain = try buildChain(allocator, chain_len);
    defer allocator.free(chain);

    const mem_results = [_]benchz.Result{
        try benchz.run(allocator, "sequentialScan(64MB)", sequentialScan, .{buf}, opts),
        try benchz.run(allocator, "pointerChase(64MB)", pointerChase, .{chain}, opts),
        try benchz.run(allocator, "tlbThrash(64MB)", tlbThrash, .{buf}, opts),
    };
    printResults(&mem_results);
}
