//! Kqueue backend for BSD and macOS
//!
//! `add`/`modify`/`remove` queue interest in userspace. `wait` emits a
//! changelist in the same `kevent` as the harvest (libev-style). `reify`
//! is a no-op so init can share the Loop path with epoll.

const std = @import("std");
const Backend = @import("../backend.zig");
const builtin = @import("builtin");
const sys = @import("../sys.zig");
const posix = std.posix;

const Kqueue = @This();

const Slot = struct {
    dirty: bool = false,
    wanted: Backend.Interest = .{},
    kernel: Backend.Interest = .{},
    user_data: ?*anyopaque = null,
};

allocator: std.mem.Allocator,
kq: std.posix.fd_t,
slots: std.AutoHashMapUnmanaged(std.posix.fd_t, Slot),
dirty: std.ArrayList(std.posix.fd_t),
changes: std.ArrayList(std.posix.system.Kevent),

pub fn init(allocator: std.mem.Allocator, capacity: usize) !Backend {
    const kq = try open();
    errdefer sys.close(kq);

    const self = try allocator.create(Kqueue);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .kq = kq,
        .slots = .empty,
        .dirty = .empty,
        .changes = .empty,
    };
    errdefer {
        self.changes.deinit(allocator);
        self.dirty.deinit(allocator);
        self.slots.deinit(allocator);
    }
    try self.slots.ensureTotalCapacity(allocator, @intCast(capacity));
    try self.dirty.ensureTotalCapacity(allocator, capacity);
    try self.changes.ensureTotalCapacity(allocator, capacity * 2);

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
    const self: *Kqueue = @ptrCast(@alignCast(ptr));
    self.changes.deinit(self.allocator);
    self.dirty.deinit(self.allocator);
    self.slots.deinit(self.allocator);
    sys.close(self.kq);
    self.allocator.destroy(self);
}

fn reifyImpl(_: *anyopaque) Backend.Error!void {}

fn addImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) Backend.Error!void {
    const self: *Kqueue = @ptrCast(@alignCast(ptr));
    const gop = try self.slots.getOrPut(self.allocator, fd);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .wanted = interest,
            .user_data = user_data,
        };
        errdefer _ = self.slots.remove(fd);
        try self.enqueue(fd, gop.value_ptr);
        return;
    }
    try addExisting(self, fd, gop.value_ptr, interest, user_data);
}

fn addExisting(
    self: *Kqueue,
    fd: std.posix.fd_t,
    slot: *Slot,
    interest: Backend.Interest,
    user_data: ?*anyopaque,
) !void {
    if (isWatched(slot.wanted)) return error.AlreadyExists;
    slot.wanted = interest;
    slot.user_data = user_data;
    try self.enqueue(fd, slot);
}

fn modifyImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) Backend.Error!void {
    const self: *Kqueue = @ptrCast(@alignCast(ptr));
    const slot = self.slots.getPtr(fd) orelse return error.NotFound;
    if (!isWatched(slot.wanted)) return error.NotFound;
    slot.wanted = interest;
    slot.user_data = user_data;
    try self.enqueue(fd, slot);
}

fn removeImpl(ptr: *anyopaque, fd: std.posix.fd_t) Backend.Error!void {
    const self: *Kqueue = @ptrCast(@alignCast(ptr));
    const slot = self.slots.getPtr(fd) orelse return error.NotFound;
    slot.wanted = .{};
    try self.enqueue(fd, slot);
}

fn enqueue(self: *Kqueue, fd: std.posix.fd_t, slot: *Slot) !void {
    if (slot.dirty) return;
    try self.dirty.append(self.allocator, fd);
    slot.dirty = true;
}

fn isWatched(interest: Backend.Interest) bool {
    return interest.read or interest.write;
}

fn waitImpl(ptr: *anyopaque, events: []Backend.Event, timeout_ns: ?u64) Backend.Error!usize {
    const self: *Kqueue = @ptrCast(@alignCast(ptr));
    try self.buildChanges();

    const timeout = timeoutTimespec(timeout_ns);
    var kevents: [64]std.posix.system.Kevent = undefined;
    const max_events = @min(events.len, kevents.len);

    const n = try waitEvents(
        self.kq,
        self.changes.items,
        kevents[0..max_events],
        if (timeout) |*t| t else null,
    );

    self.commitDirty();
    return harvest(kevents[0..n], events);
}

fn buildChanges(self: *Kqueue) !void {
    self.changes.clearRetainingCapacity();
    for (self.dirty.items) |fd| {
        try self.appendFdChanges(fd);
    }
}

