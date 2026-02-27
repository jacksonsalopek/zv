//! Common benchmark utilities and infrastructure
//!
//! Provides timing, statistical analysis, and result formatting for benchmarks.

const std = @import("std");

/// Benchmark result containing timing statistics
pub const Result = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    median_ns: u64,

    /// Format result for display
    pub fn format(
        self: Result,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}:\n", .{self.name});
        try writer.print("  Iterations: {d}\n", .{self.iterations});
        try writer.print("  Total:      {d} ns\n", .{self.total_ns});
        try writer.print("  Mean:       {d} ns\n", .{self.mean_ns});
        try writer.print("  Median:     {d} ns\n", .{self.median_ns});
        try writer.print("  Min:        {d} ns\n", .{self.min_ns});
        try writer.print("  Max:        {d} ns\n", .{self.max_ns});
    }
};

/// Comparison result between two benchmark results
pub const Comparison = struct {
    zv_result: Result,
    libev_result: Result,
    speedup: f64,

    pub fn format(
        self: Comparison,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("\n=== Benchmark Comparison ===\n\n");
        try writer.print("{}\n", .{self.zv_result});
        try writer.print("{}\n", .{self.libev_result});

        try writer.writeAll("\n--- Performance ---\n");
        if (self.speedup > 1.0) {
            try writer.print("zv is {d:.2}x FASTER than libev\n", .{self.speedup});
        } else if (self.speedup < 1.0) {
            try writer.print("libev is {d:.2}x FASTER than zv\n", .{1.0 / self.speedup});
        } else {
            try writer.writeAll("zv and libev have equal performance\n");
        }
        try writer.writeAll("\n");
    }

    pub fn init(zv_result: Result, libev_result: Result) Comparison {
        const speedup = @as(f64, @floatFromInt(libev_result.mean_ns)) /
            @as(f64, @floatFromInt(zv_result.mean_ns));

        return .{
            .zv_result = zv_result,
            .libev_result = libev_result,
            .speedup = speedup,
        };
    }
};

/// Timer for measuring elapsed time
pub const Timer = struct {
    timer: std.time.Timer,

    pub fn start() !Timer {
        return .{ .timer = try std.time.Timer.start() };
    }

    pub fn lap(self: *Timer) u64 {
        return self.timer.lap();
    }

    pub fn read(self: *Timer) u64 {
        return self.timer.read();
    }
};

/// Run a benchmark function multiple times and collect statistics
pub fn runBenchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    iterations: u64,
    benchFunc: *const fn () void,
) !Result {
    var samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var timer = try Timer.start();
        benchFunc();
        const elapsed = timer.read();

        samples[i] = elapsed;
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const mean_ns = total_ns / iterations;

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const median_ns = samples[samples.len / 2];

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .median_ns = median_ns,
    };
}

/// Configuration for benchmark runs
pub const Config = struct {
    /// Number of iterations for each benchmark
    iterations: u64 = 10_000,
    /// Number of warmup iterations (not measured)
    warmup: u64 = 100,
};

test "benchmark timer" {
    const testing = std.testing;

    var timer = try Timer.start();
    std.time.sleep(1_000_000); // 1ms
    const elapsed = timer.read();

    try testing.expect(elapsed >= 1_000_000);
}

test "comparison speedup calculation" {
    const testing = std.testing;

    const zv = Result{
        .name = "zv",
        .iterations = 1000,
        .total_ns = 1_000_000,
        .min_ns = 900,
        .max_ns = 1100,
        .mean_ns = 1000,
        .median_ns = 1000,
    };

    const libev = Result{
        .name = "libev",
        .iterations = 1000,
        .total_ns = 2_000_000,
        .min_ns = 1900,
        .max_ns = 2100,
        .mean_ns = 2000,
        .median_ns = 2000,
    };

    const comp = Comparison.init(zv, libev);
    try testing.expectApproxEqRel(2.0, comp.speedup, 0.01);
}
