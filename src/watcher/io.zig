//! IO watcher for monitoring file descriptors
//!
//! Watches file descriptors for read/write availability.

const std = @import("std");
const Loop = @import("../loop.zig");
const Backend = @import("../backend.zig");

pub const Event = enum {
    read,
    write,
    both,

    fn toInterest(self: Event) Backend.Interest {
        return switch (self) {
            .read => .{ .read = true },
            .write => .{ .write = true },
            .both => .{ .read = true, .write = true },
        };
    }
};

pub const Callback = *const fn (watcher: *Watcher, events: Backend.EventMask) void;

pub const Watcher = struct {
    loop: *Loop,
    fd: std.posix.fd_t,
    events: Event,
    callback: Callback,
    active: bool,

    pub fn init(
        loop: *Loop,
        fd: std.posix.fd_t,
        events: Event,
        callback: Callback,
    ) Watcher {
        return .{
            .loop = loop,
            .fd = fd,
            .events = events,
            .callback = callback,
            .active = false,
        };
    }

    pub fn start(self: *Watcher) !void {
        if (self.active) return;

        try self.loop.backend.add(self.fd, self.events.toInterest());
        try self.loop.registerIoWatcher(self.fd, self);
        self.active = true;
    }

    pub fn stop(self: *Watcher) !void {
        if (!self.active) return;

        try self.loop.backend.remove(self.fd);
        self.loop.unregisterIoWatcher(self.fd);
        self.active = false;
    }

    pub fn modify(self: *Watcher, events: Event) !void {
        if (!self.active) return error.NotActive;

        self.events = events;
        try self.loop.backend.modify(self.fd, events.toInterest());
    }

    pub fn invoke(self: *Watcher, event_mask: Backend.EventMask) void {
        self.callback(self, event_mask);
    }
};

test "io watcher init" {
    const testing = std.testing;

    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = watcher;
            _ = events;
        }
    };

    const watcher = Watcher.init(&loop, 0, .read, DummyCallback.callback);
    try testing.expect(!watcher.active);
    try testing.expectEqual(0, watcher.fd);
}
