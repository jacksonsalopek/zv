//! Backend abstraction for different event notification mechanisms
//!
//! Supports multiple backends:
//! - epoll (Linux)
//! - kqueue (BSD/macOS)
//! - poll (POSIX fallback)
//! - select (universal fallback)

const std = @import("std");
const builtin = @import("builtin");
const Backend = @This();

pub const Kind = enum {
    epoll,
    kqueue,
    poll,
    select,
};

pub const Event = struct {
    fd: std.posix.fd_t,
    events: EventMask,
};

pub const EventMask = packed struct {
    read: bool = false,
    write: bool = false,
    error_: bool = false,
    hangup: bool = false,

    pub fn isEmpty(self: EventMask) bool {
        return !self.read and !self.write and !self.error_ and !self.hangup;
    }
};

pub const Interest = packed struct {
    read: bool = false,
    write: bool = false,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    add: *const fn (ptr: *anyopaque, fd: std.posix.fd_t, interest: Interest) anyerror!void,
    modify: *const fn (ptr: *anyopaque, fd: std.posix.fd_t, interest: Interest) anyerror!void,
    remove: *const fn (ptr: *anyopaque, fd: std.posix.fd_t) anyerror!void,
    wait: *const fn (ptr: *anyopaque, events: []Event, timeout_ns: ?u64) anyerror!usize,
};

/// Determine the best available backend for the current platform
pub fn selectBest() Kind {
    return switch (builtin.os.tag) {
        .linux => .epoll,
        .macos, .ios, .tvos, .watchos, .visionos => .kqueue,
        .freebsd, .netbsd, .openbsd, .dragonfly => .kqueue,
        else => .poll,
    };
}

/// Initialize a backend of the specified kind
pub fn init(allocator: std.mem.Allocator, kind: Kind) !Backend {
    return switch (kind) {
        .epoll => if (builtin.os.tag == .linux) blk: {
            const epoll = @import("backend/epoll.zig");
            break :blk try epoll.init(allocator);
        } else error.UnsupportedBackend,
        .kqueue => if (comptime isKqueueSupported()) blk: {
            const kqueue = @import("backend/kqueue.zig");
            break :blk try kqueue.init(allocator);
        } else error.UnsupportedBackend,
        .poll => blk: {
            const poll = @import("backend/poll.zig");
            break :blk try poll.init(allocator);
        },
        .select => blk: {
            const select = @import("backend/select.zig");
            break :blk try select.init(allocator);
        },
    };
}

fn isKqueueSupported() bool {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => true,
        .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

pub fn deinit(self: Backend) void {
    self.vtable.deinit(self.ptr);
}

/// Register a file descriptor for monitoring
pub fn add(self: Backend, fd: std.posix.fd_t, interest: Interest) !void {
    return self.vtable.add(self.ptr, fd, interest);
}

/// Modify the events to monitor for a file descriptor
pub fn modify(self: Backend, fd: std.posix.fd_t, interest: Interest) !void {
    return self.vtable.modify(self.ptr, fd, interest);
}

/// Stop monitoring a file descriptor
pub fn remove(self: Backend, fd: std.posix.fd_t) !void {
    return self.vtable.remove(self.ptr, fd);
}

/// Wait for events, blocking up to timeout_ns nanoseconds
/// Returns number of events written to the events slice
/// timeout_ns = null means wait indefinitely
pub fn wait(self: Backend, events: []Event, timeout_ns: ?u64) !usize {
    return self.vtable.wait(self.ptr, events, timeout_ns);
}
