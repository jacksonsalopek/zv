//! Poll backend (POSIX fallback)
//!
//! Portable event notification using poll(2).

const std = @import("std");
const Backend = @import("../backend.zig");

const Poll = @This();

allocator: std.mem.Allocator,
fds: std.ArrayList(std.posix.pollfd),
fd_map: std.AutoHashMapUnmanaged(std.posix.fd_t, usize),
user_data_map: std.AutoHashMapUnmanaged(std.posix.fd_t, ?*anyopaque),

pub fn init(allocator: std.mem.Allocator, capacity: usize) !Backend {
    const self = try allocator.create(Poll);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .fds = .empty,
        .fd_map = .empty,
        .user_data_map = .empty,
    };
    errdefer {
        self.fds.deinit(allocator);
        self.fd_map.deinit(allocator);
        self.user_data_map.deinit(allocator);
    }
    try self.fds.ensureTotalCapacity(allocator, capacity);
    try self.fd_map.ensureTotalCapacity(allocator, @intCast(capacity));
    try self.user_data_map.ensureTotalCapacity(allocator, @intCast(capacity));

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
    .reify = reifyImpl,
    .wait = waitImpl,
};

fn reifyImpl(_: *anyopaque) Backend.Error!void {}

fn deinitImpl(ptr: *anyopaque) void {
    const self: *Poll = @ptrCast(@alignCast(ptr));
    self.fds.deinit(self.allocator);
    self.fd_map.deinit(self.allocator);
    self.user_data_map.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn addImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) Backend.Error!void {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    if (self.fd_map.contains(fd)) return error.AlreadyExists;

    const events = interestToPollEvents(interest);
    const idx = self.fds.items.len;

    try self.fds.append(self.allocator, .{
        .fd = fd,
        .events = events,
        .revents = 0,
    });
    errdefer _ = self.fds.pop();

    try self.fd_map.put(self.allocator, fd, idx);
    errdefer _ = self.fd_map.remove(fd);

    try self.user_data_map.put(self.allocator, fd, user_data);
}

fn modifyImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) Backend.Error!void {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    const idx = self.fd_map.get(fd) orelse return error.NotFound;
    const events = interestToPollEvents(interest);

    self.fds.items[idx].events = events;
    try self.user_data_map.put(self.allocator, fd, user_data);
}

fn removeImpl(ptr: *anyopaque, fd: std.posix.fd_t) Backend.Error!void {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    const idx = self.fd_map.get(fd) orelse return error.NotFound;

    _ = self.fds.swapRemove(idx);
    _ = self.fd_map.remove(fd);
    _ = self.user_data_map.remove(fd);

    if (idx < self.fds.items.len) {
        const moved_fd = self.fds.items[idx].fd;
        try self.fd_map.put(self.allocator, moved_fd, idx);
    }
}

fn waitImpl(ptr: *anyopaque, events: []Backend.Event, timeout_ns: ?u64) Backend.Error!usize {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    if (self.fds.items.len == 0) return 0;

    const timeout_ms = Backend.timeoutMillis(timeout_ns);

    _ = try std.posix.poll(self.fds.items, timeout_ms);

    var event_idx: usize = 0;
    for (self.fds.items) |pollfd| {
        if (event_idx >= events.len) break;
        if (pollfd.revents == 0) continue;

        const mask = pollEventsToMask(pollfd.revents);
        if (!mask.isEmpty()) {
            events[event_idx] = .{
                .fd = pollfd.fd,
                .events = mask,
                .user_data = self.user_data_map.get(pollfd.fd) orelse null,
            };
            event_idx += 1;
        }
    }

    return event_idx;
}

fn interestToPollEvents(interest: Backend.Interest) i16 {
    var events: i16 = 0;
    if (interest.read) events |= std.posix.POLL.IN;
    if (interest.write) events |= std.posix.POLL.OUT;
    return events;
}

fn pollEventsToMask(revents: i16) Backend.EventMask {
    return .{
        .read = (revents & std.posix.POLL.IN) != 0,
        .write = (revents & std.posix.POLL.OUT) != 0,
        .error_ = (revents & std.posix.POLL.ERR) != 0,
        .hangup = (revents & std.posix.POLL.HUP) != 0,
    };
}

test "poll init" {
    const testing = std.testing;
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();
}
