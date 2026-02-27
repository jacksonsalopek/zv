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
    const libev_result = try benchmarkLibevLoopInit();

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
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
    const libev_result = try benchmarkLibevIoMemory(num_watchers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
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
    const libev_result = try benchmarkLibevTimerMemory(num_watchers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
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

fn benchmarkLibevLoopInit() !Result {
    var timer = try Timer.start();
    
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const elapsed = timer.read();

    return Result{
        .name = "libev (loop init)",
        .time_ns = elapsed,
    };
}

fn benchmarkLibevIoMemory(num_watchers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const pipes = try std.heap.c_allocator.alloc([2]std.posix.fd_t, num_watchers);
    defer std.heap.c_allocator.free(pipes);

    const watchers = try std.heap.c_allocator.alloc(?*c.libev_io, num_watchers);
    defer std.heap.c_allocator.free(watchers);

    for (pipes) |*p| {
        p.* = try std.posix.pipe();
    }

    defer {
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    var timer = try Timer.start();

    for (pipes, 0..) |p, i| {
        const w = c.libev_io_new() orelse return error.WatcherCreationFailed;
        c.libev_io_init(w, libevDummyCallback, p[0], c.LIBEV_READ);
        c.libev_io_start(loop, w);
        watchers[i] = w;
    }

    const elapsed = timer.read();

    defer {
        for (watchers) |w| {
            if (w) |watcher| {
                c.libev_io_stop(loop, watcher);
                c.libev_io_destroy(watcher);
            }
        }
    }

    return Result{
        .name = "libev (100 IO watchers)",
        .time_ns = elapsed,
    };
}

fn libevDummyCallback(_: ?*c.libev_loop, _: ?*c.libev_io, _: c_int) callconv(.c) void {}

fn benchmarkLibevTimerMemory(num_watchers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const watchers = try std.heap.c_allocator.alloc(?*c.libev_timer, num_watchers);
    defer std.heap.c_allocator.free(watchers);

    var timer = try Timer.start();

    for (watchers, 0..) |*w, i| {
        const timeout_sec = @as(f64, @floatFromInt((i + 1))) / 1000.0;
        const t = c.libev_timer_new() orelse return error.WatcherCreationFailed;
        c.libev_timer_init(t, libevTimerCallback, timeout_sec, 0);
        c.libev_timer_start(loop, t);
        w.* = t;
    }

    const elapsed = timer.read();

    defer {
        for (watchers) |w| {
            if (w) |watcher| {
                c.libev_timer_stop(loop, watcher);
                c.libev_timer_destroy(watcher);
            }
        }
    }

    return Result{
        .name = "libev (100 timer watchers)",
        .time_ns = elapsed,
    };
}

fn libevTimerCallback(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {}

fn benchmarkLibevMixed(num_io: usize, num_timers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const pipes = try std.heap.c_allocator.alloc([2]std.posix.fd_t, num_io);
    defer std.heap.c_allocator.free(pipes);

    const io_watchers = try std.heap.c_allocator.alloc(?*c.libev_io, num_io);
    defer std.heap.c_allocator.free(io_watchers);

    const timer_watchers = try std.heap.c_allocator.alloc(?*c.libev_timer, num_timers);
    defer std.heap.c_allocator.free(timer_watchers);

    for (pipes) |*p| {
        p.* = try std.posix.pipe();
    }

    defer {
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    var timer = try Timer.start();

    for (pipes, 0..) |p, i| {
        const w = c.libev_io_new() orelse return error.WatcherCreationFailed;
        c.libev_io_init(w, libevDummyCallback, p[0], c.LIBEV_READ);
        c.libev_io_start(loop, w);
        io_watchers[i] = w;
    }

    for (timer_watchers, 0..) |*w, i| {
        const timeout_sec = @as(f64, @floatFromInt((i + 1))) / 1000.0;
        const t = c.libev_timer_new() orelse return error.WatcherCreationFailed;
        c.libev_timer_init(t, libevTimerCallback, timeout_sec, 0);
        c.libev_timer_start(loop, t);
        w.* = t;
    }

    const elapsed = timer.read();

    defer {
        for (io_watchers) |w| {
            if (w) |watcher| {
                c.libev_io_stop(loop, watcher);
                c.libev_io_destroy(watcher);
            }
        }
        for (timer_watchers) |w| {
            if (w) |watcher| {
                c.libev_timer_stop(loop, watcher);
                c.libev_timer_destroy(watcher);
            }
        }
    }

    return Result{
        .name = "libev (50 IO + 50 timer watchers)",
        .time_ns = elapsed,
    };
}

fn benchmarkMixedMemory(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_io: usize = 50;
    const num_timers: usize = 50;

    const zv_result = try benchmarkZvMixed(allocator, num_io, num_timers);
    const libev_result = try benchmarkLibevMixed(num_io, num_timers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
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
