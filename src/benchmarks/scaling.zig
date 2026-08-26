//! Scaling: `run(.nowait)` cost vs watcher count.
//!
//! Skips scales that would exceed the process file-descriptor limit.

const std = @import("std");
const zv = @import("zv");
const benchmarks = @import("infra.zig");

const c = @cImport({
    @cInclude("libev_wrapper.h");
});

const warmup_count = 1;
const sample_count = 3;

const Scale = struct {
    n: usize,
    iters: usize,
};

const io_scales = [_]Scale{
    .{ .n = 10, .iters = 10_000 },
    .{ .n = 50, .iters = 10_000 },
    .{ .n = 100, .iters = 8_000 },
    .{ .n = 500, .iters = 4_000 },
    .{ .n = 1000, .iters = 2_000 },
    .{ .n = 2000, .iters = 1_000 },
    .{ .n = 5000, .iters = 500 },
    .{ .n = 10000, .iters = 250 },
};

const timer_scales = [_]Scale{
    .{ .n = 10, .iters = 8_000 },
    .{ .n = 50, .iters = 4_000 },
    .{ .n = 100, .iters = 2_000 },
    .{ .n = 250, .iters = 1_000 },
    .{ .n = 500, .iters = 500 },
    .{ .n = 1000, .iters = 250 },
    .{ .n = 2500, .iters = 100 },
    .{ .n = 5000, .iters = 50 },
};

fn dummyIo(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {}
fn dummyTimer(_: *zv.timer.Watcher) void {}
fn libevDummyIo(_: ?*c.libev_loop, _: ?*c.libev_io, _: c_int) callconv(.c) void {}
fn libevDummyTimer(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {}

pub fn run(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\nScaling Characteristics\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\nMedian nowait-run time. Ratio is zv_time / libev_time.\n");

    try writer.writeAll("\nIdle IO watchers:\n");
    try writer.writeAll("Count | iters | zv (ms) | libev (ms) | note\n");
    try writer.writeAll("----- | ----- | ------- | ---------- | ----\n");
    try runIoScales(allocator, writer);

    try writer.writeAll("\nFar-future timers:\n");
    try writer.writeAll("Count | iters | zv (ms) | libev (ms) | note\n");
    try writer.writeAll("----- | ----- | ------- | ---------- | ----\n");
    try runTimerScales(allocator, writer);

    try writer.writeAll("\nScaling benchmark completed.\n");
}

fn fdLimit() usize {
    const lim = std.posix.getrlimit(.NOFILE) catch return 1024;
    return @intCast(lim.cur);
}

fn canOpenPipes(n: usize) bool {
    // 2 fds per pipe plus headroom for epoll/waker/stdio.
    return n * 2 + 64 < fdLimit();
}

fn closePipes(pipes: [][2]std.posix.fd_t) void {
    for (pipes) |p| {
        zv.sys.close(p[0]);
        zv.sys.close(p[1]);
    }
}

fn formatNote(zv_ns: u64, libev_ns: u64) []const u8 {
    if (libev_ns == 0) return "n/a";
    if (zv_ns < libev_ns) return "zv faster";
    if (zv_ns > libev_ns) return "zv slower";
    return "equal";
}

fn printRow(writer: anytype, n: usize, iters: usize, zv_ns: u64, libev_ns: u64) !void {
    const zv_ms = @as(f64, @floatFromInt(zv_ns)) / 1_000_000.0;
    const libev_ms = @as(f64, @floatFromInt(libev_ns)) / 1_000_000.0;
    const ratio = if (libev_ns == 0) 0.0 else @as(f64, @floatFromInt(zv_ns)) / @as(f64, @floatFromInt(libev_ns));
    try writer.print("{d:>5} | {d:>5} | {d:>7.2} | {d:>10.2} | {d:.2}x {s}\n", .{
        n,
        iters,
        zv_ms,
        libev_ms,
        ratio,
        formatNote(zv_ns, libev_ns),
    });
}

fn runIoScales(allocator: std.mem.Allocator, writer: anytype) !void {
    for (io_scales) |scale| {
        if (!canOpenPipes(scale.n)) {
            try writer.print("{d:>5} | skip (fd limit {d})\n", .{ scale.n, fdLimit() });
            continue;
        }
        const zv_ns = try benchZvIo(allocator, scale);
        const libev_ns = try benchLibevIo(allocator, scale);
        try printRow(writer, scale.n, scale.iters, zv_ns, libev_ns);
    }
}

const NowaitCtx = struct { loop: *zv.Loop, iters: usize };
const LibevNowaitCtx = struct { loop: *c.libev_loop, iters: usize };

fn zvNowait(ctx: NowaitCtx) !void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) try ctx.loop.run(.nowait);
}

