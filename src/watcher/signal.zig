//! Signal watcher for Unix signals using the self-pipe trick
//!
//! Implements production-ready signal handling by:
//! - Registering async-signal-safe handlers with sigaction()
//! - Writing signal number to a pipe from the signal handler
//! - Reading from pipe in event loop to invoke user callback
//! - Properly restoring previous signal handlers on cleanup

const std = @import("std");
const Loop = @import("../loop.zig");
const IoWatcher = @import("io.zig").Watcher;
const Backend = @import("../backend.zig");
const builtin = @import("builtin");
const posix = std.posix;
const sys = @import("../sys.zig");

/// Called from the event loop with the delivered signal number.
pub const Callback = *const fn (watcher: *Watcher, signum: c_int) void;

const NSIG = 64;
const invalid_fd: i32 = -1;

var signal_registry: [NSIG]std.atomic.Value(?*Watcher) = [_]std.atomic.Value(?*Watcher){std.atomic.Value(?*Watcher).init(null)} ** NSIG;
var signal_write_fds: [NSIG]std.atomic.Value(i32) = [_]std.atomic.Value(i32){std.atomic.Value(i32).init(invalid_fd)} ** NSIG;

pub const Watcher = struct {
    loop: *Loop,
    signum: posix.SIG,
    callback: Callback,
    active: bool,
    pipe_fds: ?struct {
        read: posix.fd_t,
        write: posix.fd_t,
    },
    io_watcher: ?IoWatcher,
    old_action: ?posix.Sigaction,

    /// Create an inactive watcher for `signum`.
    pub fn init(
        loop: *Loop,
        signum: posix.SIG,
        callback: Callback,
    ) Watcher {
        return .{
            .loop = loop,
            .signum = signum,
            .callback = callback,
            .active = false,
            .pipe_fds = null,
            .io_watcher = null,
            .old_action = null,
        };
    }

    /// Register the handler and self-pipe. Fails if `signum` is already watched.
    pub fn start(self: *Watcher) !void {
        if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;
        if (self.active) return;
        const raw = signumInt(self.signum);
        if (raw < 0 or raw >= NSIG) return error.InvalidSignal;

        const index: usize = @intCast(raw);
        if (signal_registry[index].load(.acquire) != null) return error.SignalAlreadyWatched;

        try self.install(index);
        if (signal_registry[index].cmpxchgStrong(null, self, .release, .acquire) != null) {
            self.uninstall();
            return error.SignalAlreadyWatched;
        }
        self.active = true;
    }

    /// Restore the previous handler and close the self-pipe. No-op if inactive.
    pub fn stop(self: *Watcher) void {
        if (!self.active) return;
        self.active = false;
        self.uninstall();
    }

    fn install(self: *Watcher, index: usize) !void {
        const fds = try openSignalPipe();
        errdefer closePipe(fds);

        self.pipe_fds = .{ .read = fds[0], .write = fds[1] };
        errdefer self.pipe_fds = null;

        signal_write_fds[index].store(fds[1], .release);
        errdefer signal_write_fds[index].store(invalid_fd, .release);

        self.io_watcher = IoWatcher.init(self.loop, fds[0], .read, onPipeReadable);
        errdefer self.io_watcher = null;
        try self.io_watcher.?.start();
        errdefer self.io_watcher.?.stop() catch {};

        self.old_action = registerSignalHandler(self.signum);
    }

    fn uninstall(self: *Watcher) void {
        const index: usize = @intCast(signumInt(self.signum));
        signal_write_fds[index].store(invalid_fd, .release);
        signal_registry[index].store(null, .release);

        if (self.old_action) |old_action| {
            posix.sigaction(self.signum, &old_action, null);
            self.old_action = null;
        }

        if (self.io_watcher) |*watcher| {
            watcher.stop() catch {};
            self.io_watcher = null;
        }

        if (self.pipe_fds) |fds| {
            sys.close(fds.read);
            sys.close(fds.write);
            self.pipe_fds = null;
        }
    }

    /// Stop the watcher if it is still active.
    pub fn deinit(self: *Watcher) void {
        self.stop();
    }

    fn onPipeReadable(io_watcher: *IoWatcher, events: Backend.EventMask) void {
        _ = events;

        const read_fd = io_watcher.fd;
        var sig_buf: [1]u8 = undefined;

        while (true) {
            const bytes_read = posix.read(read_fd, &sig_buf) catch break;
            if (bytes_read == 0) break;
            dispatchSignal(@intCast(sig_buf[0]));
        }
    }
};

fn dispatchSignal(signum: c_int) void {
    if (signum < 0 or signum >= NSIG) return;
    const index: usize = @intCast(signum);
    const watcher = signal_registry[index].load(.acquire) orelse return;
    watcher.callback(watcher, signum);
}

fn signumInt(sig: posix.SIG) c_int {
    return @intCast(@intFromEnum(sig));
}

