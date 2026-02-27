//! Benchmark infrastructure for zv
//!
//! Common utilities for performance testing and comparison with libev.

const std = @import("std");

pub const loop_throughput = @import("loop_throughput.zig");
pub const io_operations = @import("io_operations.zig");
pub const timer_accuracy = @import("timer_accuracy.zig");
pub const memory_usage = @import("memory_usage.zig");
pub const scaling = @import("scaling.zig");

/// High-precision timer for benchmarking
pub const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        return Timer{
            .start_time = std.time.nanoTimestamp(),
        };
    }

    pub fn read(self: Timer) u64 {
        const end_time = std.time.nanoTimestamp();
        const elapsed = end_time - self.start_time;
        return @intCast(if (elapsed < 0) 0 else elapsed);
    }

    pub fn readMicros(self: Timer) u64 {
        return self.read() / 1000;
    }

    pub fn readMillis(self: Timer) u64 {
        return self.read() / 1_000_000;
    }
};

/// Memory allocation tracker for profiling
pub const AllocTracker = struct {
    parent_allocator: std.mem.Allocator,
    allocations: usize = 0,
    deallocations: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    peak_memory: usize = 0,
    current_memory: usize = 0,

    pub const Stats = struct {
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
            if (self.current_memory > self.peak_memory) {
                self.peak_memory = self.current_memory;
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *AllocTracker = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            const old_len = buf.len;
            if (new_len > old_len) {
                const diff = new_len - old_len;
                self.bytes_allocated += diff;
                self.current_memory += diff;
                if (self.current_memory > self.peak_memory) {
                    self.peak_memory = self.current_memory;
                }
            } else if (new_len < old_len) {
                const diff = old_len - new_len;
                self.bytes_freed += diff;
                self.current_memory -= diff;
            }
        }
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
        if (result) |ptr| {
            const old_len = buf.len;
            if (new_len > old_len) {
                const diff = new_len - old_len;
                self.bytes_allocated += diff;
                self.current_memory += diff;
                if (self.current_memory > self.peak_memory) {
                    self.peak_memory = self.peak_memory;
                }
            } else if (new_len < old_len) {
                const diff = old_len - new_len;
                self.bytes_freed += diff;
                self.current_memory -= diff;
            }
            return ptr;
        }
        return null;
    }

    pub fn snapshot(self: *const AllocTracker) Stats {
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
    }
};

