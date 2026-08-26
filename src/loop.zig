//! Main event loop implementation
//!
//! The Loop manages watchers and dispatches events from the backend.
//!
//! Concurrency (libev-like): `run`, watcher `start`/`stop`/`modify`, and
//! `deinit` are loop-thread only. Other threads may call `wakeup`,
//! `requestBreak`, and `now`. See docs/THREAD_SAFETY_ANALYSIS.md.

const std = @import("std");
const Backend = @import("backend.zig");
const time = @import("time.zig");
const IoWatcher = @import("watcher/io.zig").Watcher;
const TimerWatcher = @import("watcher/timer.zig").Watcher;
const PrepareWatcher = @import("watcher/prepare.zig").Watcher;
const CheckWatcher = @import("watcher/check.zig").Watcher;
const TimerHeap = @import("timer_heap.zig").TimerHeap;
const Waker = @import("waker.zig").Waker;
const sys = @import("sys.zig");

const Loop = @This();
const is_single_threaded = @import("builtin").single_threaded;

pub const Options = struct {
    backend: ?Backend.Kind = null,
    max_events: usize = 64,
    initial_watcher_capacity: usize = 32,
};

pub const RunMode = enum {
    /// Run until no I/O or timer watchers remain (libev `ev_run(0)`)
    until_done,
    /// Run one iteration, blocking if needed (libev `EVRUN_ONCE`)
    once,
    /// Run one iteration without blocking (libev `EVRUN_NOWAIT`)
    nowait,
};

/// How `requestBreak` should stop `run` (libev `ev_break`)
pub const BreakHow = enum(u8) {
    /// Leave the innermost `run` after this iteration (`EVBREAK_ONE`)
    one = 1,
    /// Leave all nested `run` calls (`EVBREAK_ALL`). Nested `run` is not
    /// supported, so this currently matches `.one`.
    all = 2,
};

allocator: std.mem.Allocator,
backend: Backend,
event_buffer: []Backend.Event,
mutex: if (is_single_threaded) void else sys.Mutex,
running: std.atomic.Value(bool),
iteration: u64,
now_cache: std.atomic.Value(time.Timestamp),
break_how: std.atomic.Value(u8),

waker: Waker,
waker_io: *IoWatcher,

timer_heap: TimerHeap,
prepare_list: std.ArrayList(*PrepareWatcher),
check_list: std.ArrayList(*CheckWatcher),
pending_count: usize,

/// Allocate a loop, open a backend, and register the internal waker.
pub fn init(allocator: std.mem.Allocator, options: Options) !*Loop {
    const loop = try allocator.create(Loop);
    errdefer allocator.destroy(loop);

    const backend_kind = options.backend orelse Backend.selectBest();
    const backend = try Backend.initSized(allocator, backend_kind, options.initial_watcher_capacity);
    errdefer backend.deinit();

    const event_buffer = try allocator.alloc(Backend.Event, options.max_events);
    errdefer allocator.free(event_buffer);

    const waker = try Waker.init();
    errdefer waker.deinit();

    loop.* = Loop{
        .allocator = allocator,
        .backend = backend,
        .event_buffer = event_buffer,
        .mutex = if (is_single_threaded) {} else .{},
        .running = std.atomic.Value(bool).init(false),
        .iteration = 0,
        .now_cache = std.atomic.Value(time.Timestamp).init(time.now()),
        .break_how = std.atomic.Value(u8).init(0),
        .waker = waker,
        .waker_io = undefined,
        .timer_heap = TimerHeap.init(allocator),
        .prepare_list = .empty,
        .check_list = .empty,
        .pending_count = 0,
    };
    errdefer loop.timer_heap.deinit();
    errdefer loop.prepare_list.deinit(allocator);
    errdefer loop.check_list.deinit(allocator);

    const waker_io = try allocator.create(IoWatcher);
    errdefer allocator.destroy(waker_io);
    waker_io.* = IoWatcher.init(loop, waker.read_fd, .read, wakerCallback);

    loop.waker_io = waker_io;
    try backend.add(waker.read_fd, .{ .read = true }, waker_io);
    errdefer loop.backend.remove(waker.read_fd) catch {};
    try backend.reify();

    return loop;
}

