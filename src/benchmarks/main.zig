//! Benchmark runner for zv vs libev comparison

const std = @import("std");
const benchmarks = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    // libc malloc on both sides so GPA overhead is not counted as "event loop".
    const allocator = std.heap.c_allocator;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var benchmark_name: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            const name = args.next() orelse {
                try stdout.writeAll("Error: --name requires an argument\n");
                try printUsage(stdout);
                return error.MissingArgument;
            };
            benchmark_name = name;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            try stdout.flush();
            return;
        }
    }

    if (benchmark_name) |name| {
        try benchmarks.runByName(allocator, name, stdout);
    } else {
        try benchmarks.runAll(allocator, stdout);
    }

    try stdout.flush();
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
        \\  memory-usage          zv heap usage (libev malloc is not compared)
        \\  scaling               Performance with increasing numbers of watchers
        \\  all                   Run all benchmarks (default)
        \\
        \\Examples:
        \\  zig build benchmark
        \\  zig build benchmark -- --name loop-throughput
        \\
        \\Results from a single run are not published scores. See docs/benchmarks/.
        \\
    );
}
