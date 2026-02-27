//! Scaling Characteristics Benchmark
//!
//! Measures performance degradation with increasing numbers of watchers.

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
    try writer.writeAll("Scaling Characteristics Benchmark\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Testing throughput with increasing IO watchers:\n");
    try benchmarkIoScaling(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Testing throughput with increasing timers:\n");
    try benchmarkTimerScaling(allocator, writer);

    try writer.writeAll("\n✓ Scaling benchmark completed!\n");
}

fn benchmarkIoScaling(allocator: std.mem.Allocator, writer: anytype) !void {
    const scales = [_]usize{ 10, 50, 100, 500, 1000, 2000 };
    const iterations: usize = 10000;

    try writer.writeAll("\nWatcher Count | zv (ms) | libev (ms) | Comparison\n");
    try writer.writeAll("------------- | ------- | ---------- | ----------\n");

    for (scales) |num_watchers| {
        const zv_result = try benchmarkZvIoScale(allocator, num_watchers, iterations);
        const libev_result = try benchmarkLibevIoScale(num_watchers, iterations);

        const zv_ms = @as(f64, @floatFromInt(zv_result.time_ns)) / 1_000_000.0;
        const libev_ms = @as(f64, @floatFromInt(libev_result.time_ns)) / 1_000_000.0;

        const ratio = zv_ms / libev_ms;
        const comparison = if (ratio < 1.0) "faster" else if (ratio > 1.0) "slower" else "equal";

        try writer.print("{d:>13} | {d:>7.2} | {d:>10.2} | {d:.2}x {s}\n", .{
            num_watchers,
            zv_ms,
            libev_ms,
            @abs(ratio),
            comparison,
        });
    }
}

fn benchmarkZvIoScale(allocator: std.mem.Allocator, num_watchers: usize, iterations: usize) !Result {
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

    return Result{
        .name = "zv",
        .time_ns = elapsed,
        .iterations = iterations,
    };
}

fn dummyCallback(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {}

fn benchmarkLibevIoScale(num_watchers: usize, iterations: usize) !Result {
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

    return Result{
        .name = "libev",
        .time_ns = elapsed,
        .iterations = iterations,
    };
}

fn libevDummyCallback(_: ?*c.libev_loop, _: ?*c.libev_io, _: c_int) callconv(.c) void {}

fn benchmarkTimerScaling(allocator: std.mem.Allocator, writer: anytype) !void {
    const scales = [_]usize{ 10, 50, 100, 250, 500, 1000 };
    const iterations: usize = 1000;

    try writer.writeAll("\nTimer Count   | zv (ms) | libev (ms) | Comparison\n");
    try writer.writeAll("------------- | ------- | ---------- | ----------\n");

    for (scales) |num_timers| {
        const zv_result = try benchmarkZvTimerScale(allocator, num_timers, iterations);
        const libev_result = try benchmarkLibevTimerScale(num_timers, iterations);

        const zv_ms = @as(f64, @floatFromInt(zv_result.time_ns)) / 1_000_000.0;
        const libev_ms = @as(f64, @floatFromInt(libev_result.time_ns)) / 1_000_000.0;

        const ratio = zv_ms / libev_ms;
        const comparison = if (ratio < 1.0) "faster" else if (ratio > 1.0) "slower" else "equal";

        try writer.print("{d:>13} | {d:>7.2} | {d:>10.2} | {d:.2}x {s}\n", .{
            num_timers,
            zv_ms,
            libev_ms,
            @abs(ratio),
            comparison,
        });
    }
}

fn benchmarkZvTimerScale(allocator: std.mem.Allocator, num_timers: usize, iterations: usize) !Result {
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

    return Result{
        .name = "zv",
        .time_ns = elapsed,
        .iterations = iterations,
    };
}

fn timerCallback(_: *zv.timer.Watcher) void {}

fn benchmarkLibevTimerScale(num_timers: usize, iterations: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const watchers = try std.heap.c_allocator.alloc(?*c.libev_timer, num_timers);
    defer std.heap.c_allocator.free(watchers);

    for (watchers, 0..) |*w, i| {
        const timeout_sec = @as(f64, @floatFromInt((i + 1) * 10)) / 1000.0;
        const t = c.libev_timer_new() orelse return error.WatcherCreationFailed;
        c.libev_timer_init(t, libevTimerCallback, timeout_sec, 0);
        c.libev_timer_start(loop, t);
        w.* = t;
    }

    defer {
        for (watchers) |w| {
            if (w) |t| {
                c.libev_timer_stop(loop, t);
                c.libev_timer_destroy(t);
            }
        }
    }

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        c.libev_loop_run(loop, c.LIBEV_RUN_NOWAIT);
    }
    const elapsed = timer.read();

    return Result{
        .name = "libev",
        .time_ns = elapsed,
        .iterations = iterations,
    };
}

fn libevTimerCallback(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {}

test "benchmark runs" {
    const testing = std.testing;
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try run(testing.allocator, fbs.writer());
}