/// Release loop resources. Does not free `self`.
pub fn deinit(self: *Loop) void {
    self.backend.remove(self.waker.read_fd) catch {};
    self.allocator.destroy(self.waker_io);
    self.waker.deinit();
    self.backend.deinit();
    self.allocator.free(self.event_buffer);
    self.timer_heap.deinit();
    self.prepare_list.deinit(self.allocator);
    self.check_list.deinit(self.allocator);
}

/// Deinitialize and free `self`.
pub fn destroy(self: *Loop) void {
    const allocator = self.allocator;
    self.deinit();
    allocator.destroy(self);
}

fn lock(self: *Loop) void {
    if (is_single_threaded) return;
    self.mutex.lock();
}

fn unlock(self: *Loop) void {
    if (is_single_threaded) return;
    self.mutex.unlock();
}

/// Wake up the event loop from another thread
/// This is thread-safe and can be called from any thread
pub fn wakeup(self: *Loop) !void {
    try self.waker.wake();
}

/// Request that `run` return after the current iteration (libev `ev_break`).
/// Thread-safe: wakes a blocked `backend.wait` via the loop waker.
pub fn requestBreak(self: *Loop, how: BreakHow) void {
    self.break_how.store(@intFromEnum(how), .release);
    self.waker.wake() catch {};
}

/// Update cached time
pub fn updateTime(self: *Loop) void {
    self.now_cache.store(time.now(), .release);
}

/// Get current loop time (cached)
pub fn now(self: *Loop) time.Timestamp {
    return self.now_cache.load(.acquire);
}

/// Run the event loop
pub fn run(self: *Loop, mode: RunMode) !void {
    const was_running = self.running.swap(true, .acq_rel);
    if (was_running) return error.AlreadyRunning;
    defer self.running.store(false, .release);

    // libev clears break state at the start of ev_run
    self.break_how.store(0, .release);

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
    try self.backend.reify();

    if (!self.hasKeepers()) return false;

    const timeout = self.calculateTimeout(mode);

    // The waker fd is always registered with the backend, so backend.wait()
    // works even when there are no user I/O watchers.
    const n_events = try self.backend.wait(self.event_buffer, timeout);

    self.updateTime();
    self.processCheck();
    self.dispatchIo(n_events);
    try self.processTimers();

    if (self.break_how.load(.acquire) != 0) return false;
    return self.hasKeepers();
}

fn hasKeepers(self: *Loop) bool {
    return self.pending_count > 0;
}

/// Increment `pending_count` so `run(.until_done)` stays alive.
pub fn addKeeper(self: *Loop) void {
    self.pending_count += 1;
}

/// Decrement `pending_count`.
///
/// Asserts `pending_count > 0`.
pub fn removeKeeper(self: *Loop) void {
    std.debug.assert(self.pending_count > 0);
    self.pending_count -= 1;
}

fn dispatchIo(self: *Loop, n_events: usize) void {
    for (self.event_buffer[0..n_events]) |event| {
        const user_data = event.user_data orelse continue;
        const watcher: *IoWatcher = @ptrCast(@alignCast(user_data));
        watcher.invoke(event.events);
    }
}

fn processTimers(self: *Loop) !void {
    if (self.timer_heap.count() == 0) return;

    while (true) {
        const timer = self.takeExpiredTimer() orelse break;
        timer.invoke();
        try self.reinsertIfActive(timer);
    }
}

fn takeExpiredTimer(self: *Loop) ?*TimerWatcher {
    self.lock();
    defer self.unlock();
    const current_time = self.now();
    const timer = self.timer_heap.peek() orelse return null;
    if (!timer.isExpired(current_time)) return null;
    return self.timer_heap.removeMin();
}

fn reinsertIfActive(self: *Loop, timer: *TimerWatcher) !void {
    if (!timer.active) return;
    self.lock();
    defer self.unlock();
    if (self.timer_heap.contains(timer)) return;
    try self.timer_heap.insert(timer);
}

fn calculateTimeout(self: *Loop, mode: RunMode) ?u64 {
    if (mode == .nowait) return 0;
    if (self.timer_heap.count() == 0) return null;

    self.lock();
    defer self.unlock();
    
    const timer = self.timer_heap.peek() orelse return null;
    const current_time = self.now();

    const remaining = if (timer.deadline > current_time)
        timer.deadline - current_time
    else
        0;

    return remaining;
}

