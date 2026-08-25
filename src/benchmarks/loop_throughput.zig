//! Event loop throughput: `run(.nowait)` calls per second.
//!
//! Empty-loop runs do not poll: both libraries return immediately when there
//! are no watchers. Idle-IO and far-future-timer scenarios do poll/check.

const std = @import("std");
const zv = @import("zv");
const benchmarks = @import("infra.zig");
const Result = benchmarks.Result;

const c = @cImport({
    @cInclude("libev_wrapper.h");
});

const warmup = benchmarks.default_warmup;
const samples = benchmarks.default_samples;

var callback_hits: usize = 0;

pub fn run(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\nEvent Loop Throughput\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Scenario 1: Empty loop (no watchers — neither library polls)\n");
    try benchmarkEmptyLoop(allocator, writer);

    try writer.writeAll("\nScenario 2: Loop with idle IO watchers (epoll_wait timeout 0)\n");
    try benchmarkIdleWatchers(allocator, writer);

    try writer.writeAll("\nScenario 3: Loop with far-future timers (must not fire during the run)\n");
    try benchmarkActiveTimers(allocator, writer);

    try writer.writeAll("\nLoop throughput benchmark completed.\n");
}

fn benchmarkEmptyLoop(allocator: std.mem.Allocator, writer: anytype) !void {
    const iterations: usize = 200_000;
    const zv_result = try benchZvEmpty(allocator, iterations);
    const libev_result = try benchLibevEmpty(allocator, iterations);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try Result.compareTime(libev_result, zv_result, writer);
}

const EmptyCtx = struct { loop: *zv.Loop, iterations: usize };

fn zvEmptyTimed(ctx: EmptyCtx) !void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        try ctx.loop.run(.nowait);
    }
}

fn benchZvEmpty(allocator: std.mem.Allocator, iterations: usize) !Result {
    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();
    const stats = try benchmarks.measure(allocator, warmup, samples, EmptyCtx{
        .loop = loop,
        .iterations = iterations,
    }, zvEmptyTimed);
    return Result.fromStats("zv (empty loop)", stats, iterations, "runs/sec");
}

const LibevEmptyCtx = struct { loop: *c.libev_loop, iterations: usize };

fn libevEmptyTimed(ctx: LibevEmptyCtx) !void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        c.libev_loop_run(ctx.loop, c.LIBEV_RUN_NOWAIT);
    }
}

fn benchLibevEmpty(allocator: std.mem.Allocator, iterations: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const stats = try benchmarks.measure(allocator, warmup, samples, LibevEmptyCtx{
        .loop = loop,
        .iterations = iterations,
    }, libevEmptyTimed);
    return Result.fromStats("libev (empty loop)", stats, iterations, "runs/sec");
}

fn dummyIo(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {
    callback_hits +%= 1;
}

fn libevDummyIo(_: ?*c.libev_loop, _: ?*c.libev_io, _: c_int) callconv(.c) void {
    callback_hits +%= 1;
}

fn closePipes(pipes: [][2]std.posix.fd_t) void {
    for (pipes) |p| {
        std.posix.close(p[0]);
        std.posix.close(p[1]);
    }
}

fn openPipes(allocator: std.mem.Allocator, n: usize) ![][2]std.posix.fd_t {
    const pipes = try allocator.alloc([2]std.posix.fd_t, n);
    errdefer allocator.free(pipes);
    var opened: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < opened) : (i += 1) {
            std.posix.close(pipes[i][0]);
            std.posix.close(pipes[i][1]);
        }
    }
    for (pipes) |*p| {
        p.* = try std.posix.pipe();
        opened += 1;
    }
    return pipes;
}

fn benchmarkIdleWatchers(allocator: std.mem.Allocator, writer: anytype) !void {
    const iterations: usize = 20_000;
    const num_watchers: usize = 1000;
    callback_hits = 0;
    const zv_result = try benchZvIdle(allocator, iterations, num_watchers);
    const libev_result = try benchLibevIdle(allocator, iterations, num_watchers);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try Result.compareTime(libev_result, zv_result, writer);
    try writer.print("  idle callbacks fired (should be 0): {d}\n", .{callback_hits});
    benchmarks.keep(callback_hits);
}

const IdleCtx = struct { loop: *zv.Loop, iterations: usize };

fn zvNowaitTimed(ctx: IdleCtx) !void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        try ctx.loop.run(.nowait);
    }
}