fn libevNowait(ctx: LibevNowaitCtx) !void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) c.libev_loop_run(ctx.loop, c.LIBEV_RUN_NOWAIT);
}

fn benchZvIo(allocator: std.mem.Allocator, scale: Scale) !u64 {
    const loop = try zv.Loop.init(allocator, .{ .initial_watcher_capacity = scale.n });
    defer loop.destroy();
    const pipes = try allocator.alloc([2]std.posix.fd_t, scale.n);
    defer allocator.free(pipes);
    for (pipes) |*p| p.* = try zv.sys.pipe();
    defer closePipes(pipes);

    const watchers = try allocator.alloc(zv.io.Watcher, scale.n);
    defer allocator.free(watchers);
    for (pipes, 0..) |p, i| {
        watchers[i] = zv.io.Watcher.init(loop, p[0], .read, dummyIo);
        try watchers[i].start();
    }
    defer {
        for (watchers) |*w| w.stop() catch {};
    }

    const stats = try benchmarks.measure(allocator, warmup_count, sample_count, NowaitCtx{
        .loop = loop,
        .iters = scale.iters,
    }, zvNowait);
    return stats.median_ns;
}

fn benchLibevIo(allocator: std.mem.Allocator, scale: Scale) !u64 {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const pipes = try allocator.alloc([2]std.posix.fd_t, scale.n);
    defer allocator.free(pipes);
    for (pipes) |*p| p.* = try zv.sys.pipe();
    defer closePipes(pipes);

    const storage = c.libev_io_alloc_array(scale.n) orelse return error.WatcherCreationFailed;
    defer c.libev_io_free_array(storage);
    var i: usize = 0;
    while (i < scale.n) : (i += 1) {
        const w = c.libev_io_nth(storage, i);
        c.libev_io_init(w, libevDummyIo, pipes[i][0], c.LIBEV_READ);
        c.libev_io_start(loop, w);
    }
    defer {
        var j: usize = 0;
        while (j < scale.n) : (j += 1) {
            c.libev_io_stop(loop, c.libev_io_nth(storage, j));
        }
    }

    const stats = try benchmarks.measure(allocator, warmup_count, sample_count, LibevNowaitCtx{
        .loop = loop,
        .iters = scale.iters,
    }, libevNowait);
    return stats.median_ns;
}

fn runTimerScales(allocator: std.mem.Allocator, writer: anytype) !void {
    for (timer_scales) |scale| {
        const zv_ns = try benchZvTimers(allocator, scale);
        const libev_ns = try benchLibevTimers(allocator, scale);
        try printRow(writer, scale.n, scale.iters, zv_ns, libev_ns);
    }
}

fn benchZvTimers(allocator: std.mem.Allocator, scale: Scale) !u64 {
    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();
    const watchers = try allocator.alloc(zv.timer.Watcher, scale.n);
    defer allocator.free(watchers);
    const hour_ns: u64 = 3_600 * std.time.ns_per_s;
    for (watchers, 0..) |*w, i| {
        w.* = zv.timer.Watcher.init(loop, hour_ns + i, 0, dummyTimer);
        try w.start();
    }
    defer {
        for (watchers) |*w| w.stop();
    }

    const stats = try benchmarks.measure(allocator, warmup_count, sample_count, NowaitCtx{
        .loop = loop,
        .iters = scale.iters,
    }, zvNowait);
    return stats.median_ns;
}

fn benchLibevTimers(allocator: std.mem.Allocator, scale: Scale) !u64 {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const storage = c.libev_timer_alloc_array(scale.n) orelse return error.WatcherCreationFailed;
    defer c.libev_timer_free_array(storage);
    var i: usize = 0;
    while (i < scale.n) : (i += 1) {
        const t = c.libev_timer_nth(storage, i);
        c.libev_timer_init(t, libevDummyTimer, 3600.0 + @as(f64, @floatFromInt(i)), 0);
        c.libev_timer_start(loop, t);
    }
    defer {
        var j: usize = 0;
        while (j < scale.n) : (j += 1) {
            c.libev_timer_stop(loop, c.libev_timer_nth(storage, j));
        }
    }

    const stats = try benchmarks.measure(allocator, warmup_count, sample_count, LibevNowaitCtx{
        .loop = loop,
        .iters = scale.iters,
    }, libevNowait);
    return stats.median_ns;
}

