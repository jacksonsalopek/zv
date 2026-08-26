//! Example demonstrating prepare and check watchers
//!
//! Prepare watchers run before the loop polls for events
//! Check watchers run after the loop polls for events
//!
//! This is useful for:
//! - Integrating other event loops
//! - Performing bookkeeping before/after polling
//! - Measuring poll latency

const std = @import("std");
const zv = @import("zv");

var prepare_count: usize = 0;
var check_count: usize = 0;
var io_count: usize = 0;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Prepare/Check Watcher Example\n", .{});
    try stdout.print("=============================\n\n", .{});

    var loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();

    const pipe = try zv.sys.pipe();
    defer {
        zv.sys.close(pipe[0]);
        zv.sys.close(pipe[1]);
    }

    var prepare = zv.prepare.Watcher.init(loop, prepareCallback);
    try prepare.start();
    defer prepare.stop();

    var check = zv.check.Watcher.init(loop, checkCallback);
    try check.start();
    defer check.stop();

    var io = zv.io.Watcher.init(loop, pipe[0], .read, ioCallback);
    try io.start();
    defer io.stop() catch {};

    var stop_timer = zv.timer.Watcher.init(loop, zv.time.seconds(2), 0, stopCallback);
    try stop_timer.start();
    defer stop_timer.stop();

    _ = try zv.sys.write(pipe[1], "test");

    try stdout.print("Running loop...\n\n", .{});
    try stdout.flush();
    try loop.run(.until_done);

    try stdout.print("\n=============================\n", .{});
    try stdout.print("Final counts:\n", .{});
    try stdout.print("  Prepare callbacks: {d}\n", .{prepare_count});
    try stdout.print("  Check callbacks:   {d}\n", .{check_count});
    try stdout.print("  IO callbacks:      {d}\n", .{io_count});
    try stdout.print("\nNote: Prepare and check callbacks run on every loop iteration!\n", .{});
    try stdout.flush();
}

fn prepareCallback(watcher: *zv.prepare.Watcher) void {
    _ = watcher;
    prepare_count += 1;
    std.debug.print("[PREPARE] About to poll (count: {d})\n", .{prepare_count});
}

fn checkCallback(watcher: *zv.check.Watcher) void {
    _ = watcher;
    check_count += 1;
    std.debug.print("[CHECK] Just finished polling (count: {d})\n", .{check_count});
}

fn ioCallback(watcher: *zv.io.Watcher, events: zv.Backend.EventMask) void {
    _ = events;
    io_count += 1;
    std.debug.print("[IO] Data available on fd {d}\n", .{watcher.fd});

    var buf: [64]u8 = undefined;
    _ = std.posix.read(watcher.fd, &buf) catch 0;
}

fn stopCallback(watcher: *zv.timer.Watcher) void {
    std.debug.print("[TIMER] Stopping loop after 2 seconds\n", .{});
    watcher.stop();
}
