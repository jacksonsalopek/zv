//! Kqueue backend for BSD and macOS
//!
//! High-performance event notification for BSD-based systems.

const std = @import("std");
const Backend = @import("../backend.zig");
const builtin = @import("builtin");

const Kqueue = @This();

allocator: std.mem.Allocator,
kq: std.posix.fd_t,

pub fn init(allocator: std.mem.Allocator) !Backend {
    const kq = try std.posix.kqueue();
    errdefer std.posix.close(kq);

    const self = try allocator.create(Kqueue);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .kq = kq,
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
    const self: *Kqueue = @ptrCast(@alignCast(ptr));
    std.posix.close(self.kq);
    self.allocator.destroy(self);
}

fn addImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest) !void {
    const self: *Kqueue = @ptrCast(@alignCast(ptr));

    var changes: [2]std.posix.system.Kevent = undefined;
    var n_changes: usize = 0;

    if (interest.read) {
        changes[n_changes] = .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT_READ,
            .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        n_changes += 1;
    }

    if (interest.write) {
        changes[n_changes] = .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT_WRITE,
            .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        n_changes += 1;
    }

    if (n_changes > 0) {
        _ = try std.posix.kevent(self.kq, changes[0..n_changes], &.{}, null);
    }
}

fn modifyImpl(ptr: *anyopaque, fd: std.posix.fd_t, interest: Backend.Interest) !void {
    return addImpl(ptr, fd, interest);
}

fn removeImpl(ptr: *anyopaque, fd: std.posix.fd_t) !void {
    const self: *Kqueue = @ptrCast(@alignCast(ptr));

    const changes = [_]std.posix.system.Kevent{
        .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT_READ,
            .flags = std.posix.system.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        },
        .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT_WRITE,
            .flags = std.posix.system.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        },
    };

    _ = std.posix.kevent(self.kq, &changes, &.{}, null) catch {};
}

fn waitImpl(ptr: *anyopaque, events: []Backend.Event, timeout_ns: ?u64) !usize {
    const self: *Kqueue = @ptrCast(@alignCast(ptr));

    const timeout: ?std.posix.timespec = if (timeout_ns) |ns| .{
        .tv_sec = @intCast(ns / std.time.ns_per_s),
        .tv_nsec = @intCast(ns % std.time.ns_per_s),
    } else null;

    var kevents: [64]std.posix.system.Kevent = undefined;
    const max_events = @min(events.len, kevents.len);

    const n = try std.posix.kevent(
        self.kq,
        &.{},
        kevents[0..max_events],
        if (timeout) |*t| t else null,
    );

    var event_idx: usize = 0;
    for (kevents[0..n]) |kevent| {
        if (event_idx >= events.len) break;

        const fd: std.posix.fd_t = @intCast(kevent.ident);
        const mask = keventToMask(kevent);

        if (!mask.isEmpty()) {
            events[event_idx] = .{
                .fd = fd,
                .events = mask,
            };
            event_idx += 1;
        }
    }

    return event_idx;
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
    const backend = try init(testing.allocator);
    defer backend.deinit();
}

fn isKqueueSupported() bool {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => true,
        .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}
