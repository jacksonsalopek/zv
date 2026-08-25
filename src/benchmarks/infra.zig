//! Benchmark infrastructure for zv vs libev
//!
//! Timing uses a monotonic clock. Comparisons are median-of-samples after
//! warmup. These benches measure the public APIs as they exist; they do not
//! prove application-level throughput.

const std = @import("std");
const builtin = @import("builtin");

pub const default_warmup: usize = 2;
pub const default_samples: usize = 5;

/// Monotonic timer via CLOCK_MONOTONIC. Wall-clock timestamps are not used.
pub const Timer = struct {
    start_ns: u64,

    pub fn start() !Timer {
        return .{ .start_ns = monotonicNs() };
    }

    pub fn read(self: *Timer) u64 {
        const now = monotonicNs();
        return if (now > self.start_ns) now - self.start_ns else 0;
    }
};

fn monotonicNs() u64 {
    if (builtin.os.tag != .linux) {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    if (builtin.os.tag != .linux) return;
    var req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

/// Prevent the compiler from deleting work whose result appears unused.
pub fn keep(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}

pub const Stats = struct {
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    sample_count: usize,
};

pub fn statsFromSamples(samples: []u64) Stats {
    std.debug.assert(samples.len > 0);
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    var total: u64 = 0;
    for (samples) |s| total += s;

    return .{
        .median_ns = samples[samples.len / 2],
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .mean_ns = total / samples.len,
        .sample_count = samples.len,
    };
}

pub fn throughput(iterations: usize, ns: u64) ?f64 {
    if (ns == 0) return null;
    return @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(ns)) / 1_000_000_000.0);
}

/// Run `timed` after `warmup` untimed calls and collect `sample_count` timings.
pub fn measure(
    allocator: std.mem.Allocator,
    warmup: usize,
    sample_count: usize,
    ctx: anytype,
    comptime timed: fn (@TypeOf(ctx)) anyerror!void,
) !Stats {
    std.debug.assert(sample_count > 0);

    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        try timed(ctx);
    }

    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    for (samples) |*sample| {
        var timer = try Timer.start();
        try timed(ctx);
        sample.* = timer.read();
        keep(sample.*);
    }

    return statsFromSamples(samples);
}

/// Memory allocation tracker for profiling zv heap usage.
/// Does not observe libc malloc used by libev — do not compare the two.
pub const AllocTracker = struct {
    parent_allocator: std.mem.Allocator,
    allocations: usize = 0,
    deallocations: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    peak_memory: usize = 0,
    current_memory: usize = 0,

    pub const Snapshot = struct {
        allocations: usize,
        deallocations: usize,
        bytes_allocated: usize,
        bytes_freed: usize,
        peak_memory: usize,
        current_memory: usize,
        net_allocations: isize,
        net_bytes: isize,
    };

    pub fn allocator(self: *AllocTracker) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *AllocTracker = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            self.allocations += 1;
            self.bytes_allocated += len;
            self.current_memory += len;
            self.notePeak();
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *AllocTracker = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) self.adjustLen(buf.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *AllocTracker = @ptrCast(@alignCast(ctx));
        self.deallocations += 1;
        self.bytes_freed += buf.len;
        self.current_memory -= buf.len;
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *AllocTracker = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null) self.adjustLen(buf.len, new_len);
        return result;
    }

    fn adjustLen(self: *AllocTracker, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const diff = new_len - old_len;
            self.bytes_allocated += diff;
            self.current_memory += diff;
            self.notePeak();
        } else if (new_len < old_len) {
            const diff = old_len - new_len;
            self.bytes_freed += diff;
            self.current_memory -= diff;
        }
    }

    fn notePeak(self: *AllocTracker) void {
        if (self.current_memory > self.peak_memory) {
            self.peak_memory = self.current_memory;
        }
    }

    pub fn snapshot(self: *const AllocTracker) Snapshot {
        return .{
            .allocations = self.allocations,
            .deallocations = self.deallocations,
            .bytes_allocated = self.bytes_allocated,
            .bytes_freed = self.bytes_freed,
            .peak_memory = self.peak_memory,
            .current_memory = self.current_memory,
            .net_allocations = @as(isize, @intCast(self.allocations)) - @as(isize, @intCast(self.deallocations)),
            .net_bytes = @as(isize, @intCast(self.bytes_allocated)) - @as(isize, @intCast(self.bytes_freed)),
        };
    }

    pub fn reset(self: *AllocTracker) void {
        self.allocations = 0;
        self.deallocations = 0;
        self.bytes_allocated = 0;
        self.bytes_freed = 0;
        self.current_memory = 0;
        self.peak_memory = 0;
    }
};

