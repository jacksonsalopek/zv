//! Epoll backend for Linux
//!
//! High-performance event notification for Linux systems.

const std = @import("std");
const Backend = @import("../backend.zig");
const linux = std.os.linux;

const Epoll = @This();

allocator: std.mem.Allocator,
epoll_fd: std.posix.fd_t,

pub fn init(allocator: std.mem.Allocator) !Backend {
    const epoll_fd = try std.posix.epoll_create1(linux.EPOLL.CLOEXEC);
    errdefer std.posix.close(epoll_fd);

    const self = try allocator.create(Epoll);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .epoll_fd = epoll_fd,
    };

    return Backend{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable = Backend.VTable{
    .deinit = deinitImpl,
    .add = addImpl,
    .modify = modifyImpl,
    .remove = removeImpl,
    .wait = waitImpl,
};

fn deinitImpl(ptr: *anyopaque) void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    std.posix.close(self.epoll_fd);
    self.allocator.destroy(self);
}

fn addImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest) !void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    const events = interestToEpollEvents(interest);

    var event = linux.epoll_event{
        .events = events,
        .data = linux.epoll_data{ .fd = fd },
    };

    try std.posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &event);
}

fn modifyImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest) !void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    const events = interestToEpollEvents(interest);

    var event = linux.epoll_event{
        .events = events,
        .data = linux.epoll_data{ .fd = fd },
    };

    try std.posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &event);
}

fn removeImpl(ptr: *anyopaque, fd: std.posix.fd_t) !void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    try std.posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
}

fn waitImpl(ptr: *anyopaque, events: []Backend.Event, timeout_ns: ?u64) !usize {
    const self: *Epoll = @ptrCast(@alignCast(ptr));

    const timeout_ms: i32 = if (timeout_ns) |ns| blk: {
        const ms = ns / std.time.ns_per_ms;
        break :blk @intCast(@min(ms, std.math.maxInt(i32)));
    } else -1;

    var epoll_events: [64]linux.epoll_event = undefined;
    const max_events = @min(events.len, epoll_events.len);

    const n = std.posix.epoll_wait(self.epoll_fd, epoll_events[0..max_events], timeout_ms);

    for (epoll_events[0..n], 0..) |epoll_event, i| {
        events[i] = .{
            .fd = epoll_event.data.fd,
            .events = epollEventsToMask(epoll_event.events),
        };
    }

    return n;
}

fn interestToEpollEvents(interest: Backend.Interest) u32 {
    var events: u32 = 0;
    if (interest.read) events |= linux.EPOLL.IN;
    if (interest.write) events |= linux.EPOLL.OUT;
    events |= linux.EPOLL.ERR | linux.EPOLL.HUP;
    return events;
}

fn epollEventsToMask(events: u32) Backend.EventMask {
    return .{
        .read = (events & linux.EPOLL.IN) != 0,
        .write = (events & linux.EPOLL.OUT) != 0,
        .error_ = (events & linux.EPOLL.ERR) != 0,
        .hangup = (events & linux.EPOLL.HUP) != 0,
    };
}

test "epoll init" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const backend = try init(testing.allocator);
    defer backend.deinit();
}
