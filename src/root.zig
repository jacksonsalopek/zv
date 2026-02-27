//! zv - A Zig port of libev with better memory safety and smaller footprint
//!
//! This library provides a high-performance event loop with support for:
//! - Multiple backends (epoll, kqueue, poll, select)
//! - IO watchers for monitoring file descriptors
//! - Timer watchers for time-based events
//! - Signal watchers for handling Unix signals
//!
//! Example usage:
//! ```zig
//! const zv = @import("zv");
//!
//! var loop = try zv.Loop.init(allocator, .{});
//! defer loop.deinit();
//!
//! var io = zv.io.Watcher.init(&loop, fd, .read, callback);
//! try io.start();
//!
//! try loop.run(.until_done);
//! ```

const std = @import("std");

pub const Loop = @import("loop.zig");
pub const Backend = @import("backend.zig");
pub const time = @import("time.zig");

pub const io = struct {
    pub const Watcher = @import("watcher/io.zig").Watcher;
    pub const Event = @import("watcher/io.zig").Event;
};

pub const timer = struct {
    pub const Watcher = @import("watcher/timer.zig").Watcher;
};

pub const signal = struct {
    pub const Watcher = @import("watcher/signal.zig").Watcher;
};

pub const prepare = struct {
    pub const Watcher = @import("watcher/prepare.zig").Watcher;
};

pub const check = struct {
    pub const Watcher = @import("watcher/check.zig").Watcher;
};

test {
    std.testing.refAllDecls(@This());
}

test "prepare and check watchers" {
    const testing = std.testing;

    const TestState = struct {
        var prepare_called: bool = false;
        var check_called: bool = false;
        var timer_called: bool = false;

        fn prepareCallback(watcher: *prepare.Watcher) void {
            _ = watcher;
            prepare_called = true;
        }

        fn checkCallback(watcher: *check.Watcher) void {
            _ = watcher;
            check_called = true;
        }

        fn timerCallback(watcher: *timer.Watcher) void {
            timer_called = true;
            watcher.stop();
        }
    };

    TestState.prepare_called = false;
    TestState.check_called = false;
    TestState.timer_called = false;

    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();

    var prepare_watcher = prepare.Watcher.init(&loop, TestState.prepareCallback);
    try prepare_watcher.start();
    defer prepare_watcher.stop();

    var check_watcher = check.Watcher.init(&loop, TestState.checkCallback);
    try check_watcher.start();
    defer check_watcher.stop();

    // Add a short timer so the loop has something to wait for and will stop
    var timer_watcher = timer.Watcher.init(&loop, time.milliseconds(1), 0, TestState.timerCallback);
    try timer_watcher.start();

    try loop.run(.until_done);

    try testing.expect(TestState.prepare_called);
    try testing.expect(TestState.check_called);
    try testing.expect(TestState.timer_called);
}
