//! Event Loop Throughput Benchmark
//!
//! Measures iterations per second for zv vs libev under different workloads.

const std = @import("std");
const zv = @import("zv");
const benchmarks = @import("root.zig");
const Timer = benchmarks.Timer;
const Result = benchmarks.Result;

const c = @cImport({
    @cInclude("libev_wrapper.h");
});

pub fn run(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n");
    try writer.writeAll("Event Loop Throughput Benchmark\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Scenario 1: Empty loop (no watchers)\n");
    try benchmarkEmptyLoop(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 2: Loop with idle IO watchers\n");
    try benchmarkIdleWatchers(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 3: Loop with active timers\n");
    try benchmarkActiveTimers(allocator, writer);

    try writer.writeAll("\n✓ Loop throughput benchmark completed!\n");
}

fn benchmarkEmptyLoop(allocator: std.mem.Allocator, writer: anytype) !void {
    const iterations: usize = 500_000;

    const zv_result = try benchmarkZvEmpty(allocator, iterations);
    const libev_result = try benchmarkLibevEmpty(iterations);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

fn benchmarkZvEmpty(allocator: std.mem.Allocator, iterations: usize) !Result {
    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = try loop.run(.nowait);
    }
    const elapsed = timer.read();

    const throughput = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return Result{
        .name = "zv (empty loop)",
        .time_ns = elapsed,
        .iterations = iterations,
        .throughput = throughput,
    };
}

fn benchmarkLibevEmpty(iterations: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        c.libev_loop_run(loop, c.LIBEV_RUN_NOWAIT);
    }
    const elapsed = timer.read();

    const throughput = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return Result{
        .name = "libev (empty loop)",
        .time_ns = elapsed,
        .iterations = iterations,
        .throughput = throughput,
    };
}

fn benchmarkIdleWatchers(allocator: std.mem.Allocator, writer: anytype) !void {
    const iterations: usize = 50_000;
    const num_watchers: usize = 1000;

    const zv_result = try benchmarkZvIdleWatchers(allocator, iterations, num_watchers);
    const libev_result = try benchmarkLibevIdleWatchers(iterations, num_watchers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

fn benchmarkZvIdleWatchers(allocator: std.mem.Allocator, iterations: usize, num_watchers: usize) !Result {
    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    const pipes = try allocator.alloc([2]std.posix.fd_t, num_watchers);
    defer allocator.free(pipes);

    const watchers = try allocator.alloc(zv.io.Watcher, num_watchers);
    defer allocator.free(watchers);

    for (pipes, 0..) |*p, i| {
        p.* = try std.posix.pipe();
        watchers[i] = zv.io.Watcher.init(&loop, p[0], .read, dummyCallback);
        try watchers[i].start();
    }

    defer {
        for (watchers) |*w| _ = w.stop() catch {};
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = try loop.run(.nowait);
    }
    const elapsed = timer.read();

    const throughput = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return Result{
        .name = "zv (1000 idle watchers)",
        .time_ns = elapsed,
        .iterations = iterations,
        .throughput = throughput,
    };
}

fn dummyCallback(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {}

fn benchmarkLibevIdleWatchers(iterations: usize, num_watchers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const pipes = try std.heap.c_allocator.alloc([2]std.posix.fd_t, num_watchers);
    defer std.heap.c_allocator.free(pipes);

    const watchers = try std.heap.c_allocator.alloc(?*c.libev_io, num_watchers);
    defer std.heap.c_allocator.free(watchers);

    for (pipes, 0..) |*p, i| {
        p.* = try std.posix.pipe();
        const w = c.libev_io_new() orelse return error.WatcherCreationFailed;
        c.libev_io_init(w, libevDummyCallback, p[0], c.LIBEV_READ);
        c.libev_io_start(loop, w);
        watchers[i] = w;
    }

    defer {
        for (watchers) |w| {
            if (w) |watcher| {
                c.libev_io_stop(loop, watcher);
                c.libev_io_destroy(watcher);
            }
        }
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        c.libev_loop_run(loop, c.LIBEV_RUN_NOWAIT);
    }
    const elapsed = timer.read();

    const throughput = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return Result{
        .name = "libev (1000 idle watchers)",
        .time_ns = elapsed,
        .iterations = iterations,
        .throughput = throughput,
    };
}

fn libevDummyCallback(_: ?*c.libev_loop, _: ?*c.libev_io, _: c_int) callconv(.c) void {}

fn benchmarkActiveTimers(allocator: std.mem.Allocator, writer: anytype) !void {
    const iterations: usize = 10_000;
    const num_timers: usize = 100;

    const zv_result = try benchmarkZvActiveTimers(allocator, iterations, num_timers);
    const libev_result = try benchmarkLibevActiveTimers(iterations, num_timers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

fn benchmarkZvActiveTimers(allocator: std.mem.Allocator, iterations: usize, num_timers: usize) !Result {
    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    const watchers = try allocator.alloc(zv.timer.Watcher, num_timers);
    defer allocator.free(watchers);

    for (watchers, 0..) |*w, i| {
        const timeout_ns = (i + 1) * 10_000_000;
        w.* = zv.timer.Watcher.init(&loop, timeout_ns, 0, timerCallback);
        try w.start();
    }

    defer {
        for (watchers) |*w| w.stop();
    }

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = try loop.run(.nowait);
    }
    const elapsed = timer.read();

    const throughput = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return Result{
        .name = "zv (100 active timers)",
        .time_ns = elapsed,
        .iterations = iterations,
        .throughput = throughput,
    };
}

fn timerCallback(_: *zv.timer.Watcher) void {}

fn benchmarkLibevActiveTimers(iterations: usize, num_timers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const watchers = try std.heap.c_allocator.alloc(?*c.libev_timer, num_timers);
    defer std.heap.c_allocator.free(watchers);

    for (watchers, 0..) |*w, i| {
        const timeout_sec = @as(f64, @floatFromInt((i + 1) * 10)) / 1000.0;
        const timer = c.libev_timer_new() orelse return error.WatcherCreationFailed;
        c.libev_timer_init(timer, libevTimerCallback, timeout_sec, 0);
        c.libev_timer_start(loop, timer);
        w.* = timer;
    }

    defer {
        for (watchers) |w| {
            if (w) |timer| {
                c.libev_timer_stop(loop, timer);
                c.libev_timer_destroy(timer);
            }
        }
    }

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        c.libev_loop_run(loop, c.LIBEV_RUN_NOWAIT);
    }
    const elapsed = timer.read();

    const throughput = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return Result{
        .name = "libev (100 active timers)",
        .time_ns = elapsed,
        .iterations = iterations,
        .throughput = throughput,
    };
}

fn libevTimerCallback(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {}

test "benchmark runs" {
    const testing = std.testing;
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try run(testing.allocator, fbs.writer());
}
