//! Time utilities for the event loop
//!
//! Provides monotonic time measurement for timers and timeouts.

const std = @import("std");

/// Monotonic timestamp in nanoseconds
pub const Timestamp = u64;

/// Get current monotonic time in nanoseconds
pub fn now() Timestamp {
    return @intCast(std.time.nanoTimestamp());
}

/// Convert seconds to nanoseconds
pub fn seconds(s: u64) u64 {
    return s * std.time.ns_per_s;
}

/// Convert milliseconds to nanoseconds
pub fn milliseconds(ms: u64) u64 {
    return ms * std.time.ns_per_ms;
}

/// Convert microseconds to nanoseconds
pub fn microseconds(us: u64) u64 {
    return us * std.time.ns_per_us;
}

/// Calculate time difference, handling wraparound
pub fn diff(later: Timestamp, earlier: Timestamp) u64 {
    if (later >= earlier) {
        return later - earlier;
    }
    return std.math.maxInt(u64) - earlier + later + 1;
}

test "time conversion" {
    const testing = std.testing;
    try testing.expectEqual(1_000_000_000, seconds(1));
    try testing.expectEqual(5_000_000_000, seconds(5));
    try testing.expectEqual(1_000_000, milliseconds(1));
    try testing.expectEqual(100_000_000, milliseconds(100));
    try testing.expectEqual(1_000, microseconds(1));
}

test "time diff" {
    const testing = std.testing;
    try testing.expectEqual(1000, diff(2000, 1000));
    try testing.expectEqual(0, diff(1000, 1000));
    try testing.expectEqual(100, diff(100, 0));
}
