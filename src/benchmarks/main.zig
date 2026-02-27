//! Benchmark runner for zv vs libev comparison

const std = @import("std");
const benchmarks = @import("root.zig");

pub fn main() !void {
    std.debug.print("[benchmark] Starting...\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("[benchmark] Allocator initialized\n", .{});

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip();

    var benchmark_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            if (args.next()) |name| {
                benchmark_name = name;
            } else {
                try stdout.writeAll("Error: --name requires an argument\n");
                try printUsage(stdout);
                return error.MissingArgument;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            return;
        }
    }

    if (benchmark_name) |name| {
        std.debug.print("[benchmark] Running: {s}\n", .{name});
        try benchmarks.runByName(allocator, name, stdout);
    } else {
        std.debug.print("[benchmark] Running all benchmarks\n", .{});
        try benchmarks.runAll(allocator, stdout);
    }
    
    try stdout.flush();
    std.debug.print("[benchmark] Complete!\n", .{});
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: benchmark [options]
        \\
        \\Options:
        \\  --name <benchmark>    Run a specific benchmark
        \\  --help, -h            Show this help message
        \\
        \\Available benchmarks:
        \\  loop-throughput       Event loop iteration throughput
        \\  io-operations         IO watcher add/modify/remove operations
        \\  timer-accuracy        Timer scheduling, firing accuracy, and overhead
        \\  memory-usage          Memory consumption and allocation patterns
        \\  scaling               Performance with increasing numbers of watchers
        \\  all                   Run all benchmarks (default)
        \\
        \\Examples:
        \\  benchmark                          Run all benchmarks
        \\  benchmark -- --name loop-throughput  Run only loop throughput benchmark
        \\  benchmark -- --name scaling          Run only scaling benchmark
        \\
    );
}
