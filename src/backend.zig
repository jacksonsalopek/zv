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
    user_data: ?*anyopaque = null,
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

/// Errors from `init`, `add`, `modify`, `remove`, `reify`, and `wait`.
pub const Error = std.mem.Allocator.Error || std.posix.UnexpectedError || std.posix.PollError || error{
    UnsupportedBackend,
    AlreadyExists,
    NotFound,
    FdTooLarge,
    BadFileDescriptor,
    FileDescriptorAlreadyPresentInSet,
    InvalidArgument,
    OperationCausesCircularLoop,
    FileDescriptorNotRegistered,
    SystemResources,
    UserResourceLimitReached,
    FileDescriptorIncompatibleWithEpoll,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    AccessDenied,
    EventNotFound,
    ProcessNotFound,
    Overflow,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    add: *const fn (ptr: *anyopaque, fd: std.posix.fd_t, interest: Interest, user_data: ?*anyopaque) Error!void,
    modify: *const fn (ptr: *anyopaque, fd: std.posix.fd_t, interest: Interest, user_data: ?*anyopaque) Error!void,
    remove: *const fn (ptr: *anyopaque, fd: std.posix.fd_t) Error!void,
    /// Apply queued fd interest (epoll `epoll_ctl`, kqueue no-op — wait uses the changelist).
    reify: *const fn (ptr: *anyopaque) Error!void,
    wait: *const fn (ptr: *anyopaque, events: []Event, timeout_ns: ?u64) Error!usize,
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

/// Initialize a backend of the specified kind.
/// Preallocates room for 32 file descriptors; see `initSized` to override.
pub fn init(allocator: std.mem.Allocator, kind: Kind) !Backend {
    return initSized(allocator, kind, 32);
}

/// Initialize a backend of `kind` with room for `capacity` file descriptors.
pub fn initSized(allocator: std.mem.Allocator, kind: Kind, capacity: usize) !Backend {
    return switch (kind) {
        .epoll => if (builtin.os.tag == .linux) blk: {
            const epoll = @import("backend/epoll.zig");
            break :blk try epoll.init(allocator, capacity);
        } else error.UnsupportedBackend,
        .kqueue => if (comptime isKqueueSupported()) blk: {
            const kqueue = @import("backend/kqueue.zig");
            break :blk try kqueue.init(allocator, capacity);
        } else error.UnsupportedBackend,
        .poll => blk: {
            const poll = @import("backend/poll.zig");
            break :blk try poll.init(allocator, capacity);
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

/// Release resources owned by this backend. The instance is invalid after this call.
pub fn deinit(self: Backend) void {
    self.vtable.deinit(self.ptr);
}

/// Register a file descriptor for monitoring.
/// Epoll/kqueue may defer the kernel update until `reify`/`wait`.
pub fn add(self: Backend, fd: std.posix.fd_t, interest: Interest, user_data: ?*anyopaque) !void {
    return self.vtable.add(self.ptr, fd, interest, user_data);
}

/// Modify the events to monitor for a file descriptor
pub fn modify(self: Backend, fd: std.posix.fd_t, interest: Interest, user_data: ?*anyopaque) !void {
    return self.vtable.modify(self.ptr, fd, interest, user_data);
}

/// Stop monitoring a file descriptor
pub fn remove(self: Backend, fd: std.posix.fd_t) !void {
    return self.vtable.remove(self.ptr, fd);
}

/// Flush deferred kernel fd updates (libev `fd_reify`). No-op for poll/select.
pub fn reify(self: Backend) !void {
    return self.vtable.reify(self.ptr);
}

/// Wait for events, blocking up to timeout_ns nanoseconds
/// Returns number of events written to the events slice
/// timeout_ns = null means wait indefinitely
pub fn wait(self: Backend, events: []Event, timeout_ns: ?u64) !usize {
    return self.vtable.wait(self.ptr, events, timeout_ns);
}

/// Convert a nanosecond timeout to milliseconds, rounding up so a pending
/// timer is not skipped because the remainder was less than 1ms.
pub fn timeoutMillis(timeout_ns: ?u64) i32 {
    const ns = timeout_ns orelse return -1;
    if (ns == 0) return 0;
    const ms = (ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

test "timeoutMillis rounds up sub-millisecond waits" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, -1), timeoutMillis(null));
    try testing.expectEqual(@as(i32, 0), timeoutMillis(0));
    try testing.expectEqual(@as(i32, 1), timeoutMillis(1));
    try testing.expectEqual(@as(i32, 1), timeoutMillis(std.time.ns_per_ms));
    try testing.expectEqual(@as(i32, 2), timeoutMillis(std.time.ns_per_ms + 1));
}
