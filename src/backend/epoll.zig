//! Epoll backend for Linux
//!
//! `add`/`modify`/`remove` mark the fd dirty in userspace. `reify` coalesces
//! those into `epoll_ctl` (libev `fd_reify`). Kernel errors such as EBADF
//! and EPERM therefore surface from `reify`/`run`, not from `start`.

const std = @import("std");
const Backend = @import("../backend.zig");
const linux = std.os.linux;

const Epoll = @This();

const Slot = struct {
    dirty: bool = false,
    in_kernel: bool = false,
    wanted: bool = false,
    interest: Backend.Interest = .{},
    user_data: ?*anyopaque = null,
};

allocator: std.mem.Allocator,
epoll_fd: std.posix.fd_t,
slots: std.AutoHashMap(std.posix.fd_t, Slot),
dirty: std.ArrayList(std.posix.fd_t),

pub fn init(allocator: std.mem.Allocator, capacity: usize) !Backend {
    const epoll_fd = try std.posix.epoll_create1(linux.EPOLL.CLOEXEC);
    errdefer std.posix.close(epoll_fd);

    const self = try allocator.create(Epoll);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .epoll_fd = epoll_fd,
        .slots = std.AutoHashMap(std.posix.fd_t, Slot).init(allocator),
        .dirty = std.ArrayList(std.posix.fd_t){},
    };
    errdefer {
        self.dirty.deinit(allocator);
        self.slots.deinit();
    }
    try self.slots.ensureTotalCapacity(@intCast(capacity));
    try self.dirty.ensureTotalCapacity(allocator, capacity);

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

fn deinitImpl(ptr: *anyopaque) void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    self.dirty.deinit(self.allocator);
    self.slots.deinit();
    std.posix.close(self.epoll_fd);
    self.allocator.destroy(self);
}

fn addImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) Backend.Error!void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    const gop = try self.slots.getOrPut(fd);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .wanted = true,
            .interest = interest,
            .user_data = user_data,
        };
        errdefer _ = self.slots.remove(fd);
        try self.enqueue(fd, gop.value_ptr);
        return;
    }
    try addExisting(self, fd, gop.value_ptr, interest, user_data);
}

fn addExisting(
    self: *Epoll,
    fd: std.posix.fd_t,
    slot: *Slot,
    interest: Backend.Interest,
    user_data: ?*anyopaque,
) !void {
    if (slot.wanted) return error.AlreadyExists;
    slot.wanted = true;
    slot.interest = interest;
    slot.user_data = user_data;
    try self.enqueue(fd, slot);
}

fn modifyImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) Backend.Error!void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    const slot = self.slots.getPtr(fd) orelse return error.NotFound;
    if (!slot.wanted) return error.NotFound;
    slot.interest = interest;
    slot.user_data = user_data;
    try self.enqueue(fd, slot);
}

fn removeImpl(ptr: *anyopaque, fd: std.posix.fd_t) Backend.Error!void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    const slot = self.slots.getPtr(fd) orelse return error.NotFound;
    slot.wanted = false;
    try self.enqueue(fd, slot);
}

fn enqueue(self: *Epoll, fd: std.posix.fd_t, slot: *Slot) !void {
    if (slot.dirty) return;
    try self.dirty.append(self.allocator, fd);
    slot.dirty = true;
}

fn reifyImpl(ptr: *anyopaque) Backend.Error!void {
    const self: *Epoll = @ptrCast(@alignCast(ptr));
    try self.flushDirty();
}

fn flushDirty(self: *Epoll) !void {
    var i: usize = 0;
    while (i < self.dirty.items.len) : (i += 1) {
        self.applyFd(self.dirty.items[i]) catch |err| {
            self.keepFrom(i);
            return err;
        };
    }
    self.dirty.clearRetainingCapacity();
}

fn keepFrom(self: *Epoll, from: usize) void {
    if (from == 0) return;
    const new_len = self.dirty.items.len - from;
    std.mem.copyForwards(std.posix.fd_t, self.dirty.items[0..new_len], self.dirty.items[from..]);
    self.dirty.items.len = new_len;
}

fn applyFd(self: *Epoll, fd: std.posix.fd_t) !void {
    const slot = self.slots.getPtr(fd) orelse return;
    if (!slot.dirty) return;
    if (slot.wanted) {
        try self.applyWanted(fd, slot);
        slot.dirty = false;
        return;
    }
    try self.applyUnwanted(fd, slot);
}