/// Insert `watcher` into the timer heap.
pub fn registerTimer(self: *Loop, watcher: *TimerWatcher) !void {
    self.lock();
    defer self.unlock();
    try self.timer_heap.insert(watcher);
}

/// Remove `watcher` from the timer heap.
pub fn unregisterTimer(self: *Loop, watcher: *TimerWatcher) void {
    self.lock();
    defer self.unlock();
    self.timer_heap.remove(watcher);
}

/// Append `watcher` to the prepare list.
pub fn registerPrepare(self: *Loop, watcher: *PrepareWatcher) !void {
    self.lock();
    defer self.unlock();
    try self.prepare_list.append(self.allocator, watcher);
}

/// Remove `watcher` from the prepare list.
pub fn unregisterPrepare(self: *Loop, watcher: *PrepareWatcher) void {
    self.lock();
    defer self.unlock();
    for (self.prepare_list.items, 0..) |w, i| {
        if (w == watcher) {
            _ = self.prepare_list.swapRemove(i);
            break;
        }
    }
}

/// Append `watcher` to the check list.
pub fn registerCheck(self: *Loop, watcher: *CheckWatcher) !void {
    self.lock();
    defer self.unlock();
    try self.check_list.append(self.allocator, watcher);
}

/// Remove `watcher` from the check list.
pub fn unregisterCheck(self: *Loop, watcher: *CheckWatcher) void {
    self.lock();
    defer self.unlock();
    for (self.check_list.items, 0..) |w, i| {
        if (w == watcher) {
            _ = self.check_list.swapRemove(i);
            break;
        }
    }
}

fn processPrepare(self: *Loop) void {
    self.invokePhase(PrepareWatcher, &self.prepare_list);
}

fn processCheck(self: *Loop) void {
    self.invokePhase(CheckWatcher, &self.check_list);
}

fn invokePhase(self: *Loop, comptime T: type, list: *std.ArrayList(*T)) void {
    if (list.items.len == 0) return;

    var i: usize = 0;
    while (true) {
        const watcher = self.watcherAt(T, list, i) orelse return;
        i += 1;
        if (watcher.active) watcher.invoke();
    }
}

fn watcherAt(self: *Loop, comptime T: type, list: *std.ArrayList(*T), i: usize) ?*T {
    self.lock();
    defer self.unlock();
    if (i >= list.items.len) return null;
    return list.items[i];
}

fn wakerCallback(watcher: *IoWatcher, events: Backend.EventMask) void {
    _ = events;
    const loop: *Loop = watcher.loop;
    loop.waker.drain();
}

test "loop init and deinit" {
    const testing = std.testing;
    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    try testing.expect(!loop.running.load(.acquire));
    try testing.expectEqual(0, loop.iteration);
}

test "loop time management" {
    const testing = std.testing;
    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    const t1 = loop.now();
    loop.updateTime();
    const t2 = loop.now();

    try testing.expect(t2 >= t1);
}

test "loop wakeup from another thread" {
    if (is_single_threaded) return error.SkipZigTest;
    
    const testing = std.testing;
    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    const TestState = struct {
        var woken_up: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        fn timerCallback(watcher: *TimerWatcher) void {
            watcher.stop();
        }
    };
    TestState.woken_up.store(false, .release);

    var long_timer = TimerWatcher.init(loop, time.seconds(100), 0, TestState.timerCallback);
    try long_timer.start();

    const WakerThread = struct {
        fn run(l: *Loop) void {
            sys.sleep(20 * std.time.ns_per_ms);
            l.wakeup() catch unreachable;
            TestState.woken_up.store(true, .release);
        }
    };

    const thread = try std.Thread.spawn(.{}, WakerThread.run, .{loop});
    defer thread.join();

    const start = time.now();
    try loop.run(.once);
    const elapsed = time.now() - start;

    try testing.expect(TestState.woken_up.load(.acquire));
    try testing.expect(elapsed < time.seconds(10));
}

test "oneshot timer fires during run once" {
    const testing = std.testing;

    const TestState = struct {
        var fired: bool = false;

        fn callback(watcher: *TimerWatcher) void {
            _ = watcher;
            fired = true;
        }
    };
    TestState.fired = false;

    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    var timer_watcher = TimerWatcher.init(loop, time.milliseconds(5), 0, TestState.callback);
    try timer_watcher.start();
    defer timer_watcher.stop();

    try loop.run(.once);
    try testing.expect(TestState.fired);
}