fn appendFdChanges(self: *Kqueue, fd: std.posix.fd_t) !void {
    const slot = self.slots.getPtr(fd) orelse return;
    if (!slot.dirty) return;
    if (!isWatched(slot.wanted) and !isWatched(slot.kernel)) return;
    try self.appendFilter(fd, slot, true);
    try self.appendFilter(fd, slot, false);
}

fn appendFilter(self: *Kqueue, fd: std.posix.fd_t, slot: *Slot, read: bool) !void {
    const wanted = if (read) slot.wanted.read else slot.wanted.write;
    const kernel = if (read) slot.kernel.read else slot.kernel.write;
    if (!wanted and !kernel) return;
    if (wanted and kernel) {
        try self.appendChange(fd, read, true, slot.user_data);
        return;
    }
    try self.appendChange(fd, read, wanted, slot.user_data);
}

fn appendChange(self: *Kqueue, fd: std.posix.fd_t, read: bool, add: bool, user_data: ?*anyopaque) !void {
    const filter = if (read) std.posix.system.EVFILT_READ else std.posix.system.EVFILT_WRITE;
    const flags: u16 = if (add)
        std.posix.system.EV_ADD | std.posix.system.EV_ENABLE
    else
        std.posix.system.EV_DELETE;
    try self.changes.append(self.allocator, .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = if (user_data) |data| @intFromPtr(data) else 0,
    });
}

fn commitDirty(self: *Kqueue) void {
    for (self.dirty.items) |fd| {
        commitSlot(&self.slots, fd);
    }
    self.dirty.clearRetainingCapacity();
}

fn timeoutTimespec(timeout_ns: ?u64) ?std.posix.timespec {
    const ns = timeout_ns orelse return null;
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

fn commitSlot(slots: *std.AutoHashMapUnmanaged(std.posix.fd_t, Slot), fd: std.posix.fd_t) void {
    const slot = slots.getPtr(fd) orelse return;
    slot.dirty = false;
    slot.kernel = slot.wanted;
    if (isWatched(slot.wanted)) return;
    _ = slots.remove(fd);
}

fn harvest(kevents: []const std.posix.system.Kevent, events: []Backend.Event) usize {
    var event_idx: usize = 0;
    for (kevents) |kevent| {
        if (event_idx >= events.len) break;
        event_idx = harvestOne(kevent, events, event_idx);
    }
    return event_idx;
}

fn harvestOne(kevent: std.posix.system.Kevent, events: []Backend.Event, event_idx: usize) usize {
    const mask = keventToMask(kevent);
    if (mask.isEmpty()) return event_idx;
    events[event_idx] = .{
        .fd = @intCast(kevent.ident),
        .events = mask,
        .user_data = if (kevent.udata != 0) @ptrFromInt(kevent.udata) else null,
    };
    return event_idx + 1;
}

fn keventToMask(kevent: std.posix.system.Kevent) Backend.EventMask {
    const is_error = (kevent.flags & std.posix.system.EV_ERROR) != 0;
    const is_eof = (kevent.flags & std.posix.system.EV_EOF) != 0;

    return .{
        .read = kevent.filter == std.posix.system.EVFILT_READ,
        .write = kevent.filter == std.posix.system.EVFILT_WRITE,
        .error_ = is_error,
        .hangup = is_eof,
    };
}

test "kqueue init" {
    if (!isKqueueSupported()) return error.SkipZigTest;

    const testing = std.testing;
    const backend = try init(testing.allocator, 8);
    defer backend.deinit();
}

fn isKqueueSupported() bool {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => true,
        .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

fn open() !posix.fd_t {
    const rc = posix.system.kqueue();
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn waitEvents(
    kq: posix.fd_t,
    changelist: []const posix.system.Kevent,
    eventlist: []posix.system.Kevent,
    timeout: ?*const posix.timespec,
) !usize {
    while (true) {
        const count = try waitOnce(kq, changelist, eventlist, timeout);
        if (count) |n| return n;
    }
}

fn waitOnce(
    kq: posix.fd_t,
    changelist: []const posix.system.Kevent,
    eventlist: []posix.system.Kevent,
    timeout: ?*const posix.timespec,
) !?usize {
    const rc = posix.system.kevent(
        kq,
        changelist.ptr,
        @intCast(changelist.len),
        eventlist.ptr,
        @intCast(eventlist.len),
        timeout,
    );
    return switch (posix.errno(rc)) {
        .SUCCESS => @as(usize, @intCast(rc)),
        .INTR => null,
        .ACCES => error.AccessDenied,
        .NOENT => error.EventNotFound,
        .NOMEM => error.SystemResources,
        .SRCH => error.ProcessNotFound,
        else => |err| posix.unexpectedErrno(err),
    };
}
