//! Main event loop implementation
//!
//! The Loop manages watchers and dispatches events from the backend.

const std = @import("std");
const Backend = @import("backend.zig");
const time = @import("time.zig");
const IoWatcher = @import("watcher/io.zig").Watcher;
const TimerWatcher = @import("watcher/timer.zig").Watcher;

const Loop = @This();

pub const Options = struct {
    backend: ?Backend.Kind = null,
    max_events: usize = 64,
};

pub const RunMode = enum {
    /// Run until no active watchers remain
    until_done,
    /// Run one iteration
    once,
    /// Run one iteration without blocking
    nowait,
};

allocator: std.mem.Allocator,
backend: Backend,
event_buffer: []Backend.Event,
running: bool,
iteration: u64,
now_cache: time.Timestamp,

io_watchers: std.AutoHashMap(std.posix.fd_t, *IoWatcher),
timer_list: std.ArrayList(*TimerWatcher),
pending_count: usize,

pub fn init(allocator: std.mem.Allocator, options: Options) !Loop {
    const backend_kind = options.backend orelse Backend.selectBest();
    const backend = try Backend.init(allocator, backend_kind);
    errdefer backend.deinit();

    const event_buffer = try allocator.alloc(Backend.Event, options.max_events);
    errdefer allocator.free(event_buffer);

    return Loop{
        .allocator = allocator,
        .backend = backend,
        .event_buffer = event_buffer,
        .running = false,
        .iteration = 0,
        .now_cache = time.now(),
        .io_watchers = std.AutoHashMap(std.posix.fd_t, *IoWatcher).init(allocator),
        .timer_list = std.ArrayList(*TimerWatcher){},
        .pending_count = 0,
    };
}

pub fn deinit(self: *Loop) void {
    self.backend.deinit();
    self.allocator.free(self.event_buffer);
    self.io_watchers.deinit();
    self.timer_list.deinit(self.allocator);
}

/// Update cached time
pub fn updateTime(self: *Loop) void {
    self.now_cache = time.now();
}

/// Get current loop time (cached)
pub fn now(self: *Loop) time.Timestamp {
    return self.now_cache;
}

/// Run the event loop
pub fn run(self: *Loop, mode: RunMode) !void {
    if (self.running) return error.AlreadyRunning;

    self.running = true;
    defer self.running = false;

    while (true) {
        const should_continue = try self.iterate(mode);
        if (!should_continue) break;

        switch (mode) {
            .until_done => {},
            .once, .nowait => break,
        }
    }
}

fn iterate(self: *Loop, mode: RunMode) !bool {
    self.iteration += 1;
    self.updateTime();

    try self.processTimers();

    const timeout = self.calculateTimeout(mode);

    const n_events = try self.backend.wait(self.event_buffer, timeout);

    self.updateTime();

    for (self.event_buffer[0..n_events]) |event| {
        if (self.io_watchers.get(event.fd)) |watcher| {
            watcher.invoke(event.events);
        }
    }

    const has_active = self.io_watchers.count() > 0 or self.timer_list.items.len > 0;
    return has_active;
}

fn processTimers(self: *Loop) !void {
    const current_time = self.now();

    var i: usize = 0;
    while (i < self.timer_list.items.len) {
        const timer = self.timer_list.items[i];
        if (timer.isExpired(current_time)) {
            timer.invoke();
            if (!timer.active) {
                _ = self.timer_list.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

fn calculateTimeout(self: *Loop, mode: RunMode) ?u64 {
    if (mode == .nowait) return 0;

    if (self.timer_list.items.len == 0) {
        return if (mode == .once) null else null;
    }

    var min_timeout: ?u64 = null;
    const current_time = self.now();

    for (self.timer_list.items) |timer| {
        if (!timer.active) continue;

        const remaining = if (timer.deadline > current_time)
            timer.deadline - current_time
        else
            0;

        if (min_timeout) |current_min| {
            min_timeout = @min(current_min, remaining);
        } else {
            min_timeout = remaining;
        }
    }

    return min_timeout;
}

pub fn registerIoWatcher(self: *Loop, fd: std.posix.fd_t, watcher: *IoWatcher) !void {
    try self.io_watchers.put(fd, watcher);
}

pub fn unregisterIoWatcher(self: *Loop, fd: std.posix.fd_t) void {
    _ = self.io_watchers.remove(fd);
}

pub fn registerTimer(self: *Loop, watcher: *TimerWatcher) !void {
    try self.timer_list.append(self.allocator, watcher);
}

pub fn unregisterTimer(self: *Loop, watcher: *TimerWatcher) void {
    for (self.timer_list.items, 0..) |w, i| {
        if (w == watcher) {
            _ = self.timer_list.swapRemove(i);
            break;
        }
    }
}

test "loop init and deinit" {
    const testing = std.testing;
    var loop = try init(testing.allocator, .{});
    defer loop.deinit();

    try testing.expect(!loop.running);
    try testing.expectEqual(0, loop.iteration);
}

test "loop time management" {
    const testing = std.testing;
    var loop = try init(testing.allocator, .{});
    defer loop.deinit();

    const t1 = loop.now();
    loop.updateTime();
    const t2 = loop.now();

    try testing.expect(t2 >= t1);
}
