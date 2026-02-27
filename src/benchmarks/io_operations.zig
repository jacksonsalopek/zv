//! IO Watcher Operations Benchmark
//!
//! Measures performance of add/modify/remove operations for IO watchers.

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
    try writer.writeAll("IO Watcher Operations Benchmark\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Scenario 1: Add watchers\n");
    try benchmarkAddWatchers(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 2: Modify watchers\n");
    try benchmarkModifyWatchers(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("Scenario 3: Remove watchers\n");
    try benchmarkRemoveWatchers(allocator, writer);

    try writer.writeAll("\n✓ IO operations benchmark completed!\n");
}

fn benchmarkAddWatchers(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_watchers: usize = 1000;

    const zv_result = try benchmarkZvAdd(allocator, num_watchers);
    const libev_result = try benchmarkLibevAdd(num_watchers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

fn benchmarkZvAdd(allocator: std.mem.Allocator, num_watchers: usize) !Result {
    var tracker = AllocTracker{ .parent_allocator = allocator };
    const tracked = tracker.allocator();

    var loop = try zv.Loop.init(tracked, .{ .initial_watcher_capacity = num_watchers });
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
        .name = "zv (add watchers)",
        .time_ns = elapsed,
        .iterations = num_watchers,
        .allocations = stats.allocations,
        .bytes_allocated = stats.bytes_allocated,
    };
}

fn dummyCallback(_: *zv.io.Watcher, _: zv.Backend.EventMask) void {}

fn benchmarkLibevAdd(num_watchers: usize) !Result {
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
        .name = "libev (add watchers)",
        .time_ns = elapsed,
        .iterations = num_watchers,
    };
}

fn libevDummyCallback(_: ?*c.libev_loop, _: ?*c.libev_io, _: c_int) callconv(.c) void {}

fn benchmarkModifyWatchers(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_watchers: usize = 1000;
    const modifications: usize = 10;

    const zv_result = try benchmarkZvModify(allocator, num_watchers, modifications);
    const libev_result = try benchmarkLibevModify(num_watchers, modifications);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

fn benchmarkZvModify(allocator: std.mem.Allocator, num_watchers: usize, modifications: usize) !Result {
    var loop = try zv.Loop.init(allocator, .{ .initial_watcher_capacity = num_watchers });
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
    while (i < modifications) : (i += 1) {
        for (watchers) |*w| {
            const new_event = if (i % 2 == 0) zv.io.Event.write else zv.io.Event.read;
            try w.modify(new_event);
        }
    }

    const elapsed = timer.read();

    return Result{
        .name = "zv (modify watchers)",
        .time_ns = elapsed,
        .iterations = num_watchers * modifications,
    };
}

fn benchmarkLibevModify(num_watchers: usize, modifications: usize) !Result {
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
    while (i < modifications) : (i += 1) {
        for (watchers) |w| {
            if (w) |watcher| {
                const new_event = if (i % 2 == 0) c.LIBEV_WRITE else c.LIBEV_READ;
                c.libev_io_modify(watcher, new_event);
            }
        }
    }

    const elapsed = timer.read();

    return Result{
        .name = "libev (modify watchers)",
        .time_ns = elapsed,
        .iterations = num_watchers * modifications,
    };
}

fn benchmarkRemoveWatchers(allocator: std.mem.Allocator, writer: anytype) !void {
    const num_watchers: usize = 1000;

    const zv_result = try benchmarkZvRemove(allocator, num_watchers);
    const libev_result = try benchmarkLibevRemove(num_watchers);

    try zv_result.print(writer);
    try libev_result.print(writer);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try Result.compare(libev_result, zv_result, fbs.writer());
    try writer.writeAll(fbs.getWritten());
}

fn benchmarkZvRemove(allocator: std.mem.Allocator, num_watchers: usize) !Result {
    var loop = try zv.Loop.init(allocator, .{ .initial_watcher_capacity = num_watchers });
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
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    var timer = try Timer.start();

    for (watchers) |*w| {
        try w.stop();
    }

    const elapsed = timer.read();

    return Result{
        .name = "zv (remove watchers)",
        .time_ns = elapsed,
        .iterations = num_watchers,
    };
}

fn benchmarkLibevRemove(num_watchers: usize) !Result {
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
        for (pipes) |p| {
            std.posix.close(p[0]);
            std.posix.close(p[1]);
        }
    }

    var timer = try Timer.start();

    for (watchers) |w| {
        if (w) |watcher| {
            c.libev_io_stop(loop, watcher);
            c.libev_io_destroy(watcher);
        }
    }

    const elapsed = timer.read();

    return Result{
        .name = "libev (remove watchers)",
        .time_ns = elapsed,
        .iterations = num_watchers,
    };
}

test "benchmark runs" {
    const testing = std.testing;
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try run(testing.allocator, fbs.writer());
}
