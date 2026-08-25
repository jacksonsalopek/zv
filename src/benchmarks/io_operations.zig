//! IO watcher add / modify / remove.
//!
//! Watcher storage is allocated before the timed region on both sides so
//! libev is not penalized for calloc. `modify` is not a fair kernel-level
//! comparison: see printed caveat.

const std = @import("std");
const zv = @import("zv");
const benchmarks = @import("infra.zig");
const Timer = benchmarks.Timer;
const Result = benchmarks.Result;

const c = @cImport({
    @cInclude("libev_wrapper.h");
});

const warmup_count = benchmarks.default_warmup;
const sample_count = benchmarks.default_samples;
const num_watchers: usize = 1000;
const modifications: usize = 20;

fn dummyIo(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {}
fn libevDummyIo(_: ?*c.libev_loop, _: ?*c.libev_io, _: c_int) callconv(.c) void {}

pub fn run(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\nIO Watcher Operations\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Scenario 1: Add 1000 watchers (start + one nowait to flush libev fd_reify)\n");
    try runAdd(allocator, writer);

    try writer.writeAll("\nScenario 2: Modify events (API only — not comparable kernel work)\n");
    try writer.writeAll(
        \\  zv.modify() and ev_io_modify() both update userspace only.
        \\  libev does not mark the fd dirty, so ev_run does not apply it.
        \\  No winner is printed.
        \\
    );
    try runModify(allocator, writer);

    try writer.writeAll("\nScenario 3: Remove 1000 watchers (stop + one nowait flush)\n");
    try runRemove(allocator, writer);

    try writer.writeAll("\nIO operations benchmark completed.\n");
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
    errdefer closeOpened(pipes, opened);
    for (pipes) |*p| {
        p.* = try std.posix.pipe();
        opened += 1;
    }
    return pipes;
}

fn closeOpened(pipes: [][2]std.posix.fd_t, opened: usize) void {
    var i: usize = 0;
    while (i < opened) : (i += 1) {
        std.posix.close(pipes[i][0]);
        std.posix.close(pipes[i][1]);
    }
}

fn runAdd(allocator: std.mem.Allocator, writer: anytype) !void {
    const zv_result = try benchZvAdd(allocator);
    const libev_result = try benchLibevAdd(allocator);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try Result.compareTime(libev_result, zv_result, writer);
}

fn startZvAll(watchers: []zv.io.Watcher, loop: *zv.Loop, pipes: [][2]std.posix.fd_t) !void {
    for (watchers, 0..) |*w, i| {
        w.* = zv.io.Watcher.init(loop, pipes[i][0], .read, dummyIo);
        try w.start();
    }
}

fn stopZvAll(watchers: []zv.io.Watcher) !void {
    for (watchers) |*w| try w.stop();
}

fn flushZv(loop: *zv.Loop) !void {
    try loop.run(.nowait);
}

fn flushLibev(loop: *c.libev_loop) void {
    c.libev_loop_run(loop, c.LIBEV_RUN_NOWAIT);
}

fn benchZvAdd(allocator: std.mem.Allocator) !Result {
    const loop = try zv.Loop.init(allocator, .{ .initial_watcher_capacity = num_watchers });
    defer loop.destroy();
    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }
    const watchers = try allocator.alloc(zv.io.Watcher, num_watchers);
    defer allocator.free(watchers);

    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        try startZvAll(watchers, loop, pipes);
        try stopZvAll(watchers);
    }

    for (samples) |*sample| {
        var timer = try Timer.start();
        try startZvAll(watchers, loop, pipes);
        try flushZv(loop);
        sample.* = timer.read();
        try stopZvAll(watchers);
        try flushZv(loop);
    }

    return Result.fromStats("zv (add + reify)", benchmarks.statsFromSamples(samples), num_watchers, "adds/sec");
}

fn startLibevAll(loop: *c.libev_loop, storage: *c.libev_io, pipes: [][2]std.posix.fd_t) void {
    var i: usize = 0;
    while (i < pipes.len) : (i += 1) {
        const watcher = c.libev_io_nth(storage, i);
        c.libev_io_init(watcher, libevDummyIo, pipes[i][0], c.LIBEV_READ);
        c.libev_io_start(loop, watcher);
    }
}

fn stopLibevAll(loop: *c.libev_loop, storage: *c.libev_io, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        c.libev_io_stop(loop, c.libev_io_nth(storage, i));
    }
}

fn benchLibevAdd(allocator: std.mem.Allocator) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }
    const storage = c.libev_io_alloc_array(num_watchers) orelse return error.WatcherCreationFailed;
    defer c.libev_io_free_array(storage);

    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        startLibevAll(loop, storage, pipes);
        flushLibev(loop);
        stopLibevAll(loop, storage, num_watchers);
        flushLibev(loop);
    }

    for (samples) |*sample| {
        var timer = try Timer.start();
        startLibevAll(loop, storage, pipes);
        flushLibev(loop);
        sample.* = timer.read();
        stopLibevAll(loop, storage, num_watchers);
        flushLibev(loop);
    }

    return Result.fromStats("libev (add + reify)", benchmarks.statsFromSamples(samples), num_watchers, "adds/sec");
}

