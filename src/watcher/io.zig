//! IO watcher for monitoring file descriptors
//!
//! Watches file descriptors for read/write availability.
//!
//! On epoll/kqueue, `start`/`stop`/`modify` update userspace interest and mark
//! the fd dirty. Kernel registration (`epoll_ctl` / `kevent` changelist) is
//! applied in `Loop.run` before `wait` (libev `fd_reify`). A closed or
//! epoll-incompatible fd therefore succeeds in `start`; `run` returns the
//! backend error. Duplicate watchers for the same fd still fail at `start`
//! with `error.AlreadyExists`. Poll/select apply interest immediately.

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

    /// Create an inactive watcher for `fd` and `events`.
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

    /// Register interest. On epoll/kqueue, kernel registration is deferred to `run`.
    pub fn start(self: *Watcher) !void {
        if (self.active) return;

        try self.loop.backend.add(self.fd, self.events.toInterest(), self);
        self.loop.addKeeper();
        self.active = true;
    }

    /// Unregister interest. On epoll/kqueue, kernel unregistration is deferred to `run`.
    pub fn stop(self: *Watcher) !void {
        if (!self.active) return;

        self.active = false;
        self.loop.removeKeeper();
        try self.loop.backend.remove(self.fd);
    }

    /// Change monitored events. On epoll/kqueue, the kernel update is deferred to `run`.
    pub fn modify(self: *Watcher, events: Event) !void {
        if (!self.active) return error.NotActive;

        self.events = events;
        try self.loop.backend.modify(self.fd, events.toInterest(), self);
    }

    /// Called by the loop to dispatch `callback` with `event_mask`.
    pub fn invoke(self: *Watcher, event_mask: Backend.EventMask) void {
        self.callback(self, event_mask);
    }
};

test "io watcher init" {
    const testing = std.testing;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = watcher;
            _ = events;
        }
    };

    const watcher = Watcher.init(loop, 0, .read, DummyCallback.callback);
    try testing.expect(!watcher.active);
    try testing.expectEqual(0, watcher.fd);
}

test "io watcher start registers with loop" {
    const testing = std.testing;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = watcher;
            _ = events;
        }
    };

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var watcher = Watcher.init(loop, fds[0], .read, DummyCallback.callback);
    try watcher.start();
    defer watcher.stop() catch {};

    try testing.expect(watcher.active);
    try testing.expectEqual(@as(usize, 1), loop.pending_count);

    try watcher.stop();
    try testing.expect(!watcher.active);
    try testing.expectEqual(@as(usize, 0), loop.pending_count);
}

test "io watcher keeps until_done running" {
    const testing = std.testing;

    const TestState = struct {
        var fired: bool = false;

        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = events;
            fired = true;
            var buf: [8]u8 = undefined;
            _ = std.posix.read(watcher.fd, &buf) catch 0;
            watcher.stop() catch {};
        }
    };
    TestState.fired = false;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var watcher = Watcher.init(loop, fds[0], .read, TestState.callback);
    try watcher.start();
    defer watcher.stop() catch {};

    _ = try std.posix.write(fds[1], "x");
    try loop.run(.until_done);

    try testing.expect(TestState.fired);
}

test "io watcher modify preserves callback" {
    const testing = std.testing;

    const TestState = struct {
        var write_ready: bool = false;

        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            if (events.write) write_ready = true;
            watcher.stop() catch {};
        }
    };
    TestState.write_ready = false;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var watcher = Watcher.init(loop, fds[1], .read, TestState.callback);
    try watcher.start();
    defer watcher.stop() catch {};

    try watcher.modify(.write);
    try loop.run(.once);

    try testing.expect(TestState.write_ready);
}

