//! Signal watcher for Unix signals
//!
//! Handles Unix signals in the event loop.

const std = @import("std");
const Loop = @import("../loop.zig");
const builtin = @import("builtin");

pub const Callback = *const fn (watcher: *Watcher, signum: c_int) void;

pub const Watcher = struct {
    loop: *Loop,
    signum: c_int,
    callback: Callback,
    active: bool,
    pipe_fds: ?struct {
        read: std.posix.fd_t,
        write: std.posix.fd_t,
    },

    pub fn init(
        loop: *Loop,
        signum: c_int,
        callback: Callback,
    ) Watcher {
        return .{
            .loop = loop,
            .signum = signum,
            .callback = callback,
            .active = false,
            .pipe_fds = null,
        };
    }

    pub fn start(self: *Watcher) !void {
        if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
        if (self.active) return;

        const fds = try std.posix.pipe();
        errdefer {
            std.posix.close(fds[0]);
            std.posix.close(fds[1]);
        }

        self.pipe_fds = .{
            .read = fds[0],
            .write = fds[1],
        };

        self.active = true;
    }

    pub fn stop(self: *Watcher) void {
        if (!self.active) return;

        if (self.pipe_fds) |fds| {
            std.posix.close(fds.read);
            std.posix.close(fds.write);
            self.pipe_fds = null;
        }

        self.active = false;
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
    }

    pub fn invoke(self: *Watcher) void {
        self.callback(self, self.signum);
    }
};

test "signal watcher init" {
    const testing = std.testing;

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            _ = signum;
        }
    };

    const SIGINT = if (builtin.os.tag == .linux) 2 else std.posix.SIG.INT;
    var watcher = Watcher.init(&loop, SIGINT, DummyCallback.callback);
    defer watcher.deinit();

    try testing.expect(!watcher.active);
}
