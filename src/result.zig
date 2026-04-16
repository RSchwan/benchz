const Result = @This();

pub const PerfCounts = @import("perf.zig").PerfCounts;

name: []const u8,

iterations: u64,
samples: u64,

min_ns: f64,
max_ns: f64,
mean_ns: f64,
median_ns: f64,
std_ns: f64,

perf: PerfCounts = PerfCounts.initFill(null),