fn benchZvIdle(allocator: std.mem.Allocator, iterations: usize, num_watchers: usize) !Result {
    const loop = try zv.Loop.init(allocator, .{ .initial_watcher_capacity = num_watchers });
    defer loop.destroy();

    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }

    const watchers = try allocator.alloc(zv.io.Watcher, num_watchers);
    defer allocator.free(watchers);

    for (pipes, 0..) |p, i| {
        watchers[i] = zv.io.Watcher.init(loop, p[0], .read, dummyIo);
        try watchers[i].start();
    }
    defer stopZvIo(watchers);

    const stats = try benchmarks.measure(allocator, warmup, samples, IdleCtx{
        .loop = loop,
        .iterations = iterations,
    }, zvNowaitTimed);
    return Result.fromStats("zv (1000 idle watchers)", stats, iterations, "runs/sec");
}

fn stopZvIo(watchers: []zv.io.Watcher) void {
    for (watchers) |*w| {
        w.stop() catch {};
    }
}

const LibevIdleCtx = struct { loop: *c.libev_loop, iterations: usize };

fn libevNowaitTimed(ctx: LibevIdleCtx) !void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        c.libev_loop_run(ctx.loop, c.LIBEV_RUN_NOWAIT);
    }
}

fn benchLibevIdle(allocator: std.mem.Allocator, iterations: usize, num_watchers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }

    const storage = c.libev_io_alloc_array(num_watchers) orelse return error.WatcherCreationFailed;
    defer c.libev_io_free_array(storage);

    var i: usize = 0;
    while (i < num_watchers) : (i += 1) {
        const w = c.libev_io_nth(storage, i);
        c.libev_io_init(w, libevDummyIo, pipes[i][0], c.LIBEV_READ);
        c.libev_io_start(loop, w);
    }
    defer stopLibevIo(loop, storage, num_watchers);

    const stats = try benchmarks.measure(allocator, warmup, samples, LibevIdleCtx{
        .loop = loop,
        .iterations = iterations,
    }, libevNowaitTimed);
    return Result.fromStats("libev (1000 idle watchers)", stats, iterations, "runs/sec");
}

fn stopLibevIo(loop: *c.libev_loop, storage: *c.libev_io, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        c.libev_io_stop(loop, c.libev_io_nth(storage, i));
    }
}

fn dummyTimer(_: *zv.timer.Watcher) void {
    callback_hits +%= 1;
}

fn libevDummyTimer(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {
    callback_hits +%= 1;
}

fn benchmarkActiveTimers(allocator: std.mem.Allocator, writer: anytype) !void {
    const iterations: usize = 10_000;
    const num_timers: usize = 100;
    callback_hits = 0;
    const zv_result = try benchZvTimers(allocator, iterations, num_timers);
    const libev_result = try benchLibevTimers(allocator, iterations, num_timers);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try Result.compareTime(libev_result, zv_result, writer);
    try writer.print("  timers fired during nowait run (should be 0): {d}\n", .{callback_hits});
    benchmarks.keep(callback_hits);
}

fn benchZvTimers(allocator: std.mem.Allocator, iterations: usize, num_timers: usize) !Result {
    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();

    const watchers = try allocator.alloc(zv.timer.Watcher, num_timers);
    defer allocator.free(watchers);

    // One hour plus a unique offset so timers cannot fire during the timed run.
    const hour_ns: u64 = 3_600 * std.time.ns_per_s;
    for (watchers, 0..) |*w, i| {
        w.* = zv.timer.Watcher.init(loop, hour_ns + i, 0, dummyTimer);
        try w.start();
    }
    defer {
        for (watchers) |*w| w.stop();
    }

    const stats = try benchmarks.measure(allocator, warmup, samples, IdleCtx{
        .loop = loop,
        .iterations = iterations,
    }, zvNowaitTimed);
    return Result.fromStats("zv (100 far-future timers)", stats, iterations, "runs/sec");
}

fn benchLibevTimers(allocator: std.mem.Allocator, iterations: usize, num_timers: usize) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const storage = c.libev_timer_alloc_array(num_timers) orelse return error.WatcherCreationFailed;
    defer c.libev_timer_free_array(storage);

    var i: usize = 0;
    while (i < num_timers) : (i += 1) {
        const t = c.libev_timer_nth(storage, i);
        const after = 3600.0 + @as(f64, @floatFromInt(i));
        c.libev_timer_init(t, libevDummyTimer, after, 0);
        c.libev_timer_start(loop, t);
    }
    defer {
        var j: usize = 0;
        while (j < num_timers) : (j += 1) {
            c.libev_timer_stop(loop, c.libev_timer_nth(storage, j));
        }
    }

    const stats = try benchmarks.measure(allocator, warmup, samples, LibevIdleCtx{
        .loop = loop,
        .iterations = iterations,
    }, libevNowaitTimed);
    return Result.fromStats("libev (100 far-future timers)", stats, iterations, "runs/sec");
}