fn applyWanted(self: *Epoll, fd: std.posix.fd_t, slot: *Slot) !void {
    const op: u32 = if (slot.in_kernel) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
    try ctl(self.epoll_fd, op, fd, slot);
    slot.in_kernel = true;
}

fn applyUnwanted(self: *Epoll, fd: std.posix.fd_t, slot: *Slot) !void {
    if (slot.in_kernel) {
        try ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, slot);
    }
    _ = self.slots.remove(fd);
}

fn ctl(epfd: std.posix.fd_t, op: u32, fd: std.posix.fd_t, slot: *Slot) !void {
    var event = makeEvent(fd, slot);
    const event_ptr: ?*linux.epoll_event = if (op == linux.EPOLL.CTL_DEL) null else &event;
    const rc = linux.epoll_ctl(epfd, op, fd, event_ptr);
    try mapCtlErrno(std.posix.errno(rc));
}

fn mapCtlErrno(err: std.posix.E) !void {
    switch (err) {
        .SUCCESS => return,
        .BADF => return error.BadFileDescriptor,
        .EXIST => return error.FileDescriptorAlreadyPresentInSet,
        .INVAL => return error.InvalidArgument,
        .LOOP => return error.OperationCausesCircularLoop,
        .NOENT => return error.FileDescriptorNotRegistered,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.UserResourceLimitReached,
        .PERM => return error.FileDescriptorIncompatibleWithEpoll,
        else => return std.posix.unexpectedErrno(err),
    }
}

fn makeEvent(fd: std.posix.fd_t, slot: *const Slot) linux.epoll_event {
    return .{
        .events = interestToEpollEvents(slot.interest),
        .data = if (slot.user_data) |data|
            linux.epoll_data{ .ptr = @intFromPtr(data) }
        else
            linux.epoll_data{ .fd = fd },
    };
}

fn waitImpl(ptr: *anyopaque, events: []Backend.Event, timeout_ns: ?u64) Backend.Error!usize {
    const self: *Epoll = @ptrCast(@alignCast(ptr));

    const timeout_ms = Backend.timeoutMillis(timeout_ns);

    var epoll_events: [64]linux.epoll_event = undefined;
    const max_events = @min(events.len, epoll_events.len);

    const n = std.posix.epoll_wait(self.epoll_fd, epoll_events[0..max_events], timeout_ms);

    for (epoll_events[0..n], 0..) |epoll_event, i| {
        events[i] = .{
            .fd = 0,
            .events = epollEventsToMask(epoll_event.events),
            .user_data = if (epoll_event.data.ptr != 0) @ptrFromInt(epoll_event.data.ptr) else null,
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
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();
}

test "epoll reify arms after nowait" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var marker: u8 = 1;
    try backend.add(fds[0], .{ .read = true }, &marker);
    try backend.reify();
    _ = try std.posix.write(fds[1], "x");

    var events: [4]Backend.Event = undefined;
    const n = try backend.wait(&events, 0);
    try testing.expect(n >= 1);
    try testing.expect(events[0].user_data == @as(?*anyopaque, @ptrCast(&marker)));
    try testing.expect(events[0].events.read);
}

test "epoll start then stop before reify coalesces" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var marker: u8 = 1;
    try backend.add(fds[0], .{ .read = true }, &marker);
    try backend.remove(fds[0]);
    try backend.reify();
    _ = try std.posix.write(fds[1], "x");

    var events: [4]Backend.Event = undefined;
    const n = try backend.wait(&events, 0);
    try testing.expectEqual(@as(usize, 0), n);
}

test "epoll modify before reify applies" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    var marker: u8 = 1;
    try backend.add(fds[1], .{ .read = true }, &marker);
    try backend.modify(fds[1], .{ .write = true }, &marker);
    try backend.reify();

    var events: [4]Backend.Event = undefined;
    const n = try backend.wait(&events, 0);
    try testing.expect(n >= 1);
    try testing.expect(events[0].events.write);
}

test "epoll duplicate add fails at start" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();

    const fds = try std.posix.pipe();
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }

    try backend.add(fds[0], .{ .read = true }, null);
    try testing.expectError(error.AlreadyExists, backend.add(fds[0], .{ .write = true }, null));
}

test "epoll closed fd error surfaces at reify" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const testing = std.testing;
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();

    const fds = try std.posix.pipe();
    std.posix.close(fds[0]);
    std.posix.close(fds[1]);

    try backend.add(fds[0], .{ .read = true }, null);
    try testing.expectError(error.BadFileDescriptor, backend.reify());
}
