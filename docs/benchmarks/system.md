# zv Benchmark System - Implementation Summary

## Overview

A comprehensive benchmark suite comparing zv (Zig event loop) against libev (C reference implementation) across multiple performance dimensions.

## Architecture

### Key Design Decisions

1. **Isolated Dependency**: libev is ONLY linked for benchmark executables, never for the main zv library
2. **C Wrapper Layer**: Clean abstraction over libev via `libev_wrapper.{c,h}`
3. **Modular Structure**: Each benchmark is a self-contained module
4. **CLI Interface**: Single executable with subcommand support
5. **Statistical Analysis**: Multiple iterations with comprehensive metrics

### File Structure

```
src/benchmarks/
├── main.zig              # CLI entry point and argument parsing
├── root.zig              # Infrastructure (Timer, AllocTracker, Result)
├── libev_wrapper.{c,h}   # C wrapper for libev API
├── common.zig            # Additional common utilities
├── loop_throughput.zig   # Event loop iteration speed
├── loop_iteration.zig    # Alternative loop benchmark
├── io_operations.zig     # IO watcher add/modify/remove
├── io_watchers.zig       # Alternative IO benchmark
├── timer_accuracy.zig    # Timer precision and callback latency
├── timer_precision.zig   # Alternative timer benchmark
├── memory_usage.zig      # Memory footprint comparison (2 versions)
├── scaling.zig           # Performance vs watcher count
└── README.md             # User-facing documentation
```

## Build System Integration

### build.zig Configuration

```zig
// Create benchmark module with zv import
const benchmark_mod = b.createModule(.{
    .root_source_file = b.path("src/benchmarks/main.zig"),
    .target = target,
    .optimize = .ReleaseFast,
});
benchmark_mod.addImport("zv", mod);

// Create executable
const benchmark_exe = b.addExecutable(.{
    .name = "benchmark",
    .root_module = benchmark_mod,
});

// Link libev (BENCHMARK-ONLY DEPENDENCY)
benchmark_exe.linkSystemLibrary("ev");
benchmark_exe.linkLibC();

// Add C wrapper
benchmark_exe.addIncludePath(b.path("src/benchmarks"));
benchmark_exe.addCSourceFile(.{
    .file = b.path("src/benchmarks/libev_wrapper.c"),
    .flags = &.{"-std=c99"},
});
```

### Key Points

- **Release Optimization**: Benchmarks default to `.ReleaseFast`
- **System Library**: Uses system-installed libev, not bundled
- **C Interop**: Links libc for C wrapper compilation
- **Module Isolation**: Benchmark module separate from main library

## Benchmark Modules

### 1. Loop Throughput (`loop_throughput.zig`)

**Measures**: Raw event loop iteration overhead

**Method**:
- Empty event loop with immediate return
- Count iterations per second
- Compare zv vs libev dispatch speed

**Metrics**:
- Iterations/second
- Nanoseconds per iteration
- Throughput ratio

### 2. IO Operations (`io_operations.zig`)

**Measures**: Watcher registration/modification/removal cost

**Method**:
- Create test pipe for file descriptors
- Time add/modify/remove operations
- Compare backend integration overhead

**Metrics**:
- Add operation latency
- Modify operation latency
- Remove operation latency

### 3. Timer Accuracy (`timer_accuracy.zig`)

**Measures**: Timer scheduling precision and callback latency

**Method**:
- Schedule timers with known delays
- Measure actual vs expected fire time
- Calculate deviation statistics

**Metrics**:
- Mean callback latency
- Timer deviation (ns)
- Scheduling accuracy percentage

### 4. Memory Usage (`memory_usage.zig`)

**Measures**: Memory footprint with varying watcher counts

**Method**:
- Use tracking allocator for zv
- Create 10/100/1000 watchers
- Measure peak and per-watcher memory

**Metrics**:
- Peak allocated bytes
- Per-watcher cost
- Memory efficiency ratio

### 5. Scaling (`scaling.zig`)

**Measures**: Performance degradation with load

**Method**:
- Test with increasing watcher counts
- Measure latency at each scale
- Identify scaling characteristics

**Metrics**:
- Latency vs watcher count
- Throughput degradation curve
- Scaling factor (linear/sublinear)

## Infrastructure Components

### Timer (`root.zig`)

High-precision timing for benchmarks:

```zig
pub const Timer = struct {
    start_time: i128,
    
    pub fn start() !Timer;
    pub fn read(self: Timer) u64;
    pub fn readMicros(self: Timer) u64;
    pub fn readMillis(self: Timer) u64;
};
```

### AllocTracker (`root.zig`)

Allocation profiling:

```zig
pub const AllocTracker = struct {
    allocations: usize,
    deallocations: usize,
    bytes_allocated: usize,
    bytes_freed: usize,
    peak_memory: usize,
    current_memory: usize,
    
    pub fn allocator(self: *AllocTracker) std.mem.Allocator;
    pub fn snapshot(self: AllocTracker) Stats;
};
```

### Result (`root.zig`)

Benchmark result storage and formatting:

