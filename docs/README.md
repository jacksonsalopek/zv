# zv Documentation

**zv** is a Zig event-loop library inspired by libev. It ports a subset of libev’s watchers and backends; it is not a C-compatible drop-in.

- **[Main README](../README.md)** — overview, install, quick start
- **[Security and thread safety](./SECURITY.md)**
- **[Benchmarks](./benchmarks/README.md)** — how to run the comparison suite

## Project structure

```
zv/
├── src/
│   ├── root.zig              # Public API
│   ├── loop.zig              # Loop, run modes, wakeup
│   ├── backend.zig           # Backend vtable and selectBest()
│   ├── time.zig              # Monotonic time helpers
│   ├── sys.zig               # POSIX syscall wrappers (Zig 0.16)
│   ├── timer_heap.zig        # Intrusive min-heap (internal)
│   ├── waker.zig             # Cross-thread wakeup (internal)
│   ├── backend/
│   │   ├── epoll.zig
│   │   ├── kqueue.zig
│   │   ├── poll.zig
│   │   └── select.zig
│   ├── watcher/
│   │   ├── io.zig
│   │   ├── timer.zig
│   │   ├── signal.zig
│   │   ├── prepare.zig
│   │   └── check.zig
│   └── benchmarks/           # zig build benchmark (needs libev)
├── docs/
└── examples/
```

`Waker` and `TimerHeap` are not exported from `src/root.zig`. Use `Loop.wakeup()` for cross-thread interrupt.

## Public API

Exported from `@import("zv")`:

| Symbol | Role |
|--------|------|
| `Loop` | Event loop (`init` returns `*Loop`) |
| `Backend` | Kind, `Event`/`EventMask`/`Interest`, `selectBest()`, `init` |
| `time` | `Timestamp`, `now`, `seconds`/`milliseconds`/`microseconds`, `diff` |
| `sys` | POSIX helpers (`pipe`, `close`, `read`, `write`) after Zig 0.16 |
| `io.Watcher`, `io.Event` | FD watchers (`.read` / `.write` / `.both`) |
| `timer.Watcher` | One-shot or repeating timers |
| `signal.Watcher` | Unix signals (self-pipe + `sigaction`) |
| `prepare.Watcher` | Callbacks before `backend.wait()` |
| `check.Watcher` | Callbacks after `backend.wait()` |

## Loop

```zig
pub const Options = struct {
    backend: ?Backend.Kind = null,       // null → Backend.selectBest()
    max_events: usize = 64,
    initial_watcher_capacity: usize = 32,
};

pub const RunMode = enum { until_done, once, nowait };
```

- `init(allocator, options) !*Loop` — heap-allocates the loop, backend, event buffer, and internal waker.
- `destroy()` — `deinit()` then frees the `Loop`. **Call this after `init`.**
- `deinit()` — releases backend, waker, collections; does not `destroy` the `Loop` pointer.
- `run(mode) !void` — `error.AlreadyRunning` if already in `run` (no nested `run`).
- `now()` / `updateTime()` — cached monotonic nanoseconds (`std.atomic.Value`).
- `wakeup() !void` — write to the internal waker (eventfd on Linux, pipe elsewhere).
- `requestBreak(how) void` — libev `ev_break`; `.one` and `.all` are equivalent because nested `run` is rejected. Break state is cleared at the start of the next `run`. Thread-safe (wakes a blocked wait).

`until_done` continues while the loop still has registered IO entries or timers. Prepare/check watchers alone do not keep the loop running. The internal waker fd is not counted as a user watcher.

Timers that expire during `backend.wait` are invoked in the same iteration (after I/O), matching libev `EVRUN_ONCE`.

`selectBest()`:

- Linux → `.epoll`
- macOS, iOS, tvOS, watchOS, visionOS, FreeBSD, NetBSD, OpenBSD, DragonFly → `.kqueue`
- everything else → `.poll`

