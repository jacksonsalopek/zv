//! Benchmark comparing IO watcher registration/unregistration
//!
//! Measures the overhead of adding and removing file descriptor watchers.

const std = @import("std");
const zv = @import("zv");
const common = @import("common.zig");
const c = @cImport({
    @cInclude("ev.h");
    @cInclude("unistd.h");
});

/// Create a pipe for testing
fn createTestPipe() ![2]std.posix.fd_t {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeCreationFailed;
    return .{ fds[0], fds[1] };
}

/// Benchmark zv IO watcher registration
fn benchmarkZvIoWatchers(allocator: std.mem.Allocator, iterations: u64) !common.Result {
    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    const fds = try createTestPipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    const DummyCallback = struct {
        fn callback(watcher: *zv.io.Watcher, events: zv.Backend.EventMask) void {
            _ = watcher;
            _ = events;
        }
    };

    var watchers = try allocator.alloc(zv.io.Watcher, iterations);
    defer allocator.free(watchers);

    var timer = try common.Timer.start();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        watchers[i] = zv.io.Watcher.init(&loop, fds[0], .read, DummyCallback.callback);
        try watchers[i].start();
    }

    i = 0;
    while (i < iterations) : (i += 1) {
        try watchers[i].stop();
    }

    const elapsed = timer.read();

    return .{
        .name = "zv IO watchers",
        .iterations = iterations * 2,
        .total_ns = elapsed,
        .min_ns = elapsed / (iterations * 2),
        .max_ns = elapsed / (iterations * 2),
        .mean_ns = elapsed / (iterations * 2),
        .median_ns = elapsed / (iterations * 2),
    };
}

/// Benchmark libev IO watcher registration
fn benchmarkLibevIoWatchers(allocator: std.mem.Allocator, iterations: u64) !common.Result {
    const loop = c.ev_loop_new(c.EVFLAG_AUTO);
    defer c.ev_loop_destroy(loop);

    const fds = try createTestPipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    const DummyCallback = struct {
        fn callback(
            loop_ptr: ?*c.struct_ev_loop,
            watcher: [*c]c.ev_io,
            revents: c_int,
        ) callconv(.c) void {
            _ = loop_ptr;
            _ = watcher;
            _ = revents;
        }
    };

    var watchers = try allocator.alloc(c.ev_io, iterations);
    defer allocator.free(watchers);

    var timer = try common.Timer.start();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        c.ev_io_init(&watchers[i], DummyCallback.callback, fds[0], c.EV_READ);
        c.ev_io_start(loop, &watchers[i]);
    }

    i = 0;
    while (i < iterations) : (i += 1) {
        c.ev_io_stop(loop, &watchers[i]);
    }

    const elapsed = timer.read();

    return .{
        .name = "libev IO watchers",
        .iterations = iterations * 2,
        .total_ns = elapsed,
        .min_ns = elapsed / (iterations * 2),
        .max_ns = elapsed / (iterations * 2),
        .mean_ns = elapsed / (iterations * 2),
        .median_ns = elapsed / (iterations * 2),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const config = common.Config{ .iterations = 1_000 };

    try stdout.print("Running IO watcher benchmark ({d} operations)...\n\n", .{config.iterations * 2});

    const zv_result = try benchmarkZvIoWatchers(allocator, config.iterations);
    const libev_result = try benchmarkLibevIoWatchers(allocator, config.iterations);

    const comparison = common.Comparison.init(zv_result, libev_result);
    try stdout.print("{}", .{comparison});
}