pub const Result = struct {
    name: []const u8,
    time_ns: u64,
    allocations: usize = 0,
    bytes_allocated: usize = 0,
    peak_memory: usize = 0,
    iterations: usize = 1,
    throughput: ?f64 = null,
    sample_min_ns: ?u64 = null,
    sample_max_ns: ?u64 = null,
    sample_count: usize = 1,
    unit: []const u8 = "ops/sec",

    pub fn fromStats(name: []const u8, stats: Stats, iterations: usize, unit: []const u8) Result {
        return .{
            .name = name,
            .time_ns = stats.median_ns,
            .iterations = iterations,
            .throughput = throughput(iterations, stats.median_ns),
            .sample_min_ns = stats.min_ns,
            .sample_max_ns = stats.max_ns,
            .sample_count = stats.sample_count,
            .unit = unit,
        };
    }

    pub fn print(self: Result, writer: anytype) !void {
        try writer.print("\n{s}:\n", .{self.name});
        if (self.time_ns == 0 and self.throughput == null) {
            // Memory-only result
        } else if (self.sample_count > 1) {
            try writer.print("  Time (median of {d}): {d} ns ({d:.2} ms)\n", .{
                self.sample_count,
                self.time_ns,
                @as(f64, @floatFromInt(self.time_ns)) / 1_000_000.0,
            });
            try self.printSampleRange(writer);
        } else {
            try writer.print("  Time:        {d} ns ({d:.2} ms)\n", .{
                self.time_ns,
                @as(f64, @floatFromInt(self.time_ns)) / 1_000_000.0,
            });
        }

        if (self.iterations > 1 and self.time_ns > 0) {
            try writer.print("  Per iter:    {d} ns\n", .{self.time_ns / self.iterations});
        }

        if (self.throughput) |t| {
            try writer.print("  Throughput:  {d:.2} {s}\n", .{ t, self.unit });
        }

        if (self.allocations > 0) {
            try writer.print("  Allocations: {d}\n", .{self.allocations});
            try writer.print("  Bytes:       {d} ({d:.2} KB)\n", .{
                self.bytes_allocated,
                @as(f64, @floatFromInt(self.bytes_allocated)) / 1024.0,
            });
        }

        if (self.peak_memory > 0) {
            try writer.print("  Peak memory: {d} ({d:.2} KB)\n", .{
                self.peak_memory,
                @as(f64, @floatFromInt(self.peak_memory)) / 1024.0,
            });
        }
    }

    /// Compare wall time. `baseline` is libev, `candidate` is zv.
    /// Does not compare memory: libev malloc is not tracked.
    pub fn compareTime(baseline: Result, candidate: Result, writer: anytype) !void {
        try writer.print("\nComparison ({s} vs {s}):\n", .{ baseline.name, candidate.name });
        if (baseline.time_ns == 0 or candidate.time_ns == 0) {
            try writer.writeAll("  ⚠️  skipped: a timed region was 0 ns (measurement too coarse)\n");
            return;
        }

        if (candidate.time_ns < baseline.time_ns) {
            const speedup = @as(f64, @floatFromInt(baseline.time_ns)) / @as(f64, @floatFromInt(candidate.time_ns));
            try writer.print("  zv {d:.2}x faster on this measurement (median wall time)\n", .{speedup});
        } else if (candidate.time_ns > baseline.time_ns) {
            const slowdown = @as(f64, @floatFromInt(candidate.time_ns)) / @as(f64, @floatFromInt(baseline.time_ns));
            try writer.print("  zv {d:.2}x slower on this measurement (median wall time)\n", .{slowdown});
        } else {
            try writer.writeAll("  equal median wall time\n");
        }
        try writer.writeAll("  (single-machine, not a published result; see methodology)\n");
    }

    fn printSampleRange(self: Result, writer: anytype) !void {
        const mn = self.sample_min_ns orelse return;
        const mx = self.sample_max_ns orelse return;
        try writer.print("  Sample range: {d}–{d} ns\n", .{ mn, mx });
    }
};

