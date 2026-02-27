//! Memory Usage Comparison Benchmark
//!
//! Measures memory consumption and allocation patterns.

const std = @import("std");
const zv = @import("zv");
const benchmarks = @import("root.zig");
const Timer = benchmarks.Timer;
const Result = benchmarks.Result;
const AllocTracker = benchmarks.AllocTracker;

const c = @cImport({
    @cInclude("libev_wrapper.h");
});

pub fn run(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n");
    try writer.writeAll("Memory Usage Comparison Benchmark\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Scenario 1: Loop initialization\n");
    try benchmarkLoopInit(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 2: IO watchers memory\n");
    try benchmarkIoWatchersMemory(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 3: Timer watchers memory\n");
    try benchmarkTimerWatchersMemory(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 4: Peak memory with mixed watchers\n");
    try benchmarkMixedMemory(allocator, writer);

    try writer.writeAll("\n✓ Memory usage benchmark completed!\n");
}

fn benchmarkLoopInit(allocator: std.mem.Allocator, writer: anytype) !void {
    const zv_result = try benchmarkZvLoopInit(allocator);

    try zv_result.print(writer);
}

fn benchmarkZvLoopInit(allocator: std.mem.Allocator) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();

    var timer = try Timer.start();
    
    var loop = try zv.Loop.init(tracked, .{});
    defer loop.deinit();

    const elapsed = timer.read();
    const stats = tracker.snapshot();

    return Result{
        .name = "zv (loop init)",
        .time_ns = elapsed,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}

fn benchmarkIoWatchersMemory(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_watchers: usize = 100;

    const zv_result = try benchmarkZvIoMemory(allocator, num_watchers);

    try zv_result.print(writer);
}

fn benchmarkZvIoMemory(allocator: std.mem.Allocator, num_watchers: usize) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();

    var loop = try zv.Loop.init(tracked, .{});
    defer loop.deinit();

    const pipes = try tracked.alloc([2]std.posix.fd_t, num_watchers);
    defer tracked.free(pipes);

    const watchers = try tracked.alloc(zv.io.Watcher, num_watchers);
    defer tracked.free(watchers);

    for (pipes) |*p| {
        p.* = try std.posix.pipe();
    }

    defer {
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    tracker.reset();
    var timer = try Timer.start();

    for (pipes, 0..) |p, i| {
        watchers[i] = zv.io.Watcher.init(&loop, p[0], .read, dummyCallback);
        try watchers[i].start();
    }

    const elapsed = timer.read();

    defer {
        for (watchers) |*w| _ = w.stop() catch {};
    }

    const stats = tracker.snapshot();

    return Result{
        .name = "zv (100 IO watchers)",
        .time_ns = elapsed,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}

fn dummyCallback(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {}

fn benchmarkTimerWatchersMemory(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_watchers: usize = 100;

    const zv_result = try benchmarkZvTimerMemory(allocator, num_watchers);

    try zv_result.print(writer);
}

fn benchmarkZvTimerMemory(allocator: std.mem.Allocator, num_watchers: usize) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();

    var loop = try zv.Loop.init(tracked, .{});
    defer loop.deinit();

    const watchers = try tracked.alloc(zv.timer.Watcher, num_watchers);
    defer tracked.free(watchers);

    tracker.reset();
    var timer = try Timer.start();

    for (watchers, 0..) |*w, i| {
        const timeout_ns = (i + 1) * 1_000_000;
        w.* = zv.timer.Watcher.init(&loop, timeout_ns, 0, timerCallback);
        try w.start();
    }

    const elapsed = timer.read();

    defer {
        for (watchers) |*w| w.stop();
    }

    const stats = tracker.snapshot();

    return Result{
        .name = "zv (100 timer watchers)",
        .time_ns = elapsed,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}

fn timerCallback(_: *zv.timer.Watcher) void {}

fn benchmarkMixedMemory(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_io: usize = 50;
    const num_timers: usize = 50;

    const zv_result = try benchmarkZvMixed(allocator, num_io, num_timers);

    try zv_result.print(writer);
}

fn benchmarkZvMixed(allocator: std.mem.Allocator, num_io: usize, num_timers: usize) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();

    var loop = try zv.Loop.init(tracked, .{});
    defer loop.deinit();

    const pipes = try tracked.alloc([2]std.posix.fd_t, num_io);
    defer tracked.free(pipes);

    const io_watchers = try tracked.alloc(zv.io.Watcher, num_io);
    defer tracked.free(io_watchers);

    const timer_watchers = try tracked.alloc(zv.timer.Watcher, num_timers);
    defer tracked.free(timer_watchers);

    for (pipes) |*p| {
        p.* = try std.posix.pipe();
    }

    defer {
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    tracker.reset();
    var timer = try Timer.start();

    for (pipes, 0..) |p, i| {
        io_watchers[i] = zv.io.Watcher.init(&loop, p[0], .read, dummyCallback);
        try io_watchers[i].start();
    }

    for (timer_watchers, 0..) |*w, i| {
        const timeout_ns = (i + 1) * 1_000_000;
        w.* = zv.timer.Watcher.init(&loop, timeout_ns, 0, timerCallback);
        try w.start();
    }

    const elapsed = timer.read();

    defer {
        for (io_watchers) |*w| _ = w.stop() catch {};
        for (timer_watchers) |*w| w.stop();
    }

    const stats = tracker.snapshot();

    return Result{
        .name = "zv (50 IO + 50 timer watchers)",
        .time_ns = elapsed,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}

test "benchmark runs" {
    const testing = std.testing;
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try run(testing.allocator, fbs.writer());
}
