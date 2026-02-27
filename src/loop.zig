//! Main event loop implementation
//!
//! The Loop manages watchers and dispatches events from the backend.

const std = @import("std");
const Backend = @import("backend.zig");
const time = @import("time.zig");
const IoWatcher = @import("watcher/io.zig").Watcher;
const TimerWatcher = @import("watcher/timer.zig").Watcher;
const PrepareWatcher = @import("watcher/prepare.zig").Watcher;
const CheckWatcher = @import("watcher/check.zig").Watcher;
const TimerHeap = @import("timer_heap.zig").TimerHeap;

const Loop = @This();

pub const Options = struct {
    backend: ?Backend.Kind = null,
    max_events: usize = 64,
    initial_watcher_capacity: usize = 32,
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
timer_heap: TimerHeap,
prepare_list: std.ArrayList(*PrepareWatcher),
check_list: std.ArrayList(*CheckWatcher),
pending_count: usize,

pub fn init(allocator: std.mem.Allocator, options: Options) !Loop {
    const backend_kind = options.backend orelse Backend.selectBest();
    const backend = try Backend.init(allocator, backend_kind);
    errdefer backend.deinit();

    const event_buffer = try allocator.alloc(Backend.Event, options.max_events);
    errdefer allocator.free(event_buffer);

    var io_watchers = std.AutoHashMap(std.posix.fd_t, *IoWatcher).init(allocator);
    try io_watchers.ensureTotalCapacity(@intCast(options.initial_watcher_capacity));

    return Loop{
        .allocator = allocator,
        .backend = backend,
        .event_buffer = event_buffer,
        .running = false,
        .iteration = 0,
        .now_cache = time.now(),
        .io_watchers = io_watchers,
        .timer_heap = TimerHeap.init(allocator),
        .prepare_list = std.ArrayList(*PrepareWatcher){},
        .check_list = std.ArrayList(*CheckWatcher){},
        .pending_count = 0,
    };
}

pub fn deinit(self: *Loop) void {
    self.backend.deinit();
    self.allocator.free(self.event_buffer);
    self.io_watchers.deinit();
    self.timer_heap.deinit();
    self.prepare_list.deinit(self.allocator);
    self.check_list.deinit(self.allocator);
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
    self.processPrepare();

    const timeout = self.calculateTimeout(mode);

    // Handle timer-only scenario: epoll/kqueue/poll require at least one file
    // descriptor to wait on. When we only have timers and no I/O watchers,
    // the backend returns immediately without waiting. We manually sleep
    // to allow timers to fire correctly.
    if (self.io_watchers.count() == 0 and timeout != null and timeout.? > 0) {
        std.Thread.sleep(timeout.?);
        self.updateTime();
        self.processCheck();
        try self.processTimers();
        return self.timer_heap.count() > 0;
    }

    const n_events = try self.backend.wait(self.event_buffer, timeout);

    self.updateTime();
    self.processCheck();

    for (self.event_buffer[0..n_events]) |event| {
        if (event.user_data) |user_data| {
            const watcher: *IoWatcher = @ptrCast(@alignCast(user_data));
            watcher.invoke(event.events);
        }
    }

    const has_active = self.io_watchers.count() > 0 or self.timer_heap.count() > 0;
    return has_active;
}

fn processTimers(self: *Loop) !void {
    const current_time = self.now();

    while (self.timer_heap.peek()) |timer| {
        if (!timer.isExpired(current_time)) break;
        
        _ = self.timer_heap.removeMin();
        timer.invoke();
        
        if (timer.active) {
            try self.timer_heap.insert(timer);
        }
    }
}

fn calculateTimeout(self: *Loop, mode: RunMode) ?u64 {
    if (mode == .nowait) return 0;

    const timer = self.timer_heap.peek() orelse return null;
    const current_time = self.now();

    const remaining = if (timer.deadline > current_time)
        timer.deadline - current_time
    else
        0;

    return remaining;
}

pub fn registerIoWatcher(self: *Loop, fd: std.posix.fd_t, watcher: *IoWatcher) !void {
    try self.io_watchers.put(fd, watcher);
}

pub fn unregisterIoWatcher(self: *Loop, fd: std.posix.fd_t) void {
    _ = self.io_watchers.remove(fd);
}

pub fn registerTimer(self: *Loop, watcher: *TimerWatcher) !void {
    try self.timer_heap.insert(watcher);
}

pub fn unregisterTimer(self: *Loop, watcher: *TimerWatcher) void {
    self.timer_heap.remove(watcher);
}

pub fn registerPrepare(self: *Loop, watcher: *PrepareWatcher) !void {
    try self.prepare_list.append(self.allocator, watcher);
}

pub fn unregisterPrepare(self: *Loop, watcher: *PrepareWatcher) void {
    for (self.prepare_list.items, 0..) |w, i| {
        if (w == watcher) {
            _ = self.prepare_list.swapRemove(i);
            break;
        }
    }
}

pub fn registerCheck(self: *Loop, watcher: *CheckWatcher) !void {
    try self.check_list.append(self.allocator, watcher);
}

pub fn unregisterCheck(self: *Loop, watcher: *CheckWatcher) void {
    for (self.check_list.items, 0..) |w, i| {
        if (w == watcher) {
            _ = self.check_list.swapRemove(i);
            break;
        }
    }
}

fn processPrepare(self: *Loop) void {
    for (self.prepare_list.items) |watcher| {
        if (watcher.active) {
            watcher.invoke();
        }
    }
}

fn processCheck(self: *Loop) void {
    for (self.check_list.items) |watcher| {
        if (watcher.active) {
            watcher.invoke();
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
