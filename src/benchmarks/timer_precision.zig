//! Benchmark comparing timer precision and overhead
//!
//! Measures accuracy of timer firing and registration overhead.

const std = @import("std");
const zv = @import("zv");
const common = @import("common.zig");
const c = @cImport({
    @cInclude("ev.h");
});

const TIMER_DURATION_NS = 10_000_000; // 10ms

/// Benchmark zv timer precision
fn benchmarkZvTimers(allocator: std.mem.Allocator, iterations: u64) !common.Result {
    const State = struct {
        fired: u64 = 0,
        target: u64,
        deviations: std.ArrayList(i64),
        start_times: std.ArrayList(i64),
    };

    var deviations = std.ArrayList(i64).init(allocator);
    defer deviations.deinit();
    try deviations.ensureTotalCapacity(iterations);

    var start_times = std.ArrayList(i64).init(allocator);
    defer start_times.deinit();
    try start_times.ensureTotalCapacity(iterations);

    var state = State{
        .target = iterations,
        .deviations = deviations,
        .start_times = start_times,
    };

    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    const TimerCallback = struct {
        fn callback(watcher: *zv.timer.Watcher) void {
            const s: *State = @alignCast(@ptrCast(watcher.loop));
            const now = std.time.nanoTimestamp();
            const expected = s.start_times.items[s.fired];
            const deviation = now - expected;
            s.deviations.appendAssumeCapacity(deviation);
            s.fired += 1;
        }
    };

    var timer = zv.timer.Watcher.init(&loop, TIMER_DURATION_NS, 0, TimerCallback.callback);

    var bench_timer = try common.Timer.start();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        state.start_times.appendAssumeCapacity(start + TIMER_DURATION_NS);
        try timer.start();
        try loop.run(.until_done);
    }

    const elapsed = bench_timer.read();

    var total_deviation: u64 = 0;
    for (state.deviations.items) |dev| {
        total_deviation += @abs(dev);
    }
    const avg_deviation = total_deviation / iterations;

    return .{
        .name = "zv timers",
        .iterations = iterations,
        .total_ns = elapsed,
        .min_ns = elapsed / iterations,
        .max_ns = elapsed / iterations,
        .mean_ns = elapsed / iterations,
        .median_ns = avg_deviation,
    };
}

/// Benchmark libev timer precision
fn benchmarkLibevTimers(allocator: std.mem.Allocator, iterations: u64) !common.Result {
    const State = struct {
        fired: u64 = 0,
        target: u64,
        deviations: std.ArrayList(i64),
        start_times: std.ArrayList(i64),
    };

    var deviations = std.ArrayList(i64).init(allocator);
    defer deviations.deinit();
    try deviations.ensureTotalCapacity(iterations);

    var start_times = std.ArrayList(i64).init(allocator);
    defer start_times.deinit();
    try start_times.ensureTotalCapacity(iterations);

    var state = State{
        .target = iterations,
        .deviations = deviations,
        .start_times = start_times,
    };

    const loop = c.ev_loop_new(c.EVFLAG_AUTO);
    defer c.ev_loop_destroy(loop);

    const TimerCallback = struct {
        fn callback(
            loop_ptr: ?*c.struct_ev_loop,
            watcher: [*c]c.ev_timer,
            revents: c_int,
        ) callconv(.c) void {
            _ = revents;
            const s: *State = @alignCast(@ptrCast(watcher.*.data));
            const now = std.time.nanoTimestamp();
            const expected = s.start_times.items[s.fired];
            const deviation = now - expected;
            s.deviations.appendAssumeCapacity(deviation);
            s.fired += 1;
            c.ev_timer_stop(loop_ptr, watcher);
        }
    };

    var timer: c.ev_timer = undefined;
    timer.data = &state;

    const timeout_sec = @as(f64, @floatFromInt(TIMER_DURATION_NS)) / 1_000_000_000.0;

    var bench_timer = try common.Timer.start();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        state.start_times.appendAssumeCapacity(start + TIMER_DURATION_NS);
        c.ev_timer_init(&timer, TimerCallback.callback, timeout_sec, 0.0);
        c.ev_timer_start(loop, &timer);
        _ = c.ev_run(loop, c.EVRUN_ONCE);
    }

    const elapsed = bench_timer.read();

    var total_deviation: u64 = 0;
    for (state.deviations.items) |dev| {
        total_deviation += @abs(dev);
    }
    const avg_deviation = total_deviation / iterations;

    return .{
        .name = "libev timers",
        .iterations = iterations,
        .total_ns = elapsed,
        .min_ns = elapsed / iterations,
        .max_ns = elapsed / iterations,
        .mean_ns = elapsed / iterations,
        .median_ns = avg_deviation,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const config = common.Config{ .iterations = 100 };

    try stdout.print("Running timer precision benchmark ({d} iterations)...\n", .{config.iterations});
    try stdout.print("Timer duration: {d}ms\n\n", .{TIMER_DURATION_NS / 1_000_000});

    const zv_result = try benchmarkZvTimers(allocator, config.iterations);
    const libev_result = try benchmarkLibevTimers(allocator, config.iterations);

    const comparison = common.Comparison.init(zv_result, libev_result);
    try stdout.print("{}", .{comparison});

    try stdout.print("Average timer deviation:\n", .{});
    try stdout.print("  zv:    {d} ns\n", .{zv_result.median_ns});
    try stdout.print("  libev: {d} ns\n", .{libev_result.median_ns});
}
