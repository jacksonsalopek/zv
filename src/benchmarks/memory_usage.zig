//! zv heap usage via AllocTracker.
//!
//! libev uses libc malloc which this tracker cannot see. We report static
//! struct sizes for both libraries and zv heap only. No memory "speedup".

const std = @import("std");
const zv = @import("zv");
const benchmarks = @import("infra.zig");
const Result = benchmarks.Result;
const AllocTracker = benchmarks.AllocTracker;

const c = @cImport({
    @cInclude("libev_wrapper.h");
});

fn dummyIo(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {}
fn dummyTimer(_: *zv.timer.Watcher) void {}

pub fn run(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\nMemory Usage (zv heap; libev malloc not measured)\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Static watcher sizes (compile-time / sizeof):\n");
    try writer.print("  zv.io.Watcher:     {d} bytes\n", .{@sizeOf(zv.io.Watcher)});
    try writer.print("  libev ev_io:       {d} bytes\n", .{c.libev_io_sizeof()});
    try writer.print("  zv.timer.Watcher:  {d} bytes\n", .{@sizeOf(zv.timer.Watcher)});
    try writer.print("  libev ev_timer:    {d} bytes\n", .{c.libev_timer_sizeof()});
    try writer.writeAll(
        \\
        \\These sizes are not total cost: both libraries allocate backend
        \\tables (epoll interest lists, timer heaps). Only zv heap via the
        \\Zig allocator is counted below.
        \\
    );

    try writer.writeAll("\nScenario 1: Loop initialization (zv heap)\n");
    try printZv(writer, try benchZvLoopInit(allocator));

    try writer.writeAll("\nScenario 2: 1000 IO watchers start (zv heap after reset)\n");
    try printZv(writer, try benchZvIo(allocator, 1000));

    try writer.writeAll("\nScenario 3: 1000 timer starts (zv heap after reset)\n");
    try printZv(writer, try benchZvTimers(allocator, 1000));

    try writer.writeAll("\nScenario 4: 500 IO + 500 timers (zv heap after reset)\n");
    try printZv(writer, try benchZvMixed(allocator, 500, 500));

    try writer.writeAll("\nMemory usage benchmark completed. No libev memory comparison.\n");
}

fn printZv(writer: anytype, result: Result) !void {
    try result.print(writer);
}

fn benchZvLoopInit(allocator: std.mem.Allocator) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();
    const loop = try zv.Loop.init(tracked, .{});
    defer loop.destroy();
    const stats = tracker.snapshot();
    return .{
        .name = "zv (loop init heap)",
        .time_ns = 0,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}

fn closePipes(pipes: [][2]std.posix.fd_t) void {
    for (pipes) |p| {
        zv.sys.close(p[0]);
        zv.sys.close(p[1]);
    }
}

fn benchZvIo(allocator: std.mem.Allocator, n: usize) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();
    const loop = try zv.Loop.init(tracked, .{});
    defer loop.destroy();

    const pipes = try tracked.alloc([2]std.posix.fd_t, n);
    defer tracked.free(pipes);
    const watchers = try tracked.alloc(zv.io.Watcher, n);
    defer tracked.free(watchers);

    for (pipes) |*p| p.* = try zv.sys.pipe();
    defer closePipes(pipes);

    tracker.reset();
    for (pipes, 0..) |p, i| {
        watchers[i] = zv.io.Watcher.init(loop, p[0], .read, dummyIo);
        try watchers[i].start();
    }
    defer {
        for (watchers) |*w| w.stop() catch {};
    }

    const stats = tracker.snapshot();
    return .{
        .name = "zv (1000 IO watcher starts)",
        .time_ns = 0,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}

fn benchZvTimers(allocator: std.mem.Allocator, n: usize) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();
    const loop = try zv.Loop.init(tracked, .{});
    defer loop.destroy();

    const watchers = try tracked.alloc(zv.timer.Watcher, n);
    defer tracked.free(watchers);

    tracker.reset();
    for (watchers, 0..) |*w, i| {
        w.* = zv.timer.Watcher.init(loop, (i + 1) * std.time.ns_per_ms, 0, dummyTimer);
        try w.start();
    }
    defer {
        for (watchers) |*w| w.stop();
    }

    const stats = tracker.snapshot();
    return .{
        .name = "zv (1000 timer starts)",
        .time_ns = 0,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}

fn benchZvMixed(allocator: std.mem.Allocator, num_io: usize, num_timers: usize) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();
    const loop = try zv.Loop.init(tracked, .{});
    defer loop.destroy();

    const pipes = try tracked.alloc([2]std.posix.fd_t, num_io);
    defer tracked.free(pipes);
    const io_watchers = try tracked.alloc(zv.io.Watcher, num_io);
    defer tracked.free(io_watchers);
    const timer_watchers = try tracked.alloc(zv.timer.Watcher, num_timers);
    defer tracked.free(timer_watchers);

    for (pipes) |*p| p.* = try zv.sys.pipe();
    defer closePipes(pipes);

    tracker.reset();
    for (pipes, 0..) |p, i| {
        io_watchers[i] = zv.io.Watcher.init(loop, p[0], .read, dummyIo);
        try io_watchers[i].start();
    }
    for (timer_watchers, 0..) |*w, i| {
        w.* = zv.timer.Watcher.init(loop, (i + 1) * std.time.ns_per_ms, 0, dummyTimer);
        try w.start();
    }
    defer {
        for (io_watchers) |*w| w.stop() catch {};
        for (timer_watchers) |*w| w.stop();
    }

    const stats = tracker.snapshot();
    return .{
        .name = "zv (500 IO + 500 timer starts)",
        .time_ns = 0,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
        .peak_memory = stats.peak_memory,
    };
}