fn openSignalPipe() ![2]posix.fd_t {
    return sys.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

fn closePipe(fds: [2]posix.fd_t) void {
    sys.close(fds[0]);
    sys.close(fds[1]);
}

fn writeSignal(fd: i32, buf: []const u8) void {
    _ = sys.write(fd, buf) catch {};
}

fn registerSignalHandler(signum: posix.SIG) posix.Sigaction {
    var new_action = posix.Sigaction{
        .handler = .{ .handler = signalHandlerTrampoline },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };

    var old_action: posix.Sigaction = undefined;
    posix.sigaction(signum, &new_action, &old_action);
    return old_action;
}

fn signalHandlerTrampoline(sig: posix.SIG) callconv(.c) void {
    const raw = signumInt(sig);
    if (raw < 0 or raw >= NSIG) return;

    const index: usize = @intCast(raw);
    const fd = signal_write_fds[index].load(.acquire);
    if (fd < 0) return;

    const sig_byte: [1]u8 = .{@intCast(raw)};
    writeSignal(fd, &sig_byte);
}

test "signal watcher init" {
    const testing = std.testing;

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            _ = signum;
        }
    };

    const SIGUSR1 = posix.SIG.USR1;
    var watcher = Watcher.init(loop, SIGUSR1, DummyCallback.callback);
    defer watcher.deinit();

    try testing.expect(!watcher.active);
}

test "signal watcher start and stop" {
    const testing = std.testing;

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            _ = signum;
        }
    };

    const SIGUSR1 = posix.SIG.USR1;
    var watcher = Watcher.init(loop, SIGUSR1, DummyCallback.callback);
    defer watcher.deinit();

    try watcher.start();
    try testing.expect(watcher.active);
    try testing.expect(watcher.pipe_fds != null);
    try testing.expect(watcher.io_watcher != null);

    watcher.stop();
    try testing.expect(!watcher.active);
    try testing.expect(watcher.pipe_fds == null);
}

test "signal watcher receives signal" {
    const testing = std.testing;

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const TestContext = struct {
        var received: bool = false;
        var signum_received: c_int = 0;

        fn callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            received = true;
            signum_received = signum;
        }

        fn reset() void {
            received = false;
            signum_received = 0;
        }
    };

    TestContext.reset();

    const SIGUSR1 = posix.SIG.USR1;
    
    var watcher = Watcher.init(loop, SIGUSR1, TestContext.callback);
    defer watcher.deinit();

    try watcher.start();

    try posix.raise(SIGUSR1);

    try loop.run(.once);

    try testing.expect(TestContext.received);
    try testing.expectEqual(signumInt(SIGUSR1), TestContext.signum_received);
}

test "signal watcher prevents duplicate registration" {
    const testing = std.testing;

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            _ = signum;
        }
    };

    const SIGUSR1 = posix.SIG.USR1;
    
    var watcher1 = Watcher.init(loop, SIGUSR1, DummyCallback.callback);
    defer watcher1.deinit();

    var watcher2 = Watcher.init(loop, SIGUSR1, DummyCallback.callback);
    defer watcher2.deinit();

    try watcher1.start();

    const result = watcher2.start();
    try testing.expectError(error.SignalAlreadyWatched, result);
}

test "signal watcher restores previous handler" {
    const testing = std.testing;

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const DummyCallback = struct {
        fn callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            _ = signum;
        }
    };

    const SIGUSR1 = posix.SIG.USR1;

    var original_action: posix.Sigaction = undefined;
    posix.sigaction(SIGUSR1, null, &original_action);

    var watcher = Watcher.init(loop, SIGUSR1, DummyCallback.callback);
    try watcher.start();
    try testing.expect(watcher.old_action != null);

    watcher.stop();

    var current_action: posix.Sigaction = undefined;
    posix.sigaction(SIGUSR1, null, &current_action);

    try testing.expectEqual(original_action.handler.handler, current_action.handler.handler);
}

test "signal watcher handles multiple signals" {
    const testing = std.testing;

    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const loop = try Loop.init(testing.allocator, .{});
    defer loop.destroy();

    const TestContext = struct {
        var usr1_count: u32 = 0;
        var usr2_count: u32 = 0;

        fn usr1_callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            _ = signum;
            usr1_count += 1;
        }

        fn usr2_callback(watcher: *Watcher, signum: c_int) void {
            _ = watcher;
            _ = signum;
            usr2_count += 1;
        }

        fn reset() void {
            usr1_count = 0;
            usr2_count = 0;
        }
    };

    TestContext.reset();

    const SIGUSR1 = posix.SIG.USR1;
    const SIGUSR2 = posix.SIG.USR2;

    var watcher1 = Watcher.init(loop, SIGUSR1, TestContext.usr1_callback);
    defer watcher1.deinit();

    var watcher2 = Watcher.init(loop, SIGUSR2, TestContext.usr2_callback);
    defer watcher2.deinit();

    try watcher1.start();
    try watcher2.start();

    try posix.raise(SIGUSR1);
    try posix.raise(SIGUSR2);
    try posix.raise(SIGUSR1);

    try loop.run(.once);

    try testing.expectEqual(@as(u32, 2), TestContext.usr1_count);
    try testing.expectEqual(@as(u32, 1), TestContext.usr2_count);
}
