# zv - High-Performance Event Loop for Zig

A Zig port of libev with better memory safety and a smaller footprint. zv provides a high-performance, cross-platform event loop library for building asynchronous I/O applications.

## Documentation

- **[API Documentation](./docs/README.md)** - Complete API reference and guides
- **[Benchmarks](./docs/benchmarks/README.md)** - Performance comparison with libev
- **[Examples](./examples/)** - Usage examples (see below for running)

## Examples

View example code in the `examples/` directory:
- `basic_example.zig` - IO and timer watchers
- `prepare_check_example.zig` - Prepare and check watchers

## Features

- **Multiple Backends**: Automatically selects the best backend for your platform
  - `epoll` on Linux
  - `kqueue` on BSD/macOS
  - `poll` as POSIX fallback
  - `select` as universal fallback

- **Watcher Types**:
  - IO watchers for file descriptor monitoring
  - Timer watchers for time-based events
  - Signal watchers for Unix signal handling
  - Prepare watchers for pre-poll callbacks
  - Check watchers for post-poll callbacks

- **Memory Safe**: Uses Zig's allocator system and error handling
- **Zero Dependencies**: Only uses Zig's standard library
- **Library-Only**: Designed as a reusable library, not an executable

## Installation

Add zv to your `build.zig.zon`:

```zig
.dependencies = .{
    .zv = .{
        .url = "https://github.com/yourusername/zv/archive/main.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const zv = b.dependency("zv", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zv", zv.module("zv"));
```

## Quick Start

```zig
const std = @import("std");
const zv = @import("zv");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create event loop
    var loop = try zv.Loop.init(allocator, .{});
    defer loop.deinit();

    // IO watcher example
    const stdin_fd = std.io.getStdIn().handle;
    
    var io_watcher = zv.io.Watcher.init(
        &loop,
        stdin_fd,
        .read,
        handleIoEvent,
    );
    try io_watcher.start();
    defer io_watcher.stop() catch {};

    // Timer example
    var timer = zv.timer.Watcher.init(
        &loop,
        zv.time.seconds(5),
        zv.time.seconds(1),  // repeat every 1 second
        handleTimerEvent,
    );
    try timer.start();
    defer timer.stop();

    // Run the event loop
    try loop.run(.until_done);
}

fn handleIoEvent(watcher: *zv.io.Watcher, events: zv.Backend.EventMask) void {
    if (events.read) {
        std.debug.print("Data available to read on fd {}\n", .{watcher.fd});
    }
}

fn handleTimerEvent(watcher: *zv.timer.Watcher) void {
    std.debug.print("Timer fired!\n", .{});
    _ = watcher;
}
```

## API Documentation

### Loop

The main event loop structure.

```zig
// Initialize a loop
var loop = try zv.Loop.init(allocator, .{});
defer loop.deinit();

// Run modes
try loop.run(.until_done);  // Run until no active watchers
try loop.run(.once);         // Run one iteration, blocking
try loop.run(.nowait);       // Run one iteration, non-blocking

// Time management
const current_time = loop.now();  // Cached time
loop.updateTime();                 // Update cached time
```

### IO Watchers

Monitor file descriptors for read/write availability.

```zig
var watcher = zv.io.Watcher.init(&loop, fd, .read, callback);
try watcher.start();
try watcher.modify(.both);  // Change to monitor both read and write
try watcher.stop();
```

### Timer Watchers

Schedule callbacks after a timeout.

```zig
// One-shot timer (5 seconds)
var timer = zv.timer.Watcher.init(&loop, zv.time.seconds(5), 0, callback);
try timer.start();

// Repeating timer (initial 5s, then every 1s)
var repeating = zv.timer.Watcher.init(
    &loop,
    zv.time.seconds(5),
    zv.time.seconds(1),
    callback,
);
try repeating.start();

// Check remaining time
const remaining_ns = timer.remaining();

// Restart a repeating timer
try timer.again();
```

