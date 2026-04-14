const std = @import("std");
const linux = std.os.linux;
const p = @import("perf.zig");
const PerfCounter = p.PerfCounter;
const RawCounts = p.RawCounts;
const Error = p.Error;

const PerfEventConfig = struct {
    type: linux.PERF.TYPE,
    config: u64,
};

fn hwEvent(hw: linux.PERF.COUNT.HW) PerfEventConfig {
    return .{ .type = .HARDWARE, .config = @intFromEnum(hw) };
}

fn cacheEvent(
    cache_id: linux.PERF.COUNT.HW.CACHE,
    op: linux.PERF.COUNT.HW.CACHE.OP,
    result: linux.PERF.COUNT.HW.CACHE.RESULT,
) PerfEventConfig {
    return .{
        .type = .HW_CACHE,
        .config = @intFromEnum(cache_id) | (@as(u64, @intFromEnum(op)) << 8) | (@as(u64, @intFromEnum(result)) << 16),
    };
}

const event_config = std.enums.EnumArray(PerfCounter, PerfEventConfig).init(.{
    .cycles = hwEvent(.CPU_CYCLES),
    .instructions = hwEvent(.INSTRUCTIONS),
    .branches = hwEvent(.BRANCH_INSTRUCTIONS),
    .branch_misses = hwEvent(.BRANCH_MISSES),
    .cache_misses_l1d = cacheEvent(.L1D, .READ, .MISS),
    .cache_misses_l1i = cacheEvent(.L1I, .READ, .MISS),
    .cache_misses_llc = cacheEvent(.LL, .READ, .MISS),
    .tlb_misses_l1d = cacheEvent(.DTLB, .READ, .MISS),
    .tlb_misses_l1i = cacheEvent(.ITLB, .READ, .MISS),
});

const PERF_FORMAT_TOTAL_TIME_ENABLED = 1 << 0;
const PERF_FORMAT_TOTAL_TIME_RUNNING = 1 << 1;
const PERF_FORMAT_ID = 1 << 2;
const PERF_FORMAT_GROUP = 1 << 3;

const MAX_COUNTERS = 16;

/// Query the number of hardware performance counters available.
/// Uses perf_event_open probing: open events one by one until the kernel refuses.
pub fn maxSimultaneousCounters() Error!usize {
    // Try opening incrementing numbers of CPU_CYCLES events in a group.
    // When the kernel can't schedule them all, it will reject.
    var fds: [MAX_COUNTERS]linux.fd_t = .{-1} ** MAX_COUNTERS;
    defer for (&fds) |*fd| {
        if (fd.* != -1) _ = linux.close(fd.*);
    };

    var group_fd: linux.fd_t = -1;
    var count: usize = 0;

    for (0..MAX_COUNTERS) |i| {
        var attr = std.mem.zeroes(linux.perf_event_attr);
        attr.type = .HARDWARE;
        attr.config = @intFromEnum(linux.PERF.COUNT.HW.CPU_CYCLES);
        attr.flags.disabled = (group_fd == -1);
        attr.flags.exclude_kernel = true;
        attr.flags.exclude_hv = true;
        // Pin to avoid multiplexing — fail if hardware can't schedule
        attr.flags.pinned = (group_fd == -1);

        const rc = linux.perf_event_open(&attr, 0, -1, group_fd, 0);
        if (linux.errno(rc) != .SUCCESS) break;
        fds[i] = @intCast(rc);
        if (group_fd == -1) group_fd = fds[i];
        count += 1;
    }

    if (count == 0) return error.OpenFailed;
    return count;
}

pub const BackendState = struct {
    fds: [MAX_COUNTERS]linux.fd_t = .{-1} ** MAX_COUNTERS,
    ids: [MAX_COUNTERS]u64 = .{0} ** MAX_COUNTERS,
    requested: []const PerfCounter = &.{},

    pub fn init(counters: []const PerfCounter) Error!BackendState {
        if (counters.len == 0) return .{};
        if (counters.len > MAX_COUNTERS) return error.TooManyCounters;

        var state = BackendState{};
        state.requested = counters;

        var group_fd: linux.fd_t = -1;

        for (counters, 0..) |counter, i| {
            const ec = event_config.get(counter);
            var attr = std.mem.zeroes(linux.perf_event_attr);
            attr.type = ec.type;
            attr.config = ec.config;
            attr.read_format = PERF_FORMAT_GROUP |
                PERF_FORMAT_TOTAL_TIME_ENABLED |
                PERF_FORMAT_TOTAL_TIME_RUNNING |
                PERF_FORMAT_ID;
            attr.flags.disabled = (group_fd == -1);
            attr.flags.pinned = (group_fd == -1);
            attr.flags.exclude_kernel = true;
            attr.flags.exclude_hv = true;

            const rc = linux.perf_event_open(&attr, 0, -1, group_fd, 0);
            if (linux.errno(rc) != .SUCCESS) {
                if (linux.errno(rc) == .ACCES or linux.errno(rc) == .PERM)
                    return error.PermissionDenied;
                return error.OpenFailed;
            }
            state.fds[i] = @intCast(rc);

            // Get event ID
            var id: u64 = 0;
            const irc = linux.ioctl(state.fds[i], linux.IOCTL.IOR('$', 7, u64), @intFromPtr(&id));
            if (linux.errno(irc) != .SUCCESS) return error.IoctlFailed;
            state.ids[i] = id;

            if (group_fd == -1) group_fd = state.fds[i];
        }

        return state;
    }

    pub fn deinit(self: *BackendState) void {
        for (&self.fds) |*fd| {
            if (fd.* != -1) {
                _ = linux.close(fd.*);
                fd.* = -1;
            }
        }
    }

    pub fn readBefore(self: *BackendState) Error!void {
        if (self.requested.len == 0) return;
        const fd = self.fds[0];
        if (linux.errno(linux.ioctl(fd, linux.PERF.EVENT_IOC.RESET, 0)) != .SUCCESS)
            return error.IoctlFailed;
        if (linux.errno(linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, 0)) != .SUCCESS)
            return error.IoctlFailed;
    }

    /// Read counters and return raw totals (not per-iteration).
    pub fn readAfterRaw(self: *BackendState) Error!RawCounts {
        var result = RawCounts.initFill(null);
        if (self.requested.len == 0) return result;

        // Disable the group
        const fd = self.fds[0];
        if (linux.errno(linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, 0)) != .SUCCESS)
            return error.IoctlFailed;

        // Read the group data
        // Layout: nr, time_enabled, time_running, [nr]{value, id}
        const header_size = 3; // nr + time_enabled + time_running
        const entry_size = 2; // value + id
        const buf_len = header_size + MAX_COUNTERS * entry_size;
        var buf: [buf_len]u64 = .{0} ** buf_len;

        const read_size = @sizeOf(u64) * (header_size + self.requested.len * entry_size);
        const rc = linux.read(fd, @as([*]u8, @ptrCast(&buf))[0..read_size]);
        if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;

        if (buf[2] == 0) return result; // time_running == 0

        // Map values back to counters via IDs
        for (0..self.requested.len) |i| {
            const value = buf[header_size + i * entry_size];
            const id = buf[header_size + i * entry_size + 1];

            for (self.requested, 0..) |counter, j| {
                if (id == self.ids[j]) {
                    result.set(counter, value);
                    break;
                }
            }
        }

        return result;
    }
};
