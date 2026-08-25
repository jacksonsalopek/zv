//! Timer creation overhead, firing delay, and expired-timer dispatch.
//!
//! Firing delay is dominated by OS timer granularity, not library quality.
//! Repeating-timer wall-clock waits are not used: they measure sleep, not code.

const std = @import("std");
const zv = @import("zv");
const benchmarks = @import("infra.zig");
const Timer = benchmarks.Timer;
const Result = benchmarks.Result;

const c = @cImport({
    @cInclude("libev_wrapper.h");
});

const warmup_count = benchmarks.default_warmup;
const sample_count = benchmarks.default_samples;
const num_timers: usize = 1000;
const latency_samples: usize = 20;
const latency_timeout_ns: u64 = 10_000_000;
const dispatch_timers: usize = 100;

var zv_fired: usize = 0;
var libev_fired: usize = 0;
var latency_flag: bool = false;

fn zvNop(_: *zv.timer.Watcher) void {}
fn libevNop(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {}

pub fn run(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\nTimer Accuracy & Overhead\n");
    try writer.writeAll("=" ** 50);
    try writer.writeAll("\n\n");

    try writer.writeAll("Scenario 1: Timer creation (init + start) 1000 timers\n");
    try runCreation(allocator, writer);

    try writer.writeAll("\nScenario 2: 10ms one-shot firing delay (OS sleep dominates)\n");
    try runLatency(allocator, writer);

    try writer.writeAll("\nScenario 3: Dispatch already-expired one-shot timers\n");
    try runDispatch(allocator, writer);

    try writer.writeAll("\nTimer accuracy benchmark completed.\n");
}

fn runCreation(allocator: std.mem.Allocator, writer: anytype) !void {
    const zv_result = try benchZvCreation(allocator);
    const libev_result = try benchLibevCreation(allocator);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try Result.compareTime(libev_result, zv_result, writer);
}

fn startZvTimers(watchers: []zv.timer.Watcher, loop: *zv.Loop) !void {
    const hour_ns: u64 = 3_600 * std.time.ns_per_s;
    for (watchers, 0..) |*w, i| {
        w.* = zv.timer.Watcher.init(loop, hour_ns + i, 0, zvNop);
        try w.start();
    }
}

fn stopZvTimers(watchers: []zv.timer.Watcher) void {
    for (watchers) |*w| w.stop();
}

fn benchZvCreation(allocator: std.mem.Allocator) !Result {
    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();
    const watchers = try allocator.alloc(zv.timer.Watcher, num_timers);
    defer allocator.free(watchers);

    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        try startZvTimers(watchers, loop);
        stopZvTimers(watchers);
    }

    for (samples) |*sample| {
        var timer = try Timer.start();
        try startZvTimers(watchers, loop);
        sample.* = timer.read();
        stopZvTimers(watchers);
    }

    return Result.fromStats("zv (timer creation)", benchmarks.statsFromSamples(samples), num_timers, "starts/sec");
}

fn startLibevTimers(loop: *c.libev_loop, storage: *c.libev_timer, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = c.libev_timer_nth(storage, i);
        c.libev_timer_init(t, libevNop, 3600.0 + @as(f64, @floatFromInt(i)), 0);
        c.libev_timer_start(loop, t);
    }
}

fn stopLibevTimers(loop: *c.libev_loop, storage: *c.libev_timer, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        c.libev_timer_stop(loop, c.libev_timer_nth(storage, i));
    }
}

fn benchLibevCreation(allocator: std.mem.Allocator) !Result {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const storage = c.libev_timer_alloc_array(num_timers) orelse return error.WatcherCreationFailed;
    defer c.libev_timer_free_array(storage);

    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        startLibevTimers(loop, storage, num_timers);
        stopLibevTimers(loop, storage, num_timers);
    }

    for (samples) |*sample| {
        var timer = try Timer.start();
        startLibevTimers(loop, storage, num_timers);
        sample.* = timer.read();
        stopLibevTimers(loop, storage, num_timers);
    }

    return Result.fromStats("libev (timer creation)", benchmarks.statsFromSamples(samples), num_timers, "starts/sec");
}

fn zvLatencyCb(_: *zv.timer.Watcher) void {
    latency_flag = true;
}

fn libevLatencyCb(loop: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {
    if (loop) |l| c.libev_loop_break(l, c.LIBEV_BREAK_ONE);
}

fn runLatency(allocator: std.mem.Allocator, writer: anytype) !void {
    const zv_delays = try collectZvLatency(allocator);
    defer allocator.free(zv_delays);
    const libev_delays = try collectLibevLatency(allocator);
    defer allocator.free(libev_delays);

    try printDelayStats(allocator, writer, "zv (10ms firing delay)", zv_delays);
    try printDelayStats(allocator, writer, "libev (10ms firing delay)", libev_delays);
    try writer.writeAll(
        \\  These are signed (actual - requested) delays. Negative means early.
        \\  Do not treat a smaller delay as "the library is faster".
        \\
    );
}

fn collectZvLatency(allocator: std.mem.Allocator) ![]i64 {
    const delays = try allocator.alloc(i64, latency_samples);
    errdefer allocator.free(delays);

    // One untimed warmup so the first sample is not a cold start.
    _ = try oneZvLatency(allocator);

    var i: usize = 0;
    while (i < latency_samples) : (i += 1) {
        delays[i] = try oneZvLatency(allocator);
    }
    return delays;
}

fn oneZvLatency(allocator: std.mem.Allocator) !i64 {
    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();

    latency_flag = false;
    var watcher = zv.timer.Watcher.init(loop, latency_timeout_ns, 0, zvLatencyCb);
    var t = try Timer.start();
    try watcher.start();
    while (!latency_flag) {
        try loop.run(.once);
    }
    const elapsed = t.read();
    return @as(i64, @intCast(elapsed)) - @as(i64, @intCast(latency_timeout_ns));
}

fn collectLibevLatency(allocator: std.mem.Allocator) ![]i64 {
    const delays = try allocator.alloc(i64, latency_samples);
    errdefer allocator.free(delays);

    _ = try oneLibevLatency();

    var i: usize = 0;
    while (i < latency_samples) : (i += 1) {
        delays[i] = try oneLibevLatency();
    }
    return delays;
}

fn oneLibevLatency() !i64 {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);

    const timer = c.libev_timer_alloc_array(1) orelse return error.WatcherCreationFailed;
    defer c.libev_timer_free_array(timer);

    c.libev_timer_init(timer, libevLatencyCb, 0.01, 0);
    var t = try Timer.start();
    c.libev_timer_start(loop, timer);
    c.libev_loop_run(loop, c.LIBEV_RUN_DEFAULT);
    const elapsed = t.read();
    return @as(i64, @intCast(elapsed)) - @as(i64, @intCast(latency_timeout_ns));
}