Manual `.epoll` / `.kqueue` on an unsupported OS returns `error.UnsupportedBackend`. `.select` is never chosen automatically. Its `wait` always returns 0 events; do not use it for I/O.

Epoll/kqueue store watcher pointers in kernel event data (`epoll_data.ptr` / `udata`). Poll and select keep a user-data map.

## Watchers

All watchers are stack- or caller-allocated structs. They must outlive the callback that uses them. `start` is a no-op if already active.

### IO

```zig
var w = zv.io.Watcher.init(loop, fd, .read, callback);
try w.start();
try w.modify(.both); // error.NotActive if not started
try w.stop();        // !void
```

Callback: `fn (watcher: *zv.io.Watcher, events: zv.Backend.EventMask) void`.

`EventMask` fields: `read`, `write`, `error_`, `hangup`.

Unlike libev, only **one** IO watcher may be active per file descriptor (checked at `start` with `error.AlreadyExists`).

On epoll and kqueue, `start`/`stop`/`modify` mark the fd dirty in userspace. Kernel updates run in `Loop.run` before `wait` (libev `fd_reify`). `epoll_ctl` / bad-fd errors therefore return from `run`, not from `start`. Poll and select apply interest immediately. The internal waker fd is registered at `Loop.init`.

### Timer

```zig
var t = zv.timer.Watcher.init(loop, timeout_ns, repeat_ns, callback);
try t.start();
_ = t.remaining(); // 0 if inactive or overdue
try t.again();     // ev_timer_again: restart from repeat_ns; oneshot is stopped
t.stop();          // void; one-shot timers also stop themselves after fire
```

Callback: `fn (watcher: *zv.timer.Watcher) void`. Repeating timers reschedule in `invoke` using `loop.now() + repeat_ns`. `again()` on an inactive oneshot is a no-op; on an active oneshot it stops the timer.

### Signal

Unix only. `start` returns `error.UnsupportedOnWindows`, `error.InvalidSignal` (signum out of `0 .. 63`), or `error.SignalAlreadyWatched` (one watcher per signal in the process).

```zig
var s = zv.signal.Watcher.init(loop, std.posix.SIG.INT, callback);
try s.start();
defer s.deinit(); // stop + restore previous sigaction
```

Callback: `fn (watcher: *zv.signal.Watcher, signum: c_int) void`.

### Prepare and check

```zig
var p = zv.prepare.Watcher.init(loop, prepareCb);
try p.start();
defer p.stop();

var c = zv.check.Watcher.init(loop, checkCb);
try c.start();
defer c.stop();
```

Callbacks take only `*Watcher`. They run every iteration that reaches poll (prepare before `wait`, check after).

## Time

`time.Timestamp` is `u64` nanoseconds. `now()` reads `CLOCK_MONOTONIC`. `diff` treats wraparound as unsigned distance.

## Thread safety

See [SECURITY.md](./SECURITY.md). Short version: one thread calls `run`; other threads may `wakeup` / `requestBreak` / `now`; do not `start`/`stop` watchers from another thread.

## libev subset

Implemented: io, timer, signal, prepare, check; backends epoll, kqueue, poll; run modes analogous to default / `EVRUN_ONCE` / `EVRUN_NOWAIT`; `requestBreak` analogous to `ev_break`.

Not implemented: periodic, child, stat, idle, embed, fork, cleanup, async; extra libev backends; C ABI; watcher priority; `ev_suspend`/`ev_resume`; default loop; nested `ev_run`.

Intentional differences: prepare/check do not keep `until_done` alive; one IO watcher per fd; one signal watcher per signal process-wide; times are nanoseconds; callbacks are Zig-typed (no `EV_P` / `revents` int).

The `select` backend exists as an API choice but `wait` is unimplemented (always returns 0 events). Do not use it for production I/O.

## Building

```bash
zig build
zig build test
zig build docs
zig build benchmark   # requires system libev
```

## License

MIT — see repository `LICENSE`.
