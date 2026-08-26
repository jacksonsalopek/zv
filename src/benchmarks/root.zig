//! Benchmark runner for zv vs libev

const std = @import("std");
const zv = @import("zv");
const infra = @import("infra.zig");

pub const loop_throughput = @import("loop_throughput.zig");
pub const io_operations = @import("io_operations.zig");
pub const timer_accuracy = @import("timer_accuracy.zig");
pub const memory_usage = @import("memory_usage.zig");
pub const scaling = @import("scaling.zig");

pub const Timer = infra.Timer;
pub const AllocTracker = infra.AllocTracker;
pub const Result = infra.Result;
pub const Stats = infra.Stats;
pub const default_warmup = infra.default_warmup;
pub const default_samples = infra.default_samples;
pub const keep = infra.keep;
pub const measure = infra.measure;
pub const statsFromSamples = infra.statsFromSamples;
pub const throughput = infra.throughput;
pub const printMethodology = infra.printMethodology;

fn announceBackend(writer: anytype) !void {
    const kind = zv.Backend.selectBest();
    // select wait() always returns 0; that is not a libev comparison.
    if (kind == .select) return error.SelectBackendUnimplemented;
    try writer.print("zv backend: {t} (not select; select wait is a stub)\n", .{kind});
}

pub fn runAll(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");
    try writer.writeAll("                   zv vs libev benchmarks\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");
    try printMethodology(writer);
    try announceBackend(writer);

    try writer.writeAll("\n=== Event Loop Throughput ===\n");
    try loop_throughput.run(allocator, writer);

    try writer.writeAll("\n=== IO Watcher Operations ===\n");
    try io_operations.run(allocator, writer);

    try writer.writeAll("\n=== Timer Accuracy & Overhead ===\n");
    try timer_accuracy.run(allocator, writer);

    try writer.writeAll("\n=== Memory Usage (zv heap only) ===\n");
    try memory_usage.run(allocator, writer);

    try writer.writeAll("\n=== Scaling Characteristics ===\n");
    try scaling.run(allocator, writer);

    try writer.writeAll("\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");
    try writer.writeAll("Benchmarks completed. Do not treat this run as a published score.\n");
    try writer.writeAll("=" ** 70);
    try writer.writeAll("\n");
}

pub fn runByName(allocator: std.mem.Allocator, name: []const u8, writer: anytype) !void {
    try printMethodology(writer);
    try announceBackend(writer);
    if (std.mem.eql(u8, name, "loop-throughput")) {
        try loop_throughput.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "io-operations")) {
        try io_operations.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "timer-accuracy")) {
        try timer_accuracy.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "memory-usage")) {
        try memory_usage.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "scaling")) {
        try scaling.run(allocator, writer);
    } else if (std.mem.eql(u8, name, "all")) {
        try runAll(allocator, writer);
    } else {
        return error.UnknownBenchmark;
    }
}
