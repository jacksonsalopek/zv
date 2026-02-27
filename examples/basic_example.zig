//! Basic usage example for zv event loop
//!
//! This example demonstrates:
//! - Creating an event loop
//! - Setting up an IO watcher
//! - Setting up a timer
//! - Running the loop

const std = @import("std");
const zv = @import("zv");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("zv Event Loop Example\n", .{});
    std.debug.print("Backend: {s}\n\n", .{@tagName(zv.Backend.selectBest())});

    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    var timer = zv.timer.Watcher.init(
        &loop,
        zv.time.seconds(1),
        zv.time.seconds(1),
        timerCallback,
    );
    try timer.start();
    defer timer.stop();

    std.debug.print("Starting event loop...\n", .{});
    std.debug.print("Timer will fire every second.\n", .{});
    std.debug.print("Press Ctrl+C to exit.\n\n", .{});

    var count: usize = 0;
    while (count < 5) : (count += 1) {
        try loop.run(.once);
    }

    std.debug.print("\nEvent loop example complete!\n", .{});
}

fn timerCallback(watcher: *zv.timer.Watcher) void {
    _ = watcher;
    const time = std.time.timestamp();
    std.debug.print("[{}] Timer fired!\n", .{time});
}
