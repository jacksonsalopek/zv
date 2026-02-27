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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Prepare/Check Watcher Example\n", .{});
    std.debug.print("=============================\n\n", .{});

    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    // Create a pipe for IO events
    const pipe = try std.posix.pipe();
    defer {
        std.posix.close(pipe[0]);
        std.posix.close(pipe[1]);
    }

    // Prepare watcher - runs BEFORE polling
    var prepare = zv.prepare.Watcher.init(&loop, prepareCallback);
    try prepare.start();
    defer prepare.stop();

    // Check watcher - runs AFTER polling
    var check = zv.check.Watcher.init(&loop, checkCallback);
    try check.start();
    defer check.stop();

    // IO watcher - triggers during poll
    var io = zv.io.Watcher.init(&loop, pipe[0], .read, ioCallback);
    try io.start();
    defer io.stop() catch {};

    // Timer to stop after a few iterations
    var stop_timer = zv.timer.Watcher.init(&loop, zv.time.seconds(2), 0, stopCallback);
    try stop_timer.start();
    defer stop_timer.stop();

    // Write some data to trigger the IO watcher
    _ = try std.posix.write(pipe[1], "test");

    std.debug.print("Running loop...\n\n", .{});
    try loop.run(.until_done);

    std.debug.print("\n=============================\n", .{});
    std.debug.print("Final counts:\n", .{});
    std.debug.print("  Prepare callbacks: {d}\n", .{prepare_count});
    std.debug.print("  Check callbacks:   {d}\n", .{check_count});
    std.debug.print("  IO callbacks:      {d}\n", .{io_count});
    std.debug.print("\nNote: Prepare and check callbacks run on every loop iteration!\n", .{});
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
    
    // Read and discard the data
    var buf: [64]u8 = undefined;
    _ = std.posix.read(watcher.fd, &buf) catch 0;
}

fn stopCallback(watcher: *zv.timer.Watcher) void {
    std.debug.print("[TIMER] Stopping loop after 2 seconds\n", .{});
    watcher.stop();
}
