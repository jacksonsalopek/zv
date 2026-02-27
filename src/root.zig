//! zv - A Zig port of libev with better memory safety and smaller footprint
//!
//! This library provides a high-performance event loop with support for:
//! - Multiple backends (epoll, kqueue, poll, select)
//! - IO watchers for monitoring file descriptors
//! - Timer watchers for time-based events
//! - Signal watchers for handling Unix signals
//!
//! Example usage:
//! ```zig
//! const zv = @import("zv");
//!
//! var loop = try zv.Loop.init(allocator, .{});
//! defer loop.deinit();
//!
//! var io = try zv.io.Watcher.init(&loop, fd, .read, callback, userdata);
//! try io.start();
//!
//! try loop.run(.until_done);
//! ```

const std = @import("std");

pub const Loop = @import("loop.zig");
pub const Backend = @import("backend.zig");
pub const time = @import("time.zig");

pub const io = struct {
    pub const Watcher = @import("watcher/io.zig").Watcher;
    pub const Event = @import("watcher/io.zig").Event;
};

pub const timer = struct {
    pub const Watcher = @import("watcher/timer.zig").Watcher;
};

pub const signal = struct {
    pub const Watcher = @import("watcher/signal.zig").Watcher;
};

test {
    std.testing.refAllDecls(@This());
}
