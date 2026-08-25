//! Timer watcher for time-based events
//!
//! Executes callbacks after a specified time interval.

const std = @import("std");
const Loop = @import("../loop.zig");
const time = @import("../time.zig");

pub const Callback = *const fn (watcher: *Watcher) void;

pub const Watcher = struct {
    loop: *Loop,
    callback: Callback,
    timeout_ns: u64,
    deadline: time.Timestamp,
    repeat_ns: u64,
    active: bool,
    heap_index: usize,

    /// Create an inactive timer with initial timeout and optional repeat interval.
    pub fn init(
        loop: *Loop,
        timeout_ns: u64,
        repeat_ns: u64,
        callback: Callback,
    ) Watcher {
        return .{
            .loop = loop,
            .callback = callback,
            .timeout_ns = timeout_ns,
            .deadline = 0,
            .repeat_ns = repeat_ns,
            .active = false,
            .heap_index = std.math.maxInt(usize),
        };
    }

    /// Arm the timer and register it with the loop.
    pub fn start(self: *Watcher) !void {
        if (self.active) return;

        self.deadline = self.loop.now() + self.timeout_ns;
        try self.loop.registerTimer(self);
        self.loop.addKeeper();
        self.active = true;
    }

    /// Disarm the timer and unregister it from the loop.
    pub fn stop(self: *Watcher) void {
        if (!self.active) return;

        self.active = false;
        self.loop.unregisterTimer(self);
        self.loop.removeKeeper();
    }

    /// Restart using `repeat_ns` as the new timeout (libev `ev_timer_again`).
    /// An active oneshot (`repeat_ns == 0`) is stopped; an inactive oneshot is a no-op.
    pub fn again(self: *Watcher) !void {
        if (self.active) self.stop();
        if (self.repeat_ns == 0) return;

        self.timeout_ns = self.repeat_ns;
        try self.start();
    }

    /// Nanoseconds until the deadline, or 0 if inactive or already due.
    pub fn remaining(self: *Watcher) u64 {
        if (!self.active) return 0;

        const now = self.loop.now();
        if (now >= self.deadline) return 0;

        return self.deadline - now;
    }

    /// True if the timer is active and `now` is at or past the deadline.
    pub fn isExpired(self: *Watcher, now: time.Timestamp) bool {
        return self.active and now >= self.deadline;
    }

    /// Call the callback, then reschedule if repeating or stop if oneshot.
    pub fn invoke(self: *Watcher) void {
        self.callback(self);

        if (self.repeat_ns > 0) {
            self.deadline = self.loop.now() + self.repeat_ns;
        } else {
            self.stop();
        }
    }
};

test "timer watcher init" {
    const testing = std.testing;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    const watcher = Watcher.init(loop, time.seconds(1), 0, DummyCallback.callback);
    try testing.expect(!watcher.active);
    try testing.expectEqual(time.seconds(1), watcher.timeout_ns);
}

test "timer expiration" {
    const testing = std.testing;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    var watcher = Watcher.init(loop, time.milliseconds(100), 0, DummyCallback.callback);
    try watcher.start();

    const now = loop.now();
    try testing.expect(!watcher.isExpired(now));
    try testing.expect(watcher.isExpired(now + time.milliseconds(200)));

    watcher.stop();
}

test "timer again stops oneshot" {
    const testing = std.testing;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    var watcher = Watcher.init(loop, time.seconds(1), 0, DummyCallback.callback);
    try watcher.start();
    try testing.expect(watcher.active);

    try watcher.again();
    try testing.expect(!watcher.active);
}

test "timer again restarts repeating" {
    const testing = std.testing;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    var watcher = Watcher.init(loop, time.seconds(10), time.milliseconds(50), DummyCallback.callback);
    try watcher.start();
    const first_deadline = watcher.deadline;

    try watcher.again();
    try testing.expect(watcher.active);
    try testing.expectEqual(time.milliseconds(50), watcher.timeout_ns);
    try testing.expect(watcher.deadline < first_deadline);
}
