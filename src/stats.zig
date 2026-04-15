const std = @import("std");

/// Descriptive statistics computed over a data set.
pub fn Stats(comptime T: type) type {
    return struct {
        min: f64,
        max: f64,
        mean: f64,
        median: f64,
        std: f64,

        const Self = @This();

        /// Compute descriptive statistics over the given slice.
        /// Sorts the slice in place. Returns null for empty slices.
        pub fn fromSlice(data: []T) ?Self {
            if (data.len == 0) return null;

            std.mem.sortUnstable(T, data, {}, std.sort.asc(T));

            const n = data.len;

            var sum: f64 = 0;
            for (data) |v| sum += toF64(v);
            const mean: f64 = sum / @as(f64, @floatFromInt(n));

            const median: f64 = blk: {
                const mid = n / 2;
                if (n % 2 == 0) {
                    break :blk (toF64(data[mid - 1]) + toF64(data[mid])) / 2.0;
                } else {
                    break :blk toF64(data[mid]);
                }
            };

            var sq_sum: f64 = 0;
            for (data) |v| {
                const diff = toF64(v) - mean;
                sq_sum += diff * diff;
            }
            const std_dev: f64 = if (n > 1) @sqrt(sq_sum / (@as(f64, @floatFromInt(n)) - 1.0)) else 0;

            return .{
                .min = toF64(data[0]),
                .max = toF64(data[n - 1]),
                .mean = mean,
                .median = median,
                .std = std_dev,
            };
        }

        fn toF64(v: T) f64 {
            return switch (@typeInfo(T)) {
                .int, .comptime_int => @floatFromInt(v),
                .float, .comptime_float => @floatCast(v),
                else => @compileError("Stats requires an integer or float type, found '" ++ @typeName(T) ++ "'"),
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty slice returns null" {
    var data = [_]i64{};
    try testing.expect(Stats(i64).fromSlice(&data) == null);
}

test "single element" {
    var data = [_]i64{42};
    const s = Stats(i64).fromSlice(&data).?;
    try testing.expectEqual(@as(f64, 42), s.min);
    try testing.expectEqual(@as(f64, 42), s.max);
    try testing.expectEqual(@as(f64, 42), s.mean);
    try testing.expectEqual(@as(f64, 42), s.median);
    try testing.expectEqual(@as(f64, 0), s.std);
}

test "odd count: median is middle value" {
    var data = [_]i64{ 10, 30, 20 };
    const s = Stats(i64).fromSlice(&data).?;
    try testing.expectEqual(@as(f64, 20), s.median);
    try testing.expectEqual(@as(f64, 10), s.min);
    try testing.expectEqual(@as(f64, 30), s.max);
}

test "even count: median is average of two middle values" {
    var data = [_]i64{ 10, 40, 20, 30 };
    const s = Stats(i64).fromSlice(&data).?;
    try testing.expectEqual(@as(f64, 25), s.median);
}

test "identical values" {
    var data = [_]i64{ 7, 7, 7, 7 };
    const s = Stats(i64).fromSlice(&data).?;
    try testing.expectEqual(@as(f64, 7), s.min);
    try testing.expectEqual(@as(f64, 7), s.max);
    try testing.expectEqual(@as(f64, 7), s.mean);
    try testing.expectEqual(@as(f64, 7), s.median);
    try testing.expectEqual(@as(f64, 0), s.std);
}

test "known values: [1,2,3,4,5]" {
    var data = [_]i64{ 5, 3, 1, 4, 2 };
    const s = Stats(i64).fromSlice(&data).?;
    try testing.expectEqual(@as(f64, 1), s.min);
    try testing.expectEqual(@as(f64, 5), s.max);
    try testing.expectEqual(@as(f64, 3), s.mean);
    try testing.expectEqual(@as(f64, 3), s.median);
    // sample std = sqrt(10/4) = sqrt(2.5)
    try testing.expectApproxEqAbs(@as(f64, @sqrt(2.5)), s.std, 1e-10);
}

test "f64 type" {
    var data = [_]f64{ 1.5, 2.5, 3.5 };
    const s = Stats(f64).fromSlice(&data).?;
    try testing.expectEqual(@as(f64, 1.5), s.min);
    try testing.expectEqual(@as(f64, 3.5), s.max);
    try testing.expectEqual(@as(f64, 2.5), s.mean);
    try testing.expectEqual(@as(f64, 2.5), s.median);
    try testing.expectEqual(@as(f64, 1.0), s.std);
}

test "i96 type" {
    var data = [_]i96{ 100, 200, 300 };
    const s = Stats(i96).fromSlice(&data).?;
    try testing.expectEqual(@as(f64, 100), s.min);
    try testing.expectEqual(@as(f64, 300), s.max);
    try testing.expectEqual(@as(f64, 200), s.mean);
    try testing.expectEqual(@as(f64, 200), s.median);
    try testing.expectEqual(@as(f64, 100), s.std);
}
