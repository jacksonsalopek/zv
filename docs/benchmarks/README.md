# zv vs libev benchmarks

The suite compares zv to system libev on the same machine. **It does not publish product scores.** Run it locally and read the methodology banner the harness prints.

## Quick start

```bash
# Requires system libev (benchmark-only; zv itself does not link libev)
zig build benchmark
zig build benchmark -- --name loop-throughput
zig build benchmark -- --help
```

Install libev first (`libev` on Arch, `libev-dev` on Debian/Ubuntu, `brew install libev` on macOS).

## What is measured

| Name | What it times | What it is not |
|------|----------------|----------------|
| `loop-throughput` | `run(.nowait)` call rate | Application events/sec. Empty loop does not poll. |
| `io-operations` | start/modify/stop **plus one nowait** so libev `fd_reify` applies kernel updates | A raw `ev_io_start` vs `Watcher.start` (those are not the same work). |
| `timer-accuracy` | start cost, 10ms delay, expired-timer dispatch | OS sleep granularity, not "library speed". |
| `memory-usage` | zv heap via a tracking allocator | libev `malloc` (not observed). |
| `scaling` | nowait cost vs watcher count | A scalability proof; fd limits skip large N. |

## Methodology (enforced in code)

- zv and the harness are **ReleaseFast**; the C wrapper is compiled `-O3 -DNDEBUG`.
- Both sides use **libc malloc** (`c_allocator` vs libev's `calloc`). GPA is not used.
- Timings are **median of samples after warmup**, using `CLOCK_MONOTONIC` (not wall-clock `nanoTimestamp`).
- Watcher **storage is allocated before** the timed region on both sides.
- zv uses `Backend.selectBest()` (epoll/kqueue/poll). **`select` wait is a stub** (always 0 events) and is not a libev comparison.
- libev backends are limited to epoll/kqueue/poll (no io_uring), matching zv.
- Failed start/stop/run **fails the process**; errors are not counted as success.
- No CPU pinning. Results are noisy and machine-specific.

## Known unfair or easy-to-misread cases

1. **Empty loop** — both libraries return without polling when there are no watchers. This is API overhead, not `epoll_wait`.
2. **IO add/modify/remove** — both libraries queue fd changes until `run` (`fd_reify`). Timing `ev_io_start` alone produced fake hundreds-of-millions ops/sec. The suite includes a nowait flush on both sides. Do not cite older add/remove ratios.
3. **Timer delay** — a 10ms one-shot is dominated by the OS. Early/late samples are all counted (including negative/early). Smaller delay is not "faster".
4. **Memory** — only zv heap is tracked. Struct `sizeof` is printed for both; that is not RSS.
5. **zv always has a waker fd** on the backend that libev does not. Idle-IO polls may differ by one fd.
6. **select backend** — `wait` always returns 0. Do not add or cite a select-vs-libev bench.

## Do not cite

These claims appeared in older docs and **are not supported** by the current suite:

- "30–45% better than libev"
- "21–34% faster"
- "20–30% less memory"
- canned ops/sec, ±150 ns timer accuracy, or 7% less memory examples

There is no CI job that records baseline numbers. If you need a number, run the suite and report the machine, OS, libev version, and the printed methodology.

## Layout

```
src/benchmarks/
├── infra.zig                # Timer, AllocTracker, median-of-samples
├── root.zig                 # CLI dispatch
├── main.zig
├── libev_wrapper.{c,h}
├── loop_throughput.zig
├── io_operations.zig
├── timer_accuracy.zig
├── memory_usage.zig
└── scaling.zig
```

`zig build test` runs `infra.zig` tests (no libev). Full benches are `zig build benchmark` only.
