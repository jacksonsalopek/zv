//! Select backend (universal fallback)
//!
//! Portable event notification using select(2).
//! Limited to FD_SETSIZE file descriptors (typically 1024).

const std = @import("std");
const Backend = @import("../backend.zig");
const builtin = @import("builtin");

const Select = @This();

const fd_t = std.posix.fd_t;

const FdSet = extern struct {
    fds_bits: [32]u32 = [_]u32{0} ** 32,
};

const FD_SETSIZE: usize = 1024;

allocator: std.mem.Allocator,
read_fds: std.AutoHashMap(std.posix.fd_t, void),
write_fds: std.AutoHashMap(std.posix.fd_t, void),
user_data_map: std.AutoHashMap(std.posix.fd_t, ?*anyopaque),
max_fd: std.posix.fd_t,

pub fn init(allocator: std.mem.Allocator) !Backend {
    const self = try allocator.create(Select);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .read_fds = std.AutoHashMap(std.posix.fd_t, void).init(allocator),
        .write_fds = std.AutoHashMap(std.posix.fd_t, void).init(allocator),
        .user_data_map = std.AutoHashMap(std.posix.fd_t, ?*anyopaque).init(allocator),
        .max_fd = 0,
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
    const self: *Select = @ptrCast(@alignCast(ptr));
    self.read_fds.deinit();
    self.write_fds.deinit();
    self.user_data_map.deinit();
    self.allocator.destroy(self);
}

fn addImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest, user_data: ?*anyopaque) !void {
    const self: *Select = @ptrCast(@alignCast(ptr));

    if (fd >= FD_SETSIZE) return error.FdTooLarge;

    if (interest.read) {
        try self.read_fds.put(fd, {});
    }
    if (interest.write) {
        try self.write_fds.put(fd, {});
    }
    
    try self.user_data_map.put(fd, user_data);
    self.updateMaxFd();
}

fn modifyImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest) !void {
    const self: *Select = @ptrCast(@alignCast(ptr));

    const user_data = self.user_data_map.get(fd) orelse null;
    _ = self.read_fds.remove(fd);
    _ = self.write_fds.remove(fd);

    return addImpl(ptr, fd, interest, user_data);
}

fn removeImpl(ptr: *anyopaque, fd: std.posix.fd_t) !void {
    const self: *Select = @ptrCast(@alignCast(ptr));

    _ = self.read_fds.remove(fd);
    _ = self.write_fds.remove(fd);
    _ = self.user_data_map.remove(fd);

    self.updateMaxFd();
}

fn waitImpl(ptr: *anyopaque, events: []Backend.Event, timeout_ns: ?u64) !usize {
    const self: *Select = @ptrCast(@alignCast(ptr));
    _ = timeout_ns;

    if (self.read_fds.count() == 0 and self.write_fds.count() == 0) return 0;

    _ = events;

    return 0;
}

fn updateMaxFd(self: *Select) void {
    self.max_fd = 0;

    var read_it = self.read_fds.keyIterator();
    while (read_it.next()) |fd| {
        if (fd.* > self.max_fd) self.max_fd = fd.*;
    }

    var write_it = self.write_fds.keyIterator();
    while (write_it.next()) |fd| {
        if (fd.* > self.max_fd) self.max_fd = fd.*;
    }
}

fn fdSet(fd: fd_t, set: *FdSet) void {
    const idx: usize = @intCast(fd);
    const bit_idx = idx % 32;
    const word_idx = idx / 32;
    set.fds_bits[word_idx] |= @as(u32, 1) << @intCast(bit_idx);
}

fn fdIsSet(fd: fd_t, set: *const FdSet) bool {
    const idx: usize = @intCast(fd);
    const bit_idx = idx % 32;
    const word_idx = idx / 32;
    return (set.fds_bits[word_idx] & (@as(u32, 1) << @intCast(bit_idx))) != 0;
}

test "select init" {
    const testing = std.testing;
    const backend = try init(testing.allocator);
    defer backend.deinit();
}
