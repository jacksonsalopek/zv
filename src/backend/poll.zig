//! Poll backend (POSIX fallback)
//!
//! Portable event notification using poll(2).

const std = @import("std");
const Backend = @import("../backend.zig");

const Poll = @This();

allocator: std.mem.Allocator,
fds: std.ArrayList(std.posix.pollfd),
fd_map: std.AutoHashMap(std.posix.fd_t, usize),
user_data_map: std.AutoHashMap(std.posix.fd_t, ?*anyopaque),

pub fn init(allocator: std.mem.Allocator) !Backend {
    const self = try allocator.create(Poll);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .fds = std.ArrayList(std.posix.pollfd){},
        .fd_map = std.AutoHashMap(std.posix.fd_t, usize).init(allocator),
        .user_data_map = std.AutoHashMap(std.posix.fd_t, ?*anyopaque).init(allocator),
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
    const self: *Poll = @ptrCast(@alignCast(ptr));
    self.fds.deinit(self.allocator);
    self.fd_map.deinit();
    self.user_data_map.deinit();
    self.allocator.destroy(self);
}

fn addImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) !void {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    if (self.fd_map.contains(fd)) return error.AlreadyExists;

    const events = interestToPollEvents(interest);
    const idx = self.fds.items.len;

    try self.fds.append(self.allocator, .{
        .fd = fd,
        .events = events,
        .revents = 0,
    });

    try self.fd_map.put(fd, idx);
    try self.user_data_map.put(fd, user_data);
}

fn modifyImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest) !void {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    const idx = self.fd_map.get(fd) orelse return error.NotFound;
    const events = interestToPollEvents(interest);

    self.fds.items[idx].events = events;
}

fn removeImpl(ptr: *anyopaque, fd: std.posix.fd_t) !void {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    const idx = self.fd_map.get(fd) orelse return error.NotFound;

    _ = self.fds.swapRemove(idx);
    _ = self.fd_map.remove(fd);
    _ = self.user_data_map.remove(fd);

    if (idx < self.fds.items.len) {
        const moved_fd = self.fds.items[idx].fd;
        try self.fd_map.put(moved_fd, idx);
    }
}

fn waitImpl(ptr: *anyopaque, events: []Backend.Event, timeout_ns: ?u64) !usize {
    const self: *Poll = @ptrCast(@alignCast(ptr));

    if (self.fds.items.len == 0) return 0;

    const timeout_ms: i32 = if (timeout_ns) |ns| blk: {
        const ms: i64 = @intCast(ns / std.time.ns_per_ms);
        break :blk @intCast(@min(ms, std.math.maxInt(i32)));
    } else -1;

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
    const backend = try init(testing.allocator);
    defer backend.deinit();
}