/// Benchmark result with metrics
pub const Result = struct {
    name: []const u8,
    time_ns: u64,
    allocations: usize = 0,
    bytes_allocated: usize = 0,
    peak_memory: usize = 0,
    iterations: usize = 1,
    throughput: ?f64 = null,

    pub fn print(self: Result, writer: anytype) !void {
        try writer.print("\n{s}:\n", .{self.name});
        try writer.print("  Time:        {d} ns ({d:.2} ms)\n", .{ self.time_ns, @as(f64, @floatFromInt(self.time_ns)) / 1_000_000.0 });

        if (self.iterations > 1) {
            const per_iter = self.time_ns / self.iterations;
            try writer.print("  Per iter:    {d} ns\n", .{per_iter});
        }

        if (self.throughput) |t| {
            try writer.print("  Throughput:  {d:.2} ops/sec\n", .{t});
        }

        if (self.allocations > 0) {
            try writer.print("  Allocations: {d}\n", .{self.allocations});
            try writer.print("  Bytes:       {d} ({d:.2} KB)\n", .{ self.bytes_allocated, @as(f64, @floatFromInt(self.bytes_allocated)) / 1024.0 });
        }

        if (self.peak_memory > 0) {
            try writer.print("  Peak memory: {d} ({d:.2} KB)\n", .{ self.peak_memory, @as(f64, @floatFromInt(self.peak_memory)) / 1024.0 });
        }
    }

    pub fn compare(baseline: Result, optimized: Result, writer: anytype) !void {
        try writer.print("\nComparison ({s} vs {s}):\n", .{ baseline.name, optimized.name });

        const time_diff = @as(f64, @floatFromInt(baseline.time_ns)) - @as(f64, @floatFromInt(optimized.time_ns));
        const time_pct = (time_diff / @as(f64, @floatFromInt(baseline.time_ns))) * 100.0;

        if (optimized.time_ns < baseline.time_ns) {
            const speedup = @as(f64, @floatFromInt(baseline.time_ns)) / @as(f64, @floatFromInt(optimized.time_ns));
            try writer.print("  ⚡ {d:.2}% faster ({d:.2}x speedup)\n", .{ time_pct, speedup });
        } else if (optimized.time_ns > baseline.time_ns) {
            const slowdown = @as(f64, @floatFromInt(optimized.time_ns)) / @as(f64, @floatFromInt(baseline.time_ns));
            try writer.print("  🐌 {d:.2}% slower ({d:.2}x slowdown)\n", .{ -time_pct, slowdown });
        } else {
            try writer.print("  ⚖️  Equal performance\n", .{});
        }

        if (baseline.allocations > 0 and optimized.allocations > 0) {
            const alloc_diff = @as(f64, @floatFromInt(baseline.allocations)) - @as(f64, @floatFromInt(optimized.allocations));
            const alloc_pct = (alloc_diff / @as(f64, @floatFromInt(baseline.allocations))) * 100.0;

            if (optimized.allocations < baseline.allocations) {
                try writer.print("  📉 {d:.2}% fewer allocations\n", .{alloc_pct});
            } else if (optimized.allocations > baseline.allocations) {
                try writer.print("  📈 {d:.2}% more allocations\n", .{-alloc_pct});
            }
        }

        if (baseline.bytes_allocated > 0 and optimized.bytes_allocated > 0) {
            const bytes_diff = @as(f64, @floatFromInt(baseline.bytes_allocated)) - @as(f64, @floatFromInt(optimized.bytes_allocated));
            const bytes_pct = (bytes_diff / @as(f64, @floatFromInt(baseline.bytes_allocated))) * 100.0;

            if (optimized.bytes_allocated < baseline.bytes_allocated) {
                try writer.print("  💾 {d:.2}% less memory\n", .{bytes_pct});
            } else if (optimized.bytes_allocated > baseline.bytes_allocated) {
                try writer.print("  💾 {d:.2}% more memory\n", .{-bytes_pct});
            }
        }
    }
};

/// Run all benchmarks
pub fn runAll(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");
    try writer.writeAll("                   zv vs libev Performance Benchmarks\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");

    try writer.writeAll("\n=== Event Loop Throughput ===\n");
    try loop_throughput.run(allocator, writer);

    try writer.writeAll("\n=== IO Watcher Operations ===\n");
    try io_operations.run(allocator, writer);

    try writer.writeAll("\n=== Timer Accuracy & Overhead ===\n");
    try timer_accuracy.run(allocator, writer);

    try writer.writeAll("\n=== Memory Usage Comparison ===\n");
    try memory_usage.run(allocator, writer);

    try writer.writeAll("\n=== Scaling Characteristics ===\n");
    try scaling.run(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");
    try writer.writeAll("✓ All benchmarks completed!\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");
}

/// Run a specific benchmark by name
pub fn runByName(allocator: std.mem.Allocator, name: []const u8, writer: anytype) !void {
    if (std.mem.eql(u8, name, "loop-throughput")) {
        try loop_throughput.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "io-operations")) {
        try io_operations.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "timer-accuracy")) {
        try timer_accuracy.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "memory-usage")) {
        try memory_usage.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "scaling")) {
        try scaling.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "all")) {
        try runAll(allocator, writer);
    } else {
        return error.UnknownBenchmark;
    }
}

test "Timer measures time" {
    const testing = std.testing;
    var timer = try Timer.start();
    std.time.sleep(1_000_000);
    const elapsed = timer.read();
    try testing.expect(elapsed >= 1_000_000);
}

test "AllocTracker tracks allocations" {
    const testing = std.testing;
    var tracker = AllocTracker{ .parent_allocator = testing.allocator };
    const tracked = tracker.allocator();

    const buf = try tracked.alloc(u8, 100);
    defer tracked.free(buf);

    const stats = tracker.snapshot();
    try testing.expectEqual(@as(usize, 1), stats.allocations);
    try testing.expect(stats.bytes_allocated >= 100);
}
