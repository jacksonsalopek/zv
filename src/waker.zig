//! Cross-thread wakeup mechanism for event loops
//!
//! Interrupt a blocked `backend.wait` from another thread.
//! Linux uses eventfd; other platforms use a pipe (pipe2 when available).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// File-status bit for `O_NONBLOCK`. Prefer the packed-struct field or named
/// constant from `posix.O`; fall back to the well-known POSIX values only when
/// the target headers omit the name.
const o_nonblock: u32 = if (@hasField(posix.O, "NONBLOCK"))
    @as(u32, 1) << @bitOffsetOf(posix.O, "NONBLOCK")
else if (@hasDecl(posix.O, "NONBLOCK"))
    @intCast(posix.O.NONBLOCK)
else if (builtin.os.tag == .linux)
    0o4000 // Linux O_NONBLOCK (bit 11)
else
    0x800; // BSD/Solaris O_NONBLOCK when the name is missing

/// Descriptor flag for `FD_CLOEXEC`. Prefer `posix.FD_CLOEXEC` (or `posix.FD.CLOEXEC`);
/// POSIX requires the value 1 when neither form exists.
const fd_cloexec: u32 = blk: {
    if (@hasDecl(posix, "FD_CLOEXEC")) break :blk posix.FD_CLOEXEC;
    if (@hasDecl(posix, "FD")) {
        if (@hasDecl(posix.FD, "CLOEXEC")) break :blk posix.FD.CLOEXEC;
    }
    break :blk 1;
};

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
        posix.close(self.read_fd);
        if (!self.is_eventfd) {
            posix.close(self.write_fd);
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
    _ = posix.write(fd, buf) catch |err| {
        if (err == error.Interrupted) return false;
        if (err == error.WouldBlock) return true;
        return err;
    };
    return true;
}

fn initEventfd() !Waker {
    const linux = std.os.linux;
    const fd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    return .{
        .read_fd = fd,
        .write_fd = fd,
        .is_eventfd = true,
    };
}

fn initPipe() !Waker {
    const fds = try openPipe();
    return .{
        .read_fd = fds[0],
        .write_fd = fds[1],
        .is_eventfd = false,
    };
}

fn openPipe() ![2]posix.fd_t {
    if (@hasDecl(posix, "pipe2")) {
        return posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    }
    return openPipeFcntl();
}

fn openPipeFcntl() ![2]posix.fd_t {
    const fds = try posix.pipe();
    errdefer {
        posix.close(fds[0]);
        posix.close(fds[1]);
    }
    try setNonBlocking(fds[0]);
    try setNonBlocking(fds[1]);
    try setCloExec(fds[0]);
    try setCloExec(fds[1]);
    return fds;
}

fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | o_nonblock);
}

fn setCloExec(fd: posix.fd_t) !void {
    _ = try posix.fcntl(fd, posix.F.SETFD, fd_cloexec);
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