fn runModify(allocator: std.mem.Allocator, writer: anytype) !void {
    const zv_result = try benchZvModify(allocator);
    const libev_result = try benchLibevModify(allocator);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try writer.writeAll("  Comparison skipped: ev_io_modify is not a kernel update.\n");
}

const ZvModifyCtx = struct { watchers: []zv.io.Watcher };

fn zvModifyTimed(ctx: ZvModifyCtx) !void {
    var round: usize = 0;
    while (round < modifications) : (round += 1) {
        const event = if (round % 2 == 0) zv.io.Event.write else zv.io.Event.read;
        for (ctx.watchers) |*w| try w.modify(event);
    }
}

fn benchZvModify(allocator: std.mem.Allocator) !Result {
    const loop = try zv.Loop.init(allocator, .{ .initial_watcher_capacity = num_watchers });
    defer loop.destroy();
    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }
    const watchers = try allocator.alloc(zv.io.Watcher, num_watchers);
    defer allocator.free(watchers);
    try startZvAll(watchers, loop, pipes);
    defer stopZvAll(watchers) catch {};

    const stats = try benchmarks.measure(allocator, warmup_count, sample_count, ZvModifyCtx{
        .watchers = watchers,
    }, zvModifyTimed);
    return Result.fromStats("zv (modify API)", stats, num_watchers * modifications, "modifies/sec");
}

const LibevModifyCtx = struct { storage: *c.libev_io, n: usize };

fn libevModifyTimed(ctx: LibevModifyCtx) !void {
    var round: usize = 0;
    while (round < modifications) : (round += 1) {
        const event: c_int = if (round % 2 == 0) c.LIBEV_WRITE else c.LIBEV_READ;
        applyLibevModify(ctx.storage, ctx.n, event);
    }
}

fn applyLibevModify(storage: *c.libev_io, n: usize, event: c_int) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        c.libev_io_modify(c.libev_io_nth(storage, i), event);
    }
}

fn benchLibevModify(allocator: std.mem.Allocator) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }
    const storage = c.libev_io_alloc_array(num_watchers) orelse return error.WatcherCreationFailed;
    defer c.libev_io_free_array(storage);
    startLibevAll(loop, storage, pipes);
    flushLibev(loop);
    defer {
        stopLibevAll(loop, storage, num_watchers);
        flushLibev(loop);
    }

    const stats = try benchmarks.measure(allocator, warmup_count, sample_count, LibevModifyCtx{
        .storage = storage,
        .n = num_watchers,
    }, libevModifyTimed);
    return Result.fromStats("libev (modify API)", stats, num_watchers * modifications, "modifies/sec");
}

fn runRemove(allocator: std.mem.Allocator, writer: anytype) !void {
    const zv_result = try benchZvRemove(allocator);
    const libev_result = try benchLibevRemove(allocator);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try Result.compareTime(libev_result, zv_result, writer);
}

fn benchZvRemove(allocator: std.mem.Allocator) !Result {
    const loop = try zv.Loop.init(allocator, .{ .initial_watcher_capacity = num_watchers });
    defer loop.destroy();
    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }
    const watchers = try allocator.alloc(zv.io.Watcher, num_watchers);
    defer allocator.free(watchers);

    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        try startZvAll(watchers, loop, pipes);
        try stopZvAll(watchers);
    }

    for (samples) |*sample| {
        try startZvAll(watchers, loop, pipes);
        try flushZv(loop);
        var timer = try Timer.start();
        try stopZvAll(watchers);
        try flushZv(loop);
        sample.* = timer.read();
    }

    return Result.fromStats("zv (remove + reify)", benchmarks.statsFromSamples(samples), num_watchers, "stops/sec");
}

fn benchLibevRemove(allocator: std.mem.Allocator) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const pipes = try openPipes(allocator, num_watchers);
    defer {
        closePipes(pipes);
        allocator.free(pipes);
    }
    const storage = c.libev_io_alloc_array(num_watchers) orelse return error.WatcherCreationFailed;
    defer c.libev_io_free_array(storage);

    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        startLibevAll(loop, storage, pipes);
        flushLibev(loop);
        stopLibevAll(loop, storage, num_watchers);
        flushLibev(loop);
    }

    for (samples) |*sample| {
        startLibevAll(loop, storage, pipes);
        flushLibev(loop);
        var timer = try Timer.start();
        stopLibevAll(loop, storage, num_watchers);
        flushLibev(loop);
        sample.* = timer.read();
    }

    return Result.fromStats("libev (remove + reify)", benchmarks.statsFromSamples(samples), num_watchers, "stops/sec");
}
