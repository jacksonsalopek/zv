//! Basic usage example for zv event loop
//!
//! Demonstrates creating a loop, a repeating timer, and run(.once).

const std = @import("std");
const zv = @import("zv");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("zv Event Loop Example\n", .{});
    try stdout.print("Backend: {t}\n\n", .{zv.Backend.selectBest()});

    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();

    var timer = zv.timer.Watcher.init(
        loop,
        zv.time.seconds(1),
        zv.time.seconds(1),
        timerCallback,
    );
    try timer.start();
    defer timer.stop();

    try stdout.print("Starting event loop...\n", .{});
    try stdout.print("Timer will fire every second.\n", .{});
    try stdout.print("Press Ctrl+C to exit.\n\n", .{});
    try stdout.flush();

    var count: usize = 0;
    while (count < 5) : (count += 1) {
        try loop.run(.once);
    }

    try stdout.print("\nEvent loop example complete!\n", .{});
    try stdout.flush();
}

fn timerCallback(watcher: *zv.timer.Watcher) void {
    _ = watcher;
    std.debug.print("[{}] Timer fired!\n", .{zv.time.now()});
}
