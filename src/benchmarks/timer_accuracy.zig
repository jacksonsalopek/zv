//! Timer Accuracy and Overhead Benchmark
//!
//! Measures timer scheduling, firing accuracy, and cleanup performance.

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
    try writer.writeAll("Timer Accuracy & Overhead Benchmark\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Scenario 1: Timer creation overhead\n");
    try benchmarkTimerCreation(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 2: Timer firing latency\n");
    try benchmarkTimerLatency(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 3: Repeating timers\n");
    try benchmarkRepeatingTimers(allocator, writer);

    try writer.writeAll("\n✓ Timer accuracy benchmark completed!\n");
}

fn benchmarkTimerCreation(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_timers: usize = 1000;

    const zv_result = try benchmarkZvTimerCreation(allocator, num_timers);
    const libev_result = try benchmarkLibevTimerCreation(num_timers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

fn benchmarkZvTimerCreation(allocator: std.mem.Allocator, num_timers: usize) !Result {
    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    const watchers = try allocator.alloc(zv.timer.Watcher, num_timers);
    defer allocator.free(watchers);

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

    return Result{
        .name = "zv (timer creation)",
        .time_ns = elapsed,
        .iterations = num_timers,
    };
}

fn timerCallback(_: *zv.timer.Watcher) void {}

fn benchmarkLibevTimerCreation(num_timers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const watchers = try std.heap.c_allocator.alloc(?*c.libev_timer, num_timers);
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
            if (w) |t| {
                c.libev_timer_stop(loop, t);
                c.libev_timer_destroy(t);
            }
        }
    }

    return Result{
        .name = "libev (timer creation)",
        .time_ns = elapsed,
        .iterations = num_timers,
    };
}

fn libevTimerCallback(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {}

fn benchmarkTimerLatency(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_samples: usize = 100;

    const zv_result = try benchmarkZvLatency(allocator, num_samples);
    const libev_result = try benchmarkLibevLatency(num_samples);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

var latency_fired: bool = false;

fn benchmarkZvLatency(allocator: std.mem.Allocator, num_samples: usize) !Result {
    var total_latency: u64 = 0;

    var i: usize = 0;
    while (i < num_samples) : (i += 1) {
        var loop = try zv.Loop.init(allocator, .{});
        defer loop.deinit();

        latency_fired = false;
        const timeout_ns = 10_000_000;

        var watcher = zv.timer.Watcher.init(&loop, timeout_ns, 0, zvLatencyCallback);
        
        const start = std.time.nanoTimestamp();
        try watcher.start();

        while (!latency_fired) {
            _ = try loop.run(.once);
        }

        const end = std.time.nanoTimestamp();
        const latency_ns = end - start;
        
        if (latency_ns > timeout_ns) {
            const overhead = @as(u64, @intCast(latency_ns - timeout_ns));
            total_latency += overhead;
        }
    }

    const avg_latency = total_latency / num_samples;

    return Result{
        .name = "zv (timer latency)",
        .time_ns = avg_latency,
        .iterations = num_samples,
    };
}

fn zvLatencyCallback(_: *zv.timer.Watcher) void {
    latency_fired = true;
}

fn benchmarkLibevLatency(num_samples: usize) !Result {
    var total_latency: u64 = 0;

    var i: usize = 0;
    while (i < num_samples) : (i += 1) {
        const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
        defer c.libev_loop_destroy(loop);

        const timeout_sec = 0.01;
        const timeout_ns: u64 = 10_000_000;

        const timer = c.libev_timer_new() orelse return error.WatcherCreationFailed;
        defer c.libev_timer_destroy(timer);

        c.libev_timer_init(timer, libevBreakCallback, timeout_sec, 0);
        
        const start = std.time.nanoTimestamp();
        c.libev_timer_start(loop, timer);
        c.libev_loop_run(loop, c.LIBEV_RUN_DEFAULT);
        const end = std.time.nanoTimestamp();

        const latency_ns = end - start;
        
        if (latency_ns > timeout_ns) {
            const overhead = @as(u64, @intCast(latency_ns - timeout_ns));
            total_latency += overhead;
        }
    }

    const avg_latency = total_latency / num_samples;

    return Result{
        .name = "libev (timer latency)",
        .time_ns = avg_latency,
        .iterations = num_samples,
    };
}

fn libevBreakCallback(loop: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {
    if (loop) |l| {
        c.libev_loop_break(l, c.LIBEV_BREAK_ONE);
    }
}

fn benchmarkRepeatingTimers(allocator: std.mem.Allocator, writer: anytype) !void {
    const iterations: usize = 1000;
    const num_timers: usize = 10;

    const zv_result = try benchmarkZvRepeating(allocator, iterations, num_timers);
    const libev_result = try benchmarkLibevRepeating(iterations, num_timers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

var repeat_count: usize = 0;

fn benchmarkZvRepeating(allocator: std.mem.Allocator, iterations: usize, num_timers: usize) !Result {
    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    const watchers = try allocator.alloc(zv.timer.Watcher, num_timers);
    defer allocator.free(watchers);

    repeat_count = 0;
    const target = iterations;

    for (watchers) |*w| {
        w.* = zv.timer.Watcher.init(&loop, 1_000_000, 1_000_000, zvRepeatCallback);
        try w.start();
    }

    var timer = try Timer.start();

    while (repeat_count < target) {
        _ = try loop.run(.once);
    }

    const elapsed = timer.read();

    defer {
        for (watchers) |*w| w.stop();
    }

    return Result{
        .name = "zv (repeating timers)",
        .time_ns = elapsed,
        .iterations = iterations,
    };
}

fn zvRepeatCallback(_: *zv.timer.Watcher) void {
    repeat_count += 1;
}

var libev_repeat_count: usize = 0;

fn benchmarkLibevRepeating(iterations: usize, num_timers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const watchers = try std.heap.c_allocator.alloc(?*c.libev_timer, num_timers);
    defer std.heap.c_allocator.free(watchers);

    libev_repeat_count = 0;
    const target = iterations;

    for (watchers) |*w| {
        const timer = c.libev_timer_new() orelse return error.WatcherCreationFailed;
        c.libev_timer_init(timer, libevRepeatCallback, 0.001, 0.001);
        c.libev_timer_start(loop, timer);
        w.* = timer;
    }

    var timer = try Timer.start();

    while (libev_repeat_count < target) {
        c.libev_loop_run(loop, c.LIBEV_RUN_ONCE);
    }

    const elapsed = timer.read();

    defer {
        for (watchers) |w| {
            if (w) |t| {
                c.libev_timer_stop(loop, t);
                c.libev_timer_destroy(t);
            }
        }
    }

    return Result{
        .name = "libev (repeating timers)",
        .time_ns = elapsed,
        .iterations = iterations,
    };
}

fn libevRepeatCallback(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {
    libev_repeat_count += 1;
}

test "benchmark runs" {
    const testing = std.testing;
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try run(testing.allocator, fbs.writer());
}
