//! Check watcher for post-poll callbacks
//!
//! Executes callbacks after the event loop wakes up from blocking.
//! Useful for integrating other event loops or performing cleanup work.

const std = @import("std");
const Loop = @import("../loop.zig");

pub const Callback = *const fn (watcher: *Watcher) void;

pub const Watcher = struct {
    loop: *Loop,
    callback: Callback,
    active: bool,

    pub fn init(loop: *Loop, callback: Callback) Watcher {
        return .{
            .loop = loop,
            .callback = callback,
            .active = false,
        };
    }

    pub fn start(self: *Watcher) !void {
        if (self.active) return;

        try self.loop.registerCheck(self);
        self.active = true;
    }

    pub fn stop(self: *Watcher) void {
        if (!self.active) return;

        self.loop.unregisterCheck(self);
        self.active = false;
    }

    pub fn invoke(self: *Watcher) void {
        self.callback(self);
    }
};

test "check watcher init" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher) void {
            _ = watcher;
        }
    };

    const watcher = Watcher.init(&loop, DummyCallback.callback);
    try testing.expect(!watcher.active);
}