pub fn printMethodology(writer: anytype) !void {
    try writer.writeAll(
        \\
        \\Methodology (read before citing numbers)
        \\----------------------------------------
        \\- Both zv and the harness are compiled ReleaseFast; libev C wrapper is -O3 -DNDEBUG.
        \\- zv uses libc malloc (c_allocator) here so allocator choice is not the variable.
        \\- Timings are median of several samples after warmup, using a monotonic clock.
        \\- Empty-loop `run(.nowait)` with no watchers returns without polling on both sides.
        \\- libev and zv defer epoll_ctl until run (fd_reify). IO add/modify/remove
        \\  therefore include one nowait flush on both sides.
        \\- Memory figures are zv heap via AllocTracker only. libev malloc is not measured.
        \\- No CPU pinning, no isolation from other processes. Do not cite as product numbers.
        \\- Errors are not dropped: a failed start/stop/run fails the benchmark.
        \\- zv `select` wait is a stub (always 0 events). This suite uses selectBest()
        \\  (epoll/kqueue/poll) and refuses to run as a libev comparison on select.
        \\
    );
}

test "Timer measures elapsed time" {
    const testing = std.testing;
    var timer = try Timer.start();
    sleepNs(1_000_000);
    try testing.expect(timer.read() >= 1_000_000);
}

test "AllocTracker tracks allocations and peak" {
    const testing = std.testing;
    var tracker = AllocTracker{ .parent_allocator = testing.allocator };
    const tracked = tracker.allocator();

    const buf = try tracked.alloc(u8, 100);
    defer tracked.free(buf);

    const snap = tracker.snapshot();
    try testing.expectEqual(@as(usize, 1), snap.allocations);
    try testing.expect(snap.bytes_allocated >= 100);
    try testing.expect(snap.peak_memory >= 100);
}

test "statsFromSamples uses median not mean" {
    const testing = std.testing;
    var samples = [_]u64{ 10, 1000, 20, 30, 40 };
    const stats = statsFromSamples(&samples);
    try testing.expectEqual(@as(u64, 30), stats.median_ns);
    try testing.expectEqual(@as(u64, 10), stats.min_ns);
    try testing.expectEqual(@as(u64, 1000), stats.max_ns);
}

test "throughput is null for zero duration" {
    const testing = std.testing;
    try testing.expect(throughput(100, 0) == null);
    const t = throughput(1000, 1_000_000_000).?;
    try testing.expectApproxEqAbs(@as(f64, 1000.0), t, 0.01);
}

test "measure warms up then records samples" {
    const testing = std.testing;
    const Ctx = struct { hits: *usize };
    var hits: usize = 0;
    const timed = struct {
        fn run(ctx: Ctx) !void {
            ctx.hits.* += 1;
        }
    }.run;
    const stats = try measure(testing.allocator, 2, 3, Ctx{ .hits = &hits }, timed);
    try testing.expectEqual(@as(usize, 5), hits);
    try testing.expectEqual(@as(usize, 3), stats.sample_count);
}