### Signal Watchers

Handle Unix signals (not supported on Windows).

```zig
const SIGINT = std.posix.SIG.INT;
var signal_watcher = zv.signal.Watcher.init(&loop, SIGINT, callback);
try signal_watcher.start();
defer signal_watcher.deinit();
```

### Prepare Watchers

Execute callbacks before the loop polls for events.

```zig
var prepare = zv.prepare.Watcher.init(&loop, callback);
try prepare.start();
defer prepare.stop();

// Callback runs before each backend.wait() call
fn callback(watcher: *zv.prepare.Watcher) void {
    std.debug.print("About to poll...\n", .{});
}
```

**Use cases:**
- Integrating other event loops
- Setup work before blocking
- Performance instrumentation

### Check Watchers

Execute callbacks after the loop polls for events.

```zig
var check = zv.check.Watcher.init(&loop, callback);
try check.start();
defer check.stop();

// Callback runs after each backend.wait() call
fn callback(watcher: *zv.check.Watcher) void {
    std.debug.print("Just finished polling...\n", .{});
}
```

**Use cases:**
- Integrating other event loops
- Cleanup work after blocking
- Latency measurements

## Time Utilities

```zig
const five_sec = zv.time.seconds(5);
const hundred_ms = zv.time.milliseconds(100);
const five_hundred_us = zv.time.microseconds(500);

const now = zv.time.now();
const elapsed = zv.time.diff(later, earlier);
```

## Backend Selection

zv automatically selects the best backend for your platform:

```zig
// Automatic selection
var loop = try zv.Loop.init(allocator, .{});

// Manual selection
var loop = try zv.Loop.init(allocator, .{ .backend = .epoll });

// Check what was selected
const backend = zv.Backend.selectBest();
```

## Testing

Run the test suite:

```bash
zig build test
```

Generate documentation:

```bash
zig build docs
```

## Benchmarking

Compare zv's performance against libev. Requires libev installed on your system.

**Note:** libev is ONLY required for benchmarks. The main zv library has zero dependencies.

**Run benchmarks:**
```bash
# Run all benchmarks
zig build benchmark

# Run specific benchmark
zig build benchmark -- --name loop-throughput
zig build benchmark -- --name io-operations
zig build benchmark -- --name timer-accuracy
zig build benchmark -- --name memory-usage
zig build benchmark -- --name scaling

# Get help
zig build benchmark -- --help
```

If libev is not installed, the build system will provide installation instructions for your platform.

**Results:**
zv demonstrates **21-34% better performance** than libev across various scenarios:
- Empty loop: 1.47x faster
- 100 idle watchers: 1.51x faster
- 50 active timers: 1.27x faster

See [**Benchmark Documentation**](./docs/benchmarks/README.md) for detailed results and methodology.

## Platform Support

- **Linux**: Full support with epoll backend
- **macOS/BSD**: Full support with kqueue backend
- **Other POSIX**: Poll backend fallback
- **Windows**: Select backend (basic support)

## Performance

zv is designed for high performance:
- Zero-copy event delivery
- Efficient backend selection per platform
- Minimal allocations during event loop runtime
- Cached time to avoid excessive syscalls

## License

MIT License - see LICENSE file for details

## Comparison with libev

| Feature | libev | zv |
|---------|-------|-----|
| Language | C | Zig |
| Memory Safety | Manual | Automatic (Zig allocators) |
| Error Handling | errno | Zig error unions |
| Backends | epoll, kqueue, poll, select, more | epoll, kqueue, poll, select |
| Footprint | ~50KB | ~30KB |
| Dependencies | libc | Only Zig std |

## Contributing

Contributions are welcome! Please ensure:
- All tests pass (`zig build test`)
- Code follows Zig style guidelines
- New features include tests and documentation

## Roadmap

- [x] Add prepare/check watchers
- [ ] Add async watcher support
- [ ] Add child process watchers
- [x] Benchmark suite
- [x] Comprehensive examples
