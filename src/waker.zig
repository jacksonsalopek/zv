//! Cross-thread wakeup mechanism for event loops
//!
//! Interrupt a blocked `backend.wait` from another thread.
//! Linux uses eventfd; other platforms use a pipe (pipe2 when available).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = @import("sys.zig");

pub const Waker = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
    is_eventfd: bool,

    /// Open a wakeup channel for interrupting a blocked wait from another thread.
    ///
    /// Linux prefers eventfd and falls back to a pipe. Other platforms use a pipe.
    pub fn init() !Waker {
        if (builtin.os.tag != .linux) return initPipe();
        return initEventfd() catch initPipe();
    }

    /// Close the wakeup file descriptors.
    pub fn deinit(self: Waker) void {
        sys.close(self.read_fd);
        if (!self.is_eventfd) {
            sys.close(self.write_fd);
        }
    }

    /// Thread-safe. Extra wakes coalesce (eventfd counter; pipe may fill).
    pub fn wake(self: Waker) !void {
        const value: u64 = 1;
        const buf: []const u8 = if (self.is_eventfd)
            std.mem.asBytes(&value)
        else
            &.{1};
        try writeWake(self.write_fd, buf);
    }

    /// Discard pending wakeup bytes until the read side would block.
    pub fn drain(self: Waker) void {
        var buf: [64]u8 = undefined;
        while (readPending(self.read_fd, &buf)) {}
    }
};

fn readPending(fd: posix.fd_t, buf: []u8) bool {
    _ = posix.read(fd, buf) catch |err| return err == error.Interrupted;
    return true;
}

fn writeWake(fd: posix.fd_t, buf: []const u8) !void {
    while (true) {
        if (try writeOnce(fd, buf)) return;
    }
}

fn writeOnce(fd: posix.fd_t, buf: []const u8) !bool {
    _ = sys.write(fd, buf) catch |err| {
        if (err == error.Interrupted) return false;
        if (err == error.WouldBlock) return true;
        return err;
    };
    return true;
}

fn initEventfd() !Waker {
    const linux = std.os.linux;
    const fd = try sys.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    return .{
        .read_fd = fd,
        .write_fd = fd,
        .is_eventfd = true,
    };
}

fn initPipe() !Waker {
    const fds = try sys.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    return .{
        .read_fd = fds[0],
        .write_fd = fds[1],
        .is_eventfd = false,
    };
}

test "waker init and deinit" {
    const testing = std.testing;

    const waker = try Waker.init();
    defer waker.deinit();

    try testing.expect(waker.read_fd >= 0);
    try testing.expect(waker.write_fd >= 0);
}

test "waker wake and drain" {
    const waker = try Waker.init();
    defer waker.deinit();

    try waker.wake();
    waker.drain();
}

test "waker multiple wakes coalesce" {
    const waker = try Waker.init();
    defer waker.deinit();

    try waker.wake();
    try waker.wake();
    try waker.wake();

    waker.drain();
}

test "waker concurrent wake" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const testing = std.testing;
    const waker = try Waker.init();
    defer waker.deinit();

    const Worker = struct {
        fn run(w: Waker, done: *std.atomic.Value(u32)) void {
            for (0..64) |_| {
                w.wake() catch {};
            }
            _ = done.fetchAdd(1, .monotonic);
        }
    };

    var done = std.atomic.Value(u32).init(0);
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ waker, &done });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ waker, &done });
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{ waker, &done });
    t1.join();
    t2.join();
    t3.join();

    try testing.expectEqual(@as(u32, 3), done.load(.monotonic));
    waker.drain();
}
