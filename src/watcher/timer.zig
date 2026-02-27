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
            .heap_index = undefined,
        };
    }

    pub fn start(self: *Watcher) !void {
        if (self.active) return;

        self.deadline = self.loop.now() + self.timeout_ns;
        try self.loop.registerTimer(self);
        self.active = true;
    }

    pub fn stop(self: *Watcher) void {
        if (!self.active) return;

        self.loop.unregisterTimer(self);
        self.active = false;
    }

    pub fn again(self: *Watcher) !void {
        if (self.repeat_ns == 0) return error.NotRepeating;

        self.stop();
        self.timeout_ns = self.repeat_ns;
        try self.start();
    }

    pub fn remaining(self: *Watcher) u64 {
        if (!self.active) return 0;

        const now = self.loop.now();
        if (now >= self.deadline) return 0;

        return self.deadline - now;
    }

    pub fn isExpired(self: *Watcher, now: time.Timestamp) bool {
        return self.active and now >= self.deadline;
    }

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

    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    const watcher = Watcher.init(&loop, time.seconds(1), 0, DummyCallback.callback);
    try testing.expect(!watcher.active);
    try testing.expectEqual(time.seconds(1), watcher.timeout_ns);
}

test "timer expiration" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    var watcher = Watcher.init(&loop, time.milliseconds(100), 0, DummyCallback.callback);
    try watcher.start();

    const now = loop.now();
    try testing.expect(!watcher.isExpired(now));
    try testing.expect(watcher.isExpired(now + time.milliseconds(200)));

    watcher.stop();
}
