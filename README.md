# benchz

A micro-benchmarking library for Zig with hardware performance counter support on **both Linux and macOS** — including Apple Silicon.

Most benchmarking tools only support perf counters on Linux via `perf_event_open`. benchz also supports macOS by using Apple's private `kpc`/`kperf` API, giving you access to cycle counts, instruction counts, branch misses, cache misses, and TLB misses on M-series chips. No kernel extensions or DTrace required.

## Features

- **Hardware perf counters** — cycles, instructions, branches, cache misses, TLB misses on Linux (`perf_event_open`) and macOS (`kpc`/`kperf`, including Apple Silicon)
- **Automatic calibration** — determines iteration count to meet minimum run time
- **Statistical output** — min, max, mean, median, and standard deviation
- **Grouped benchmarks** — organize benchmarks into named groups with optional baseline comparison
- **Multiple output formats** — Markdown (terminal-friendly), CSV, and JSON
- **Streaming output** — results appear as benchmarks complete, no need to wait for the full suite

## Quick Start

Add benchz to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/rschwan/benchz
```

Then in your `build.zig`:

```zig
const benchz = b.dependency("benchz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("benchz", benchz.module("benchz"));
```

## Usage

This example partitions 32K bytes into "small" (<128) and "large" (>=128) arrays.
The same function runs on the same data, but sorted vs shuffled. With sorted input,
all small values come first, then all large values: two long predictable runs. With
shuffled input, the branch outcome at each element is essentially random.

```zig
const std = @import("std");
const benchz = @import("benchz");

/// Partition values into small (<128) and large (>=128) arrays.
fn partition(data: []const u8, small: []u8, large: []u8) void {
    var si: usize = 0;
    var li: usize = 0;
    for (data) |val| {
        if (val < 128) {
            small[si] = val;
            si += 1;
        } else {
            large[li] = val;
            li += 1;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const size = 32 * 1024;

    // Sorted data: all small values first, then large — predictable branches
    const sorted = try allocator.alloc(u8, size);
    defer allocator.free(sorted);
    var rng = std.Random.DefaultPrng.init(42);
    for (sorted) |*v| v.* = rng.random().int(u8);
    std.mem.sort(u8, sorted, {}, std.sort.asc(u8));

    // Shuffled data: same values, random order — unpredictable branches
    const shuffled = try allocator.dupe(u8, sorted);
    defer allocator.free(shuffled);
    rng.random().shuffle(u8, shuffled);

    // Output buffers for the partition
    const buf_a = try allocator.alloc(u8, size);
    defer allocator.free(buf_a);
    const buf_b = try allocator.alloc(u8, size);
    defer allocator.free(buf_b);

    // Set up streaming markdown output
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var md = benchz.Markdown.init(&stdout_writer.interface);
    var report = benchz.Report.initWithWriter(allocator, &md.writer);
    defer report.deinit();

    const opts: benchz.Options = .{
        .perf_counters = &.{ .cycles, .instructions, .branches, .branch_misses },
    };

    const group = try report.addGroup("Branch prediction");
    try group.addBaseline(try benchz.run(allocator, "sorted", partition, .{ sorted, buf_a, buf_b }, opts));
    try group.add(try benchz.run(allocator, "shuffled", partition, .{ shuffled, buf_a, buf_b }, opts));

    try report.finish();
    try stdout_writer.flush();
}
```

Output (on MacBook Pro, `sudo` required for perf counters):

```
## Branch prediction

| Benchmark                      |       time | vs baseline | iterations |     cycles |     instrs |   branches |    br miss |
|--------------------------------|-----------:|------------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| sorted                         |   18.87 us |  (baseline) |         75 |   45171.47 |  188434.51 |   40964.05 |       4.61 |
| shuffled                       |  168.21 us |     +791.7% |          6 |  449257.67 |  193605.00 |   43635.50 |   15735.00 |
```

Nearly identical instruction and branch counts, but the shuffled version has 36% branch misses, causing an 8x slowdown.

## Output Formats

### Markdown (default)

Streaming-friendly, aligned for terminal display:

```
## Arithmetic

| Benchmark                      |       time | iterations |     cycles |     instrs |   branches |    br miss |
|--------------------------------|-----------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| noop                           |    0.84 ns |    1981276 |       2.00 |       0.00 |       0.00 |       0.00 |
| add                            |    0.85 ns |    2375114 |       2.01 |       2.00 |       0.00 |       0.00 |
| powerNaive(2, 60)              |    8.00 ns |     129744 |      19.11 |      52.01 |      15.00 |       0.00 |
| powerFast(2, 60)               |    6.90 ns |     145590 |      16.56 |      63.00 |       8.00 |       0.00 |


## Fibonacci(10)

| Benchmark                      |       time | vs baseline | iterations |     cycles |     instrs |   branches |    br miss |
|--------------------------------|-----------:|------------:|-----------:|-----------:|-----------:|-----------:|-----------:|
| fibRecursive                   |  264.44 ns |  (baseline) |       4472 |     627.79 |    1831.01 |     355.00 |       0.01 |
| fibIterative                   |    4.28 ns |      -98.4% |     218944 |      10.01 |      35.00 |       6.00 |       0.00 |
```

Time units scale automatically: ns, us, ms, s.

### CSV

All columns always present for consistent machine parsing:

```zig
var csv = benchz.Csv.init(&out);
var report = benchz.Report.initWithWriter(allocator, &csv.writer);
```

### JSON

Fully streamed, results written as they complete:

```zig
var json = benchz.Json.init(&out);
var report = benchz.Report.initWithWriter(allocator, &json.writer);
```

### Batch Output

Write a completed report in any format without streaming:

```zig
var report = benchz.Report.init(allocator);
defer report.deinit();

// ... add benchmarks ...

try benchz.Markdown.writeReport(&report, &out);
try benchz.Csv.writeReport(&report, &out);
try benchz.Json.writeReport(&report, &out);
```

## Grouping and Baselines

Organize benchmarks into named groups with optional baseline comparison:

```zig
// Ungrouped results (implicit unnamed group)
try report.addBaseline(try benchz.run(allocator, "baseline", func, .{}, .{}));
try report.add(try benchz.run(allocator, "variant", func2, .{}, .{}));

// Named group
const group = try report.addGroup("Sorting");
try group.addBaseline(try benchz.run(allocator, "std.sort", stdSort, .{data}, .{}));
try group.add(try benchz.run(allocator, "mySort", mySort, .{data}, .{}));
```

The baseline must be the first result added to a group. Subsequent results show a relative percentage comparison.

## Hardware Performance Counters

benchz gives you access to CPU hardware performance counters on both Linux and macOS. Most Zig and C benchmarking tools rely on Linux's `perf_event_open` and leave macOS users without counter support. benchz bridges this gap using Apple's private `kpc`/`kperf` framework, which works on both Intel Macs and Apple Silicon.

Enable counters via the `Options` struct:

```zig
const opts: benchz.Options = .{
    .perf_counters = &.{
        .cycles,
        .instructions,
        .branches,
        .branch_misses,
        .cache_misses_l1d,
    },
};
const result = try benchz.run(allocator, "bench", func, .{}, opts);
```

Available counters:

| Counter | Description |
|---------|-------------|
| `cycles` | CPU clock cycles |
| `instructions` | Instructions retired |
| `branches` | Branch instructions |
| `branch_misses` | Mispredicted branches |
| `cache_misses_l1d` | L1 data cache misses |
| `cache_misses_l1i` | L1 instruction cache misses |
| `cache_misses_llc` | Last-level cache misses |
| `tlb_misses_l1d` | L1 data TLB misses |
| `tlb_misses_l1i` | L1 instruction TLB misses |

### Platform Notes

- **Linux** — Uses `perf_event_open`. May require `sudo` or `sysctl kernel.perf_event_paranoid=1`.
- **macOS** — Uses Apple's `kpc`/`kperf` private API. Requires `sudo`. Works on both Intel and Apple Silicon. No kernel extensions or DTrace needed.
- **Other platforms** — Timing works everywhere; perf counters are silently skipped with a warning.

## Configuration

The `Options` struct controls benchmark behavior:

```zig
const opts: benchz.Options = .{
    .clock = .awake,                                     // clock source
    .min_run_time = std.Io.Duration.fromMilliseconds(1), // minimum time per calibration
    .min_iterations = 1,                                 // minimum iteration count
    .max_iterations = 10_000_000,                        // cap on iterations
    .samples = 11,                                       // number of timing samples
    .perf_counters = &.{},                               // hardware counters to measure
};
```

## Acknowledgments

This project has been inspired by:

- [bench](https://github.com/pyk/bench) — Zig benchmarking library
- [nanobench](https://github.com/martinus/nanobench) — C++ micro-benchmarking with perf counter support
- [Google Benchmark](https://github.com/google/benchmark) — C++ benchmarking framework
- [ibireme's kpc demo](https://gist.github.com/ibireme/173517c208c7dc333ba962c1f0d67d12) — Apple Silicon performance counter access via kpc/kperf
- [mperf](https://github.com/tmcgilchrist/mperf) — macOS performance counter library

## License

MIT
