//! Prepare watcher for pre-poll callbacks
//!
//! Executes callbacks before the event loop blocks waiting for events.
//! Useful for integrating other event loops or performing setup work.

const std = @import("std");
const Loop = @import("../loop.zig");

pub const Callback = *const fn (watcher: *Watcher) void;

pub const Watcher = struct {
    loop: *Loop,
    callback: Callback,
    active: bool,

    /// Create an inactive watcher; the callback runs before the loop blocks.
    pub fn init(loop: *Loop, callback: Callback) Watcher {
        return .{
            .loop = loop,
            .callback = callback,
            .active = false,
        };
    }

    /// Register to run before the loop blocks waiting for events.
    pub fn start(self: *Watcher) !void {
        if (self.active) return;

        try self.loop.registerPrepare(self);
        self.active = true;
    }

    /// Stop receiving prepare callbacks. No-op if inactive.
    pub fn stop(self: *Watcher) void {
        if (!self.active) return;

        self.loop.unregisterPrepare(self);
        self.active = false;
    }

    /// Called by the loop to dispatch `callback`.
    pub fn invoke(self: *Watcher) void {
        self.callback(self);
    }
};

test "prepare watcher init" {
    const testing = std.testing;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    const watcher = Watcher.init(loop, DummyCallback.callback);
    try testing.expect(!watcher.active);
}

test "prepare callback can start a timer" {
    const testing = std.testing;
    const time = @import("../time.zig");
    const TimerWatcher = @import("timer.zig").Watcher;

    const TestState = struct {
        var timer_started: bool = false;
        var timer_fired: bool = false;
        var timer: TimerWatcher = undefined;

        fn prepareCb(watcher: *Watcher) void {
            if (timer_started) return;
            timer = TimerWatcher.init(watcher.loop, time.milliseconds(1), 0, timerCb);
            timer.start() catch return;
            timer_started = true;
        }

        fn timerCb(watcher: *TimerWatcher) void {
            _ = watcher;
            timer_fired = true;
        }
    };
    TestState.timer_started = false;
    TestState.timer_fired = false;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    var prepare_watcher = Watcher.init(loop, TestState.prepareCb);
    try prepare_watcher.start();
    defer prepare_watcher.stop();

    try loop.run(.until_done);
    try testing.expect(TestState.timer_started);
    try testing.expect(TestState.timer_fired);
}
