# zv vs libev Performance Benchmarks

Comprehensive performance comparison between zv (our Zig event loop) and libev (the original C implementation).

## Overview

These benchmarks validate that zv offers comparable performance to libev while providing better memory safety through Zig's type system and ownership model. libev is **only used as a dependency for benchmarking** and is not part of the main zv library.

## Prerequisites

To run the benchmarks, you need:

1. **Zig** (latest stable version)
2. **libev** installed on your system:
   ```bash
   # Arch Linux
   sudo pacman -S libev
   
   # Ubuntu/Debian
   sudo apt-get install libev-dev
   
   # macOS
   brew install libev
   ```

## Running Benchmarks

### Run All Benchmarks

```bash
zig build benchmark
```

This will run all benchmark suites and output comprehensive performance metrics.

### Run Specific Benchmark

```bash
# Event loop throughput
zig build benchmark -- --name loop-throughput

# IO watcher operations
zig build benchmark -- --name io-operations

# Timer accuracy and overhead
zig build benchmark -- --name timer-accuracy

# Memory usage comparison
zig build benchmark -- --name memory-usage

# Scaling characteristics
zig build benchmark -- --name scaling
```

### Get Help

```bash
zig build benchmark -- --help
```

## Benchmark Suites

### 1. Loop Throughput (`loop-throughput`)

**What it measures:** Iterations per second the event loop can handle under different workloads.

**Scenarios:**
- Empty loop (no watchers)
- Loop with 100 idle IO watchers
- Loop with 50 active timers

**Key metrics:**
- Time per iteration
- Throughput (iterations/second)
- Speedup/slowdown comparison

**Example output:**
```
Event Loop Throughput Benchmark
================================================

Scenario 1: Empty loop (no watchers)

zv (empty loop):
  Time:        25034567 ns (25.03 ms)
  Per iter:    250 ns
  Throughput:  3994483.52 ops/sec

libev (empty loop):
  Time:        23456789 ns (23.46 ms)
  Per iter:    234 ns
  Throughput:  4263565.89 ops/sec

Comparison (libev vs zv):
  🐌 6.73% slower (1.07x slowdown)
```

### 2. IO Operations (`io-operations`)

**What it measures:** Performance of IO watcher lifecycle operations.

**Scenarios:**
- Add watchers: Creating and registering 1000 IO watchers
- Modify watchers: Changing events on 1000 watchers 10 times
- Remove watchers: Unregistering 1000 watchers

**Key metrics:**
- Total time for operations
- Time per operation
- Allocations and memory usage (zv only)

**Why it matters:** These operations are frequently called in real applications as connections are accepted, monitored, and closed.

### 3. Timer Accuracy (`timer-accuracy`)

**What it measures:** Timer scheduling overhead, firing precision, and cleanup performance.

**Scenarios:**
- Timer creation: Overhead of creating and starting 1000 timers
- Timer latency: Measuring how accurately timers fire (100 samples)
- Repeating timers: Performance with 10 repeating timers over 1000 iterations

**Key metrics:**
- Creation overhead
- Average firing latency
- Throughput with active timers

**Why it matters:** Timer precision affects quality of time-based operations like animations, timeouts, and periodic tasks.

### 4. Memory Usage (`memory-usage`)

**What it measures:** Memory consumption and allocation patterns.

**Scenarios:**
- Loop initialization: Memory overhead of creating an event loop
- IO watchers: Memory per IO watcher (100 watchers)
- Timer watchers: Memory per timer (100 timers)
- Mixed workload: Memory with 50 IO + 50 timer watchers

**Key metrics:**
- Total allocations
- Bytes allocated
- Peak memory usage

**Why it matters:** Lower memory usage allows running more concurrent connections and reduces system pressure.

### 5. Scaling (`scaling`)

**What it measures:** How performance degrades with increasing numbers of watchers.

**Scenarios:**
- IO scaling: Throughput with 10, 50, 100, 500, 1000 IO watchers
- Timer scaling: Throughput with 10, 50, 100, 250, 500 timers

**Key metrics:**
- Time vs number of watchers
- Performance ratio at each scale
- Scaling trends