test "requestBreak stops until_done" {
    const testing = std.testing;

    const TestState = struct {
        var fires: u32 = 0;

        fn callback(watcher: *TimerWatcher) void {
            fires += 1;
            watcher.loop.requestBreak(.one);
        }
    };
    TestState.fires = 0;

    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    var timer_watcher = TimerWatcher.init(
        loop,
        time.milliseconds(1),
        time.milliseconds(1),
        TestState.callback,
    );
    try timer_watcher.start();
    defer timer_watcher.stop();

    try loop.run(.until_done);
    try testing.expect(TestState.fires >= 1);
    try testing.expect(TestState.fires < 50);
}

test "requestBreak from another thread" {
    if (is_single_threaded) return error.SkipZigTest;

    const testing = std.testing;
    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    var long_timer = TimerWatcher.init(loop, time.seconds(100), 0, struct {
        fn cb(watcher: *TimerWatcher) void {
            watcher.stop();
        }
    }.cb);
    try long_timer.start();
    defer long_timer.stop();

    const Breaker = struct {
        fn run(l: *Loop) void {
            sys.sleep(20 * std.time.ns_per_ms);
            l.requestBreak(.one);
        }
    };

    const thread = try std.Thread.spawn(.{}, Breaker.run, .{loop});
    defer thread.join();

    const start = time.now();
    try loop.run(.until_done);
    const elapsed = time.now() - start;

    try testing.expect(elapsed < time.seconds(10));
}

test "prepare callback can stop another watcher" {
    const testing = std.testing;

    const State = struct {
        var check: *CheckWatcher = undefined;

        fn prepareCb(watcher: *PrepareWatcher) void {
            check.stop();
            watcher.stop();
        }

        fn checkCb(watcher: *CheckWatcher) void {
            _ = watcher;
        }

        fn timerCb(watcher: *TimerWatcher) void {
            watcher.stop();
        }
    };

    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    var check_watcher = CheckWatcher.init(loop, State.checkCb);
    try check_watcher.start();
    defer check_watcher.stop();
    State.check = &check_watcher;

    var prepare_watcher = PrepareWatcher.init(loop, State.prepareCb);
    try prepare_watcher.start();
    defer prepare_watcher.stop();

    var timer_watcher = TimerWatcher.init(loop, time.milliseconds(5), 0, State.timerCb);
    try timer_watcher.start();
    defer timer_watcher.stop();

    try loop.run(.until_done);
}

test "prepare and check do not keep loop running" {
    const testing = std.testing;

    const Dummy = struct {
        fn prepareCb(watcher: *PrepareWatcher) void {
            _ = watcher;
        }
        fn checkCb(watcher: *CheckWatcher) void {
            _ = watcher;
        }
    };

    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    var prepare_watcher = PrepareWatcher.init(loop, Dummy.prepareCb);
    try prepare_watcher.start();
    defer prepare_watcher.stop();

    var check_watcher = CheckWatcher.init(loop, Dummy.checkCb);
    try check_watcher.start();
    defer check_watcher.stop();

    try loop.run(.until_done);
}

test "timer again from callback does not double-insert" {
    const testing = std.testing;

    const State = struct {
        var fires: u32 = 0;

        fn callback(watcher: *TimerWatcher) void {
            fires += 1;
            if (fires == 1) watcher.again() catch {};
            if (fires >= 2) watcher.loop.requestBreak(.one);
        }
    };
    State.fires = 0;

    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    var timer_watcher = TimerWatcher.init(
        loop,
        time.milliseconds(1),
        time.milliseconds(1),
        State.callback,
    );
    try timer_watcher.start();
    defer timer_watcher.stop();

    try loop.run(.until_done);
    try testing.expect(State.fires >= 2);
    try testing.expectEqual(1, loop.timer_heap.count());
}

test "now is readable from another thread" {
    if (is_single_threaded) return error.SkipZigTest;

    const testing = std.testing;
    const loop = try init(testing.allocator, .{});
    defer loop.destroy();

    const Reader = struct {
        fn run(l: *Loop, ok: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                _ = l.now();
            }
            ok.store(true, .release);
        }
    };

    var ok = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Reader.run, .{ loop, &ok });

    var n: usize = 0;
    while (n < 100) : (n += 1) {
        loop.updateTime();
    }

    thread.join();
    try testing.expect(ok.load(.acquire));
}