test "io N starts then nowait arms" {
    const testing = std.testing;
    const n = 8;

    const TestState = struct {
        var fired: usize = 0;

        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = events;
            fired += 1;
            var buf: [8]u8 = undefined;
            _ = std.posix.read(watcher.fd, &buf) catch 0;
            watcher.stop() catch {};
        }
    };
    TestState.fired = 0;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    var pipes: [n][2]std.posix.fd_t = undefined;
    var opened: usize = 0;
    errdefer closeOpenedPipes(pipes[0..opened]);
    for (&pipes) |*p| {
        p.* = try std.posix.pipe();
        opened += 1;
    }
    defer closeOpenedPipes(pipes[0..opened]);

    var watchers: [n]Watcher = undefined;
    for (&watchers, &pipes) |*w, p| {
        w.* = Watcher.init(loop, p[0], .read, TestState.callback);
        try w.start();
    }
    defer stopWatchers(&watchers);

    for (pipes) |p| {
        _ = try std.posix.write(p[1], "x");
    }
    try loop.run(.nowait);
    try testing.expectEqual(@as(usize, n), TestState.fired);
}

test "io start then stop before run coalesces" {
    const testing = std.testing;

    const TestState = struct {
        var fired: bool = false;

        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = watcher;
            _ = events;
            fired = true;
        }
    };
    TestState.fired = false;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var watcher = Watcher.init(loop, fds[0], .read, TestState.callback);
    try watcher.start();
    try watcher.stop();

    _ = try std.posix.write(fds[1], "x");
    try loop.run(.nowait);

    try testing.expect(!TestState.fired);
    try testing.expectEqual(@as(usize, 0), loop.pending_count);
}

test "io modify before first wait applies" {
    const testing = std.testing;

    const TestState = struct {
        var write_ready: bool = false;

        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            if (events.write) write_ready = true;
            watcher.stop() catch {};
        }
    };
    TestState.write_ready = false;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var watcher = Watcher.init(loop, fds[1], .read, TestState.callback);
    try watcher.start();
    defer watcher.stop() catch {};

    try watcher.modify(.write);
    try loop.run(.nowait);
    try testing.expect(TestState.write_ready);
}

test "io until_done works with deferred register" {
    const testing = std.testing;

    const TestState = struct {
        var fired: bool = false;

        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = events;
            fired = true;
            var buf: [8]u8 = undefined;
            _ = std.posix.read(watcher.fd, &buf) catch 0;
            watcher.stop() catch {};
        }
    };
    TestState.fired = false;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var watcher = Watcher.init(loop, fds[0], .read, TestState.callback);
    try watcher.start();
    defer watcher.stop() catch {};

    _ = try std.posix.write(fds[1], "x");
    try loop.run(.until_done);
    try testing.expect(TestState.fired);
    try testing.expectEqual(@as(usize, 0), loop.pending_count);
}

test "io duplicate fd fails at start" {
    const testing = std.testing;

    const Dummy = struct {
        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = watcher;
            _ = events;
        }
    };

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var first = Watcher.init(loop, fds[0], .read, Dummy.callback);
    try first.start();
    defer first.stop() catch {};

    var second = Watcher.init(loop, fds[0], .write, Dummy.callback);
    try testing.expectError(error.AlreadyExists, second.start());
}

test "io kernel register error surfaces in run" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;

    const Dummy = struct {
        fn callback(watcher: *Watcher, events: Backend.EventMask) void {
            _ = watcher;
            _ = events;
        }
    };

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const fds = try std.posix.pipe();
    std.posix.close(fds[0]);
    std.posix.close(fds[1]);

    var watcher = Watcher.init(loop, fds[0], .read, Dummy.callback);
    try watcher.start();
    defer watcher.stop() catch {};

    try testing.expectError(error.BadFileDescriptor, loop.run(.nowait));
}

fn closeOpenedPipes(pipes: [][2]std.posix.fd_t) void {
    for (pipes) |p| {
        std.posix.close(p[0]);
        std.posix.close(p[1]);
    }
}

fn stopWatchers(watchers: []Watcher) void {
    for (watchers) |*w| w.stop() catch {};
}
