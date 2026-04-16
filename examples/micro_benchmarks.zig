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
    for (buf[0..4096]) |byte| {
        sum +%= byte;
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const opts: benchz.Options = .{
        .perf_counters = &.{
            .cycles,
            .instructions,
            .branches,
            .branch_misses,
            // .cache_misses_l1d,
            // .cache_misses_l1i,
            // .cache_misses_llc,
            // .tlb_misses_l1d,
            // .tlb_misses_l1i,
        },
    };

    // Stream results as markdown to stdout
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var md = benchz.Markdown.init(&stdout_writer.interface);
    var report = benchz.Report.initWithWriter(allocator, &md.writer);
    defer report.deinit();

    // --- Arithmetic benchmarks ---
    const arith = try report.addGroup("Arithmetic");
    try arith.add(try benchz.run(allocator, "noop", noop, .{}, opts));
    try arith.add(try benchz.run(allocator, "add", add, .{ 1, 2 }, opts));
    try arith.add(try benchz.run(allocator, "powerNaive(2, 60)", powerNaive, .{ 2, 60 }, opts));
    try arith.add(try benchz.run(allocator, "powerFast(2, 60)", powerFast, .{ 2, 60 }, opts));

    // --- Fibonacci comparison ---
    const fib = try report.addGroup("Fibonacci(10)");
    try fib.addBaseline(try benchz.run(allocator, "fibRecursive", fibRecursive, .{10}, opts));
    try fib.add(try benchz.run(allocator, "fibIterative", fibIterative, .{10}, opts));

    // --- Memory benchmarks ---
    // 64MB buffer for cache/TLB tests (well beyond L1/L2/LLC)
    const buf_size = 64 * 1024 * 1024;
    const buf = try allocator.alloc(u8, buf_size);
    defer allocator.free(buf);
    @memset(buf, 0xAB); // touch all pages

    // 16M-entry pointer chase (~64MB of u32)
    const chain_len: u32 = 16 * 1024 * 1024;
    const chain = try buildChain(allocator, chain_len);
    defer allocator.free(chain);

    const mem = try report.addGroup("Memory (64MB)");
    try mem.addBaseline(try benchz.run(allocator, "sequentialScan", sequentialScan, .{buf}, opts));
    try mem.add(try benchz.run(allocator, "pointerChase", pointerChase, .{chain}, opts));
    try mem.add(try benchz.run(allocator, "tlbThrash", tlbThrash, .{buf}, opts));

    try report.finish();
    try stdout_writer.flush();
}
