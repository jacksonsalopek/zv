//! Low-level POSIX helpers for APIs removed from `std.posix` in Zig 0.16.
//!
//! Goes through `std.posix.system` / `std.os.linux` rather than `std.Io`.
//! The event loop is the I/O layer; it must not depend on an injected Io.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

pub const fd_t = posix.fd_t;
pub const UnexpectedError = posix.UnexpectedError;

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || UnexpectedError;

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
    BrokenPipe,
    SystemResources,
    WouldBlock,
    NotOpenForWriting,
    Interrupted,
    ConnectionResetByPeer,
} || UnexpectedError;

pub const FcntlError = error{
    WouldBlock,
    BadFileDescriptor,
    InvalidArgument,
    SystemResources,
} || UnexpectedError;

pub const EventfdError = error{
    InvalidArgument,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
} || UnexpectedError;

pub const EpollCreateError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
} || UnexpectedError;


/// Blocking mutex that does not require a `std.Io` instance.
pub const Mutex = if (builtin.os.tag == .linux) struct {
    state: std.atomic.Value(u32) = .init(unlocked),

    const unlocked: u32 = 0;
    const locked: u32 = 1;
    const contended: u32 = 2;

    pub fn lock(self: *@This()) void {
        if (self.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) == null) return;
        self.lockContended();
    }

    fn lockContended(self: *@This()) void {
        while (self.state.swap(contended, .acquire) != unlocked) {
            _ = linux.futex_4arg(
                &self.state.raw,
                .{ .cmd = .WAIT, .private = true },
                contended,
                null,
            );
        }
    }

    pub fn unlock(self: *@This()) void {
        if (self.state.swap(unlocked, .release) != contended) return;
        _ = linux.futex_3arg(
            &self.state.raw,
            .{ .cmd = .WAKE, .private = true },
            1,
        );
    }
} else struct {
    impl: posix.system.pthread_mutex_t = posix.system.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *@This()) void {
        _ = posix.system.pthread_mutex_lock(&self.impl);
    }

    pub fn unlock(self: *@This()) void {
        _ = posix.system.pthread_mutex_unlock(&self.impl);
    }
};

pub fn close(fd: fd_t) void {
    switch (posix.errno(posix.system.close(fd))) {
        .SUCCESS, .INTR => {},
        else => {},
    }
}

pub fn pipe() PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    return switch (posix.errno(posix.system.pipe(&fds))) {
        .SUCCESS => fds,
        .NFILE => error.SystemFdQuotaExceeded,
        .MFILE => error.ProcessFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn pipe2(flags: posix.O) PipeError![2]fd_t {
    if (!@hasDecl(posix.system, "pipe2")) return openPipeThenFlags(flags);
    var fds: [2]fd_t = undefined;
    return switch (posix.errno(posix.system.pipe2(&fds, flags))) {
        .SUCCESS => fds,
        .INVAL => unreachable,
        .NFILE => error.SystemFdQuotaExceeded,
        .MFILE => error.ProcessFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn openPipeThenFlags(flags: posix.O) PipeError![2]fd_t {
    const fds = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    setPipeFlags(fds[0], flags) catch return error.Unexpected;
    setPipeFlags(fds[1], flags) catch return error.Unexpected;
    return fds;
}

fn setPipeFlags(fd: fd_t, flags: posix.O) FcntlError!void {
    if (flags.CLOEXEC) try setCloexec(fd);
    if (flags.NONBLOCK) try setNonblock(fd);
}

pub fn setNonblock(fd: fd_t) FcntlError!void {
    const flags = try fcntlGet(fd, posix.F.GETFL);
    _ = try fcntlSet(fd, posix.F.SETFL, flags | oNonblock());
}

pub fn setCloexec(fd: fd_t) FcntlError!void {
    _ = try fcntlSet(fd, posix.F.SETFD, posix.FD_CLOEXEC);
}

fn oNonblock() usize {
    if (@hasField(posix.O, "NONBLOCK")) {
        return @as(u32, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    }
    if (builtin.os.tag == .linux) return 0o4000;
    return 0x800;
}

pub fn fcntlGet(fd: fd_t, cmd: i32) FcntlError!usize {
    return mapFcntl(posix.system.fcntl(fd, cmd, @as(usize, 0)));
}

pub fn fcntlSet(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    return mapFcntl(posix.system.fcntl(fd, cmd, arg));
}

fn mapFcntl(rc: usize) FcntlError!usize {
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFileDescriptor,
        .INVAL => error.InvalidArgument,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    const rc = posix.system.write(fd, bytes.ptr, bytes.len);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .BADF => error.NotOpenForWriting,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .PERM => error.AccessDenied,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionResetByPeer,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn eventfd(initval: u32, flags: u32) EventfdError!fd_t {
    const rc = linux.eventfd(initval, flags);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => error.InvalidArgument,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV, .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn epollCreate1(flags: u32) EpollCreateError!fd_t {
    const rc = linux.epoll_create1(flags);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => unreachable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub fn epollWait(epfd: fd_t, events: []linux.epoll_event, timeout: i32) usize {
    while (true) {
        const rc = linux.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return 0,
        }
    }
}

/// Monotonic clock in nanoseconds. Returns 0 if the clock is unavailable.
pub fn monotonicNs() u64 {
    var ts = timespecZero();
    if (clockGettimeMonotonic(&ts) != 0) return 0;
    return timespecToNs(ts);
}

pub fn sleep(ns: u64) void {
    var req = nsToTimespec(ns);
    nanosleep(&req);
}

fn clockGettimeMonotonic(ts: *posix.timespec) usize {
    if (builtin.os.tag == .linux) return linux.clock_gettime(.MONOTONIC, ts);
    if (posix.system.clock_gettime(posix.CLOCK.MONOTONIC, ts) != 0) return 1;
    return 0;
}

fn nanosleep(req: *posix.timespec) void {
    if (builtin.os.tag == .linux) {
        _ = linux.nanosleep(req, null);
        return;
    }
    _ = posix.system.nanosleep(req, null);
}

fn timespecZero() posix.timespec {
    return nsToTimespec(0);
}

fn nsToTimespec(ns: u64) posix.timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

fn timespecToNs(ts: posix.timespec) u64 {
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "pipe write read close" {
    const testing = std.testing;
    const fds = try pipe();
    defer {
        close(fds[0]);
        close(fds[1]);
    }
    try testing.expectEqual(@as(usize, 1), try write(fds[1], "x"));
    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try posix.read(fds[0], &buf));
    try testing.expectEqual(@as(u8, 'x'), buf[0]);
}

test "monotonicNs advances" {
    const testing = std.testing;
    const a = monotonicNs();
    sleep(1 * std.time.ns_per_ms);
    const b = monotonicNs();
    try testing.expect(b >= a);
}

test "mutex lock unlock" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var mutex: Mutex = .{};
    mutex.lock();
    mutex.unlock();
}