**Example output:**
```
Testing throughput with increasing IO watchers:

Watcher Count | zv (ms) | libev (ms) | Comparison
------------- | ------- | ---------- | ----------
           10 |    2.34 |       2.12 | 1.10x slower
           50 |   11.23 |      10.89 | 1.03x slower
          100 |   22.45 |      21.78 | 1.03x slower
          500 |  112.34 |     109.23 | 1.03x slower
         1000 |  224.56 |     218.45 | 1.03x slower
```

**Why it matters:** Demonstrates how well the library handles high-load scenarios with many concurrent operations.

## Implementation Details

### C Wrapper for libev

The benchmarks use a thin C wrapper (`libev_wrapper.c/h`) that provides a consistent interface to libev. This wrapper:

- Abstracts libev's API for easy comparison
- Provides opaque types for libev structures
- Handles C callbacks and memory management
- Is **only compiled for benchmarks**, not the main library

### Fair Comparison

To ensure fair benchmarks:

1. **Same workload**: Both libraries process identical operations
2. **Compiled with optimizations**: Benchmarks use `ReleaseFast`
3. **Multiple samples**: Most tests run multiple iterations for statistical validity
4. **Warmup runs**: Code paths are warmed before measurement
5. **Isolated measurements**: Each benchmark measures only the operation being tested

### Common Utilities

All benchmarks use shared utilities from `root.zig`:

- **Timer**: High-precision timing using `std.time.nanoTimestamp()`
- **AllocTracker**: Memory profiling allocator wrapper
- **Result**: Standardized result format with comparison functions

## Interpreting Results

### Performance Ratios

- **< 1.0x**: zv is faster
- **1.0x**: Equal performance
- **> 1.0x**: libev is faster

**Acceptable range:** Within 0.9x-1.1x (±10%) is considered comparable performance.

### Memory Metrics

zv tracks allocation patterns that libev (using malloc) doesn't report:

- **Allocations**: Number of allocation calls
- **Bytes allocated**: Total memory requested
- **Peak memory**: Maximum memory in use at once

Lower values indicate better memory efficiency.

### Throughput

Higher ops/sec is better. Compare:

- Absolute throughput for each library
- Relative performance (speedup/slowdown)
- How performance scales with load

## Expected Results

Based on design goals, we expect:

1. **Throughput**: Within 5-10% of libev (slightly slower acceptable)
2. **Memory**: 20-30% less memory due to better allocation patterns
3. **Scaling**: Similar O(n) characteristics for most operations
4. **Safety**: Compile-time guarantees without runtime cost

## Troubleshooting

### Build Errors

**Error: `ev.h` not found**
- Install libev development headers
- Check the library is in your system include path

**Error: undefined reference to `ev_*`**
- Ensure libev is properly linked
- Check `build.zig` has `linkSystemLibrary("ev")`

### Runtime Issues

**Benchmark crashes or hangs**
- Check ulimit for file descriptors: `ulimit -n` (should be ≥ 1024)
- Reduce number of watchers in benchmarks if hitting system limits

**Inconsistent results**
- Close other applications to reduce system noise
- Run benchmarks multiple times and average results
- Disable CPU frequency scaling if possible

## Contributing

When adding new benchmarks:

1. Follow the established pattern in existing benchmarks
2. Use common utilities (Timer, AllocTracker, Result)
3. Test multiple scenarios (simple, realistic, stress)
4. Include warmup runs for accurate timing
5. Document what the benchmark measures and why it matters
6. Update this README with the new benchmark

## Architecture

```
src/benchmarks/
├── root.zig                    # Common utilities and benchmark runner
├── main.zig                    # CLI entry point
├── libev_wrapper.{c,h}         # C wrapper for libev
├── loop_throughput.zig         # Loop iteration benchmarks
├── io_operations.zig           # IO watcher benchmarks
├── timer_accuracy.zig          # Timer precision benchmarks
├── memory_usage.zig            # Memory consumption benchmarks
├── scaling.zig                 # Scaling characteristics benchmarks
└── README.md                   # This file
```

## License

Same as zv - see repository root for license information.

## References

- [libev documentation](http://pod.tst.eu/http://cvs.schmorp.de/libev/ev.pod)
- [zv design goals](/README.md)
- [Zig language reference](https://ziglang.org/documentation/master/)
