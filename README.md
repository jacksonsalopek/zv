# zv - Event Loop for Zig

A Zig port of a **subset** of [libev](http://software.schmorp.de/pkg/libev.html) with Zig allocators and error unions. zv is a library (not an executable) for asynchronous I/O on POSIX systems.

Requires **Zig 0.16.0** or later.

## Documentation

- **[API Documentation](./docs/README.md)** — types, watchers, backends, run modes
- **[Benchmarks](./docs/benchmarks/README.md)** — how to run the libev comparison suite
- **[Security](./docs/SECURITY.md)** — security model and thread-safety contract
- **[Examples](./examples/)** — source samples (`basic_example.zig`, `prepare_check_example.zig`)

Examples are not wired into `zig build`; copy from `examples/` or import the `zv` module in your own executable.

## Features

- **Backends** (automatic via `Backend.selectBest()`, or set `Loop.Options.backend`):
  - `epoll` on Linux
  - `kqueue` on BSD/macOS
  - `poll` as the default POSIX fallback
  - `select` exists as a kind but `wait` always returns 0 events — do not use it

- **Watcher types**: IO, timer, signal, prepare, check

- **Zig-only core**: no libc/libev dependency in the library itself (libev is used only by `zig build benchmark`)

- **Timer heap**: intrusive min-heap (`O(log n)` insert/remove/update)

## Installation

Requires Zig 0.16.0+. From your project:

```bash
zig fetch --save git+https://github.com/jacksonsalopek/zv
```

Then in `build.zig`:

```zig
const zv = b.dependency("zv", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zv", zv.module("zv"));
```

## Quick Start

`Loop.init` heap-allocates; pair it with `destroy()` (not `deinit()` alone). Watcher `init` takes `*Loop`, not `*Loop` taken by address:

```zig
const std = @import("std");
const zv = @import("zv");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const loop = try zv.Loop.init(allocator, .{});
    defer loop.destroy();

    var io_watcher = zv.io.Watcher.init(
        loop,
        std.posix.STDIN_FILENO,
        .read,
        handleIoEvent,
    );
    try io_watcher.start();
    defer io_watcher.stop() catch {};

    var timer = zv.timer.Watcher.init(
        loop,
        zv.time.seconds(5),
        zv.time.seconds(1),
        handleTimerEvent,
    );
    try timer.start();
    defer timer.stop();

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

## Loop

```zig
const loop = try zv.Loop.init(allocator, .{
    .backend = null, // null = Backend.selectBest()
    .max_events = 64,
    .initial_watcher_capacity = 32,
});
defer loop.destroy();

try loop.run(.until_done); // until no IO/timer watchers remain
try loop.run(.once);        // one iteration, may block
try loop.run(.nowait);      // one iteration, non-blocking

_ = loop.now();             // cached monotonic time (ns)
loop.updateTime();          // refresh cache
try loop.wakeup();          // interrupt a blocked wait (any thread)
loop.requestBreak(.one);    // leave run after this iteration (libev ev_break)
```

`run` returns `error.AlreadyRunning` if another call is in progress (nested `run` is not supported). `deinit` releases backends and the internal waker but does **not** free the `Loop` allocation; use `destroy` after `init`. Prepare and check watchers do not keep `until_done` running.

On epoll and kqueue, IO `start`/`stop`/`modify` update userspace interest only. Kernel registration happens in `run` before `wait` (libev `fd_reify`). A closed or epoll-incompatible fd succeeds at `start`; `run` returns the backend error. Two IO watchers on the same fd still fail at `start` (`error.AlreadyExists`). Poll and select apply interest immediately. The internal waker fd is registered at `Loop.init`.

## Watchers

```zig
// IO — callback: fn (*io.Watcher, Backend.EventMask) void
var io = zv.io.Watcher.init(loop, fd, .read, ioCallback); // .read, .write, .both
try io.start();
try io.modify(.both);
try io.stop();

// Timer — times in nanoseconds; repeat_ns = 0 is one-shot
var t = zv.timer.Watcher.init(loop, zv.time.seconds(5), 0, timerCallback);
try t.start();
_ = t.remaining();
try t.again(); // libev ev_timer_again: restart from repeat_ns, or stop if 0
t.stop();

// Signal — Unix only; one watcher per signal process-wide
var sig = zv.signal.Watcher.init(loop, std.posix.SIG.INT, signalCallback);
try sig.start();
defer sig.deinit(); // same as stop(); restores previous handler

fn signalCallback(watcher: *zv.signal.Watcher, signum: c_int) void {
    _ = watcher;
    _ = signum;
}

// Prepare / check — run before / after backend.wait()
var prepare = zv.prepare.Watcher.init(loop, prepareCallback);
try prepare.start();
defer prepare.stop();

var check = zv.check.Watcher.init(loop, checkCallback);
try check.start();
defer check.stop();
```

## Time

```zig
const five_sec = zv.time.seconds(5);
const hundred_ms = zv.time.milliseconds(100);
const five_hundred_us = zv.time.microseconds(500);
const now = zv.time.now();
const elapsed = zv.time.diff(later, earlier);
```

## Thread safety

`run()` is single-threaded (one caller at a time). `wakeup()`, `requestBreak()`, and `now()`/`updateTime()` are safe from other threads. Watcher `start`/`stop`/`modify` must run on the loop thread. Prefer one loop per thread. Details: [SECURITY.md](./docs/SECURITY.md).

## Testing and docs

```bash
zig build test
zig build docs
```

## Benchmarks

libev is required **only** for benchmarks. The library itself has no libev dependency.

```bash
zig build benchmark
zig build benchmark -- --name loop-throughput
zig build benchmark -- --help
```

Do not treat older README numbers as current; run the suite on your machine. See [benchmark documentation](./docs/benchmarks/README.md).

## Platform support

| Platform | Default backend | Notes |
|----------|-----------------|--------|
| Linux | epoll | Full |
| macOS / BSD | kqueue | Full |
| Other POSIX | poll | `select` available via `Options.backend` |
| Windows | — | Not supported (`signal` returns `error.UnsupportedOnWindows`; `selectBest` would pick `poll`) |

## Comparison with libev

zv is a Zig-idiomatic subset, not a C ABI or drop-in replacement.

| | libev | zv |
|--|-------|-----|
| Language | C | Zig |
| Error handling | errno | error unions |
| Time | `ev_tstamp` (seconds, `double`) | `u64` nanoseconds |
| Backends | epoll, kqueue, poll, select, plus others | epoll, kqueue, poll; `select` is a stub (`wait` is unimplemented) |
| Watchers | io, timer, periodic, signal, child, stat, idle, prepare, check, embed, fork, cleanup, async | io, timer, signal, prepare, check |
| `ev_run` flags | 0 / `EVRUN_ONCE` / `EVRUN_NOWAIT` | `.until_done` / `.once` / `.nowait` |
| `ev_break` | `EVBREAK_ONE` / `EVBREAK_ALL` | `requestBreak(.one \| .all)` (no nested `run`, so both are equivalent) |
| IO events | `EV_READ` / `EV_WRITE` bitset; many watchers per fd | `.read` / `.write` / `.both`; **one watcher per fd** |
| Timers | oneshot + repeating; `ev_timer_again` | same; `again()` matches libev (`repeat == 0` stops) |
| Signals | multiple watchers per signal per loop | one watcher per signal, process-wide |
| Prepare/check | count as active (keep `ev_run` alive) | do **not** keep `until_done` running |
| Priority / multiplicity default loop | `ev_set_priority`, `ev_default_loop` | not provided (create loops explicitly) |
| `ev_suspend` / `ev_resume` | yes | not provided |
| Dependencies | libc | Zig std only |

Not ported (explicitly out of scope): periodic, child, stat, idle, embed, fork, cleanup, async, and extra libev backends.

## License

MIT License — see [LICENSE](./LICENSE).