fn printDelayStats(allocator: std.mem.Allocator, writer: anytype, name: []const u8, delays: []i64) !void {
    const abs_copy = try allocator.alloc(u64, delays.len);
    defer allocator.free(abs_copy);
    var signed_sum: i64 = 0;
    var early: usize = 0;
    var late: usize = 0;
    for (delays, 0..) |d, i| {
        signed_sum += d;
        abs_copy[i] = @abs(d);
        if (d < 0) early += 1 else late += 1;
    }
    std.mem.sort(u64, abs_copy, {}, std.sort.asc(u64));
    const median_abs = abs_copy[abs_copy.len / 2];
    const mean_signed = @divTrunc(signed_sum, @as(i64, @intCast(delays.len)));
    try writer.print("\n{s}:\n", .{name});
    try writer.print("  samples: {d}  early: {d}  late/on-time: {d}\n", .{ delays.len, early, late });
    try writer.print("  mean signed delay: {d} ns\n", .{mean_signed});
    try writer.print("  median |delay|:    {d} ns\n", .{median_abs});
}

fn zvDispatchCb(_: *zv.timer.Watcher) void {
    zv_fired += 1;
}

fn libevDispatchCb(_: ?*c.libev_loop, _: ?*c.libev_timer, _: c_int) callconv(.c) void {
    libev_fired += 1;
}

fn runDispatch(allocator: std.mem.Allocator, writer: anytype) !void {
    const zv_result = try benchZvDispatch(allocator);
    const libev_result = try benchLibevDispatch(allocator);
    try zv_result.print(writer);
    try libev_result.print(writer);
    try Result.compareTime(libev_result, zv_result, writer);
}

fn benchZvDispatch(allocator: std.mem.Allocator) !Result {
    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        _ = try oneZvDispatch(allocator);
    }
    for (samples) |*sample| {
        sample.* = try oneZvDispatch(allocator);
    }
    return Result.fromStats("zv (expired timer dispatch)", benchmarks.statsFromSamples(samples), dispatch_timers, "callbacks/sec");
}

fn oneZvDispatch(allocator: std.mem.Allocator) !u64 {
    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();
    const watchers = try allocator.alloc(zv.timer.Watcher, dispatch_timers);
    defer allocator.free(watchers);

    zv_fired = 0;
    for (watchers) |*w| {
        w.* = zv.timer.Watcher.init(loop, 0, 0, zvDispatchCb);
        try w.start();
    }

    var timer = try Timer.start();
    var spins: usize = 0;
    while (zv_fired < dispatch_timers) {
        try loop.run(.nowait);
        spins += 1;
        if (spins > dispatch_timers * 1000) return error.TimersDidNotFire;
    }
    const elapsed = timer.read();
    if (zv_fired != dispatch_timers) return error.DroppedCallbacks;
    return elapsed;
}

fn benchLibevDispatch(allocator: std.mem.Allocator) !Result {
    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);

    var w: usize = 0;
    while (w < warmup_count) : (w += 1) {
        _ = try oneLibevDispatch();
    }
    for (samples) |*sample| {
        sample.* = try oneLibevDispatch();
    }
    return Result.fromStats("libev (expired timer dispatch)", benchmarks.statsFromSamples(samples), dispatch_timers, "callbacks/sec");
}

fn oneLibevDispatch() !u64 {
    const loop = c.libev_loop_new() orelse return error.LoopCreationFailed;
    defer c.libev_loop_destroy(loop);
    const storage = c.libev_timer_alloc_array(dispatch_timers) orelse return error.WatcherCreationFailed;
    defer c.libev_timer_free_array(storage);

    libev_fired = 0;
    var i: usize = 0;
    while (i < dispatch_timers) : (i += 1) {
        const t = c.libev_timer_nth(storage, i);
        c.libev_timer_init(t, libevDispatchCb, 0, 0);
        c.libev_timer_start(loop, t);
    }

    var timer = try Timer.start();
    var spins: usize = 0;
    while (libev_fired < dispatch_timers) {
        c.libev_loop_run(loop, c.LIBEV_RUN_NOWAIT);
        spins += 1;
        if (spins > dispatch_timers * 1000) return error.TimersDidNotFire;
    }
    const elapsed = timer.read();
    if (libev_fired != dispatch_timers) return error.DroppedCallbacks;
    return elapsed;
}