```zig
pub const Result = struct {
    name: []const u8,
    duration_ns: u64,
    iterations: usize,
    allocations: usize,
    bytes_allocated: usize,
    
    pub fn format(...) !void;
};
```

### Comparison (`root.zig`)

Side-by-side result comparison:

```zig
pub const Comparison = struct {
    pub fn init(baseline: Result, optimized: Result) Comparison;
    pub fn format(...) !void;  // Pretty-print with speedup
};
```

## libev C Wrapper

### Purpose

Provides clean Zig-friendly interface to libev without exposing raw C API.

### Design

- Opaque pointer types (no struct layouts exposed)
- Simple function calls (no C macros)
- Consistent naming (libev_* prefix)
- Memory management helpers

### Example Usage

```zig
const wrapper = @cImport({
    @cInclude("libev_wrapper.h");
});

const loop = wrapper.libev_loop_new();
defer wrapper.libev_loop_destroy(loop);

const io = wrapper.libev_io_new();
wrapper.libev_io_init(io, callback, fd, wrapper.LIBEV_READ);
wrapper.libev_io_start(loop, io);
```

## Usage

### Prerequisites

```bash
# Check for libev
./check_libev.sh

# Install if needed (Arch Linux)
sudo pacman -S libev
```

### Running Benchmarks

```bash
# All benchmarks
zig build benchmark

# Specific benchmark
zig build benchmark -- --name loop-throughput

# With release optimization (recommended)
zig build benchmark -Doptimize=ReleaseFast

# List available benchmarks
zig build benchmark -- --help
```

### Expected Output

```
======================================================================
                   zv vs libev Performance Benchmarks
======================================================================

=== Event Loop Throughput ===
Running loop throughput benchmark...
  zv:    2,450,000 iterations/sec (408 ns/iter)
  libev: 2,100,000 iterations/sec (476 ns/iter)
  🚀 zv is 1.17x faster

=== IO Watcher Operations ===
...
```

## Validation Status

✅ **All Requirements Met**:
- ✅ Loop iteration speed comparison
- ✅ IO watcher registration/unregistration
- ✅ Timer precision and overhead
- ✅ Memory usage comparison
- ✅ libev as benchmark-only dependency
- ✅ Separate build target
- ✅ Main library independent of libev
- ✅ Comprehensive statistical analysis

⚠️ **Optional Enhancement**:
- Signal handling performance (not implemented)

## Performance Goals

| Metric | Target | Rationale |
|--------|--------|-----------|
| Loop throughput | ≥ 0.8x libev | Core event loop performance |
| IO operations | ≥ 0.9x libev | Near-zero overhead goal |
| Timer accuracy | ≥ 0.9x libev | Critical for time-sensitive apps |
| Memory usage | ≤ 1.2x libev | Acceptable for safety benefits |

## Testing

### Unit Tests

Benchmark infrastructure includes tests:

```bash
zig build test  # Tests Timer, AllocTracker, etc.
```

### Integration Tests

Verify benchmarks compile without libev runtime:

```bash
zig build  # Should succeed even without libev
```

### Continuous Integration

Example GitHub Actions workflow:

```yaml
- name: Install libev
  run: sudo apt-get install -y libev-dev

- name: Run benchmarks
  run: zig build benchmark -Doptimize=ReleaseFast
```

## Future Enhancements

1. **Signal Handling Benchmark**: Add POSIX signal performance tests
2. **Real Workloads**: HTTP server, database proxy scenarios
3. **Cross-Platform**: Test on macOS (kqueue), Linux (epoll)
4. **Regression Tracking**: Store results over time
5. **Automated Reports**: Generate graphs and trends
6. **CI Integration**: Fail on performance regressions

## Documentation

- **User Guide**: [`src/benchmarks/README.md`](../src/benchmarks/README.md)
- **High-Level Overview**: [`BENCHMARKS.md`](../BENCHMARKS.md)
- **Main README**: [`README.md`](../README.md) (includes quick start)
- **This Document**: Implementation details for maintainers

## Maintenance

### Adding New Benchmarks

1. Create `src/benchmarks/new_feature.zig`
2. Implement `pub fn run(allocator, writer) !void`
3. Add to `root.zig` imports
4. Register in `runAll()` and `runByName()`
5. Update documentation

### Modifying libev Wrapper

1. Edit `libev_wrapper.h` (API) and `libev_wrapper.c` (impl)
2. Keep functions simple and opaque-pointer-based
3. Avoid exposing libev internals
4. Test with `zig build benchmark`

## Code Quality

### Naming Conventions

✅ Validated by redundancy-checker:
- No `_mod` suffixes on imports
- No redundant type names (e.g., no `TimerTimer`)
- Context-aware naming
- Proper Zig conventions

### Linting

All benchmark code passes without warnings:

```bash
zig build test  # No linter errors
```

### Safety

- Uses Zig allocators (memory leak detection)
- Error unions (no errno)
- Type safety (no void pointers in Zig code)
- Bounds checking (no buffer overflows)

## Conclusion

The benchmark system successfully validates zv's performance against libev while maintaining complete isolation of dependencies. The main zv library remains pure Zig with zero C dependencies, while benchmarks provide rigorous performance validation.
