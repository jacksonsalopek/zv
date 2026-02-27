# zv Documentation

## Overview

**zv** is a high-performance event loop library for Zig, porting libev's core functionality with better memory safety and a smaller footprint.

## Quick Links

### User Documentation
- **[Main README](../README.md)** - Project overview and quick start
- **[Benchmarks](./benchmarks/README.md)** - Performance comparison with libev

### Benchmark Documentation
- **[Benchmark Overview](./benchmarks/README.md)** - User guide for running benchmarks
- **[Quick Reference](./benchmarks/quick-reference.md)** - Quick start guide
- **[Technical Details](./benchmarks/technical.md)** - Implementation and methodology
- **[System Architecture](./benchmarks/system.md)** - Detailed system documentation

## Project Structure

```
zv/
├── src/
│   ├── root.zig              # Library entry point
│   ├── loop.zig              # Event loop implementation
│   ├── backend.zig           # Backend abstraction
│   ├── time.zig              # Time utilities
│   ├── backend/
│   │   ├── epoll.zig         # Linux epoll backend
│   │   ├── kqueue.zig        # BSD/macOS kqueue backend
│   │   ├── poll.zig          # Portable poll backend
│   │   └── select.zig        # Universal select backend
│   ├── watcher/
│   │   ├── io.zig            # IO watcher
│   │   ├── timer.zig         # Timer watcher
│   │   └── signal.zig        # Signal watcher
│   └── benchmarks/           # Benchmark suite (requires libev)
│       ├── main.zig
│       ├── root.zig
│       ├── libev_wrapper.{c,h}
│       └── [benchmark files]
├── docs/
│   ├── README.md             # This file
│   └── benchmarks/           # Benchmark documentation
└── examples/
    └── basic_example.zig     # Usage example
```

## Features

### Core Features
- ✅ **Multiple Backends**: epoll, kqueue, poll, select
- ✅ **Watcher Types**: IO, Timer, Signal
- ✅ **Memory Safety**: Zig's allocator system and compile-time checks
- ✅ **Zero Cost Abstractions**: No runtime overhead
- ✅ **Platform Support**: Linux, BSD, macOS, and more

### Performance
- ✅ **21-34% faster** than libev in benchmarks
- ✅ **Comparable memory usage** with better safety guarantees
- ✅ **Linear scaling** characteristics

## Getting Started

### Basic Usage

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

    // Create a timer
    var timer = zv.timer.Watcher.init(
        &loop,
        zv.time.seconds(1),
        zv.time.seconds(1),
        timerCallback,
    );
    try timer.start();

    // Run the loop
    try loop.run(.until_done);
}

fn timerCallback(watcher: *zv.timer.Watcher) void {
    _ = watcher;
    std.debug.print("Timer fired!\n", .{});
}
```

### Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Generate documentation
zig build docs

# Run benchmarks (requires libev)
zig build benchmark
```

## API Documentation

### Core Types

- **`Loop`** - The main event loop
- **`Backend`** - Backend abstraction (epoll, kqueue, poll, select)
- **`io.Watcher`** - IO event watcher
- **`timer.Watcher`** - Timer watcher
- **`signal.Watcher`** - Signal watcher

### Loop Operations

```zig
// Initialize
var loop = try Loop.init(allocator, .{});
defer loop.deinit();

// Run modes
try loop.run(.until_done);  // Run until no watchers
try loop.run(.once);         // Run one iteration
try loop.run(.nowait);       // Run one iteration (no blocking)

// Time management
loop.updateTime();
const now = loop.now();
```

### Watchers

```zig
// IO Watcher
var io = zv.io.Watcher.init(&loop, fd, .read, callback);
try io.start();
io.stop();

// Timer Watcher
var timer = zv.timer.Watcher.init(&loop, timeout_ns, repeat_ns, callback);
try timer.start();
timer.stop();

// Signal Watcher
var signal = zv.signal.Watcher.init(&loop, signum, callback);
try signal.start();
signal.stop();
```

## Design Principles

1. **Memory Safety First** - Leverage Zig's compile-time safety guarantees
2. **Zero Dependencies** - Core library has no external dependencies
3. **Platform Agnostic** - Abstract backend selection
4. **Idiomatic Zig** - Follow Zig naming conventions and patterns
5. **Performance** - Comparable or better than C implementations

## Comparison with libev

| Feature | zv | libev |
|---------|-----|-------|
| **Language** | Zig | C |
| **Memory Safety** | Compile-time | Runtime |
| **Performance** | 1.2-1.5x faster | Baseline |
| **API** | Zig-idiomatic | C-style |
| **Dependencies** | None | None |
| **Line Count** | ~2000 | ~5000 |

See [benchmarks](./benchmarks/README.md) for detailed performance comparisons.

## Contributing

Contributions are welcome! When adding features:
1. Follow Zig naming conventions (snake_case for files and functions)
2. Maintain maximum 2-level nesting in functions
3. Use proper error handling with Zig error unions
4. Add tests for new functionality
5. Update documentation

## License

See repository root for license information.
