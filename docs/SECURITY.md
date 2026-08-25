# Security Considerations for zv

This document describes the security model implied by the current code. It does not invent mitigations that are not implemented.

## Strengths

**Memory and types.** Callers pass a Zig allocator; the core library does not use `malloc` directly. Watcher callbacks are typed function pointers. Internal backend `user_data` is `?*anyopaque` set by zv when registering with the kernel, then recovered with `@ptrCast(@alignCast)` in `Loop.iterate`.

**Errors.** Syscall and registration failures use error unions. Cleanup paths may ignore errors (`catch {}`) when tearing down fds or handlers. On epoll/kqueue, kernel fd registration (`epoll_ctl` / `kevent`) is deferred until `run`; those errors return from `run`, not from `IoWatcher.start`. Duplicate IO watchers for the same fd still fail at `start` (`error.AlreadyExists`).

**Signals.** `signal.Watcher` uses `sigaction`, a self-pipe, and a process-wide atomic registry. The trampoline loads only an atomic write-fd and writes the signal number (raw `write` on Linux). It does not dereference the watcher. `stop`/`deinit` restore the previous handler. Duplicate watchers for the same signal return `error.SignalAlreadyWatched`. Windows returns `error.UnsupportedOnWindows`.

## Thread-safety contract

Matches `src/loop.zig` and [THREAD_SAFETY_ANALYSIS.md](./THREAD_SAFETY_ANALYSIS.md). This is the libev model, not a fully thread-safe loop.

**Safe from any thread** (while the loop is alive):

- `wakeup()` and `requestBreak()` (Linux `eventfd`, otherwise a pipe; extra wakes coalesce on eventfd).
- `now()` / `updateTime()` via `std.atomic.Value`.
- One thread in `run()` (`running` atomic; `error.AlreadyRunning` otherwise). Nested `run` is not supported.

**Loop thread only:**

- Watcher `start` / `stop` / `modify` / `again` (`active` is a plain `bool`; backend `add`/`remove`/`wait` are not under the loop mutex).
- `deinit` / `destroy`.
- Concurrent `start`/`stop` on the **same** watcher, or from a non-run thread, is unsupported.

The loop mutex serializes collection updates so prepare/check/timer callbacks can start/stop watchers without deadlock. It does **not** make `start`/`stop` safe from other threads (poll/select mutate user-space state; dispatch can UAF).

**Practical pattern:** one loop per thread. Other threads only `wakeup()` / `requestBreak()`. Watchers must stay alive until their callback returns.

The internal `Waker` type is not part of the public `root.zig` API.

## Resource limits

There is no `max_watchers` option. Watcher count is bounded by memory and OS file-descriptor limits (`ulimit -n`). The select backend rejects fds `>= 1024` (`error.FdTooLarge`).

Loop `Options.max_events` sizes the loop’s event buffer (default 64). The epoll backend also caps a wait at 64 events internally.

## Integer conversion

`@intCast` is used for fds (kqueue `ident`), timeouts (epoll/poll/`select` millisecond caps use `@min` where noted), and `time.now()` (`i128` → `u64`). Extreme user-supplied fds or timeouts can still overflow a cast. Nanosecond timestamps wrap after ~584 years.

## Pointer recovery

Event dispatch does:

```zig
const watcher: *IoWatcher = @ptrCast(@alignCast(user_data));
```

`user_data` is set by zv, not by application code. Corruption of that pointer is undefined behavior. Do not free a watcher while it may still be dispatched.

## Comparison with libev

Zig prevents many C memory-safety bugs at compile time. Signal handling is intended to be production-usable on Unix (self-pipe + `sigaction`). zv does not add sandboxing, fd quotas, or a multi-threaded `run`.

## Disclosure

Report vulnerabilities via GitHub issues or advisories on [jacksonsalopek/zv](https://github.com/jacksonsalopek/zv).
