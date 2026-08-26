# Thread-safety contract

zv follows the libev model: the loop is **not** a fully thread-safe API. One thread owns `run` and watcher lifetime. Other threads may only wake or query time.

This replaces the earlier investigation dump. Line numbers and “transparent thread-safety” claims in old drafts were wrong.

## Intended vs actual

| | Intended (libev-like) | Actual |
|--|----------------------|--------|
| `run` | One thread | `running` atomic; second caller gets `error.AlreadyRunning`. Nested `run` is not supported. |
| Cross-thread wake | `ev_async` / `ev_break` | `wakeup()` and `requestBreak()` write the internal waker (`eventfd` on Linux, pipe elsewhere) and are safe from any thread while the loop is alive. |
| Time | Cached loop time | `now()` / `updateTime()` use `std.atomic.Value`. |
| Watcher `start`/`stop`/`modify` | Loop thread only | `active` is a plain `bool`. Backend `add`/`remove`/`wait` are **not** under the loop mutex. Concurrent start/stop from another thread is a data race (poll/select mutate arrays; dispatch can UAF). Epoll/kqueue `add`/`remove` are userspace dirty marks; syscalls run in `reify`/`wait` on the loop thread. |
| Collections | Loop thread | `register*` / `unregister*` take a mutex (no-op if `builtin.single_threaded`). That mutex is for **loop-thread reentrancy** (prepare/check/timer callbacks that start/stop watchers), not a license to register from other threads. |
| Prepare/check | May start timers | Callbacks run **without** holding the mutex (`invokePhase` / `watcherAt`). They do **not** keep `until_done` alive (`pending_count` counts IO and timers only). |
| Signals | Async-signal-safe trampoline | Trampoline writes a signal byte to an **atomic write fd**. It does not load watcher fields. Registry is process-wide: one watcher per signal. |

## Safe from any thread

- `Loop.wakeup()`
- `Loop.requestBreak(.one \| .all)` (cleared at the start of the next `run`; `.all` equals `.one` because nested `run` is rejected)
- `Loop.now()` and `Loop.updateTime()`

`Waker` is internal (`src/waker.zig`); use the Loop methods.

## Loop thread only

- `run`, `deinit` / `destroy`
- Every watcher `start` / `stop` / `modify` / `again`
- Freeing a watcher (must outlive its callback)

Recommended: **one Loop per thread**. Cross-thread work: other threads call `wakeup` / `requestBreak` only.

## What the mutex does not cover

- `backend.add` / `remove` / `wait` (epoll `reify` issues `epoll_ctl`; poll/select user-space lists are not kernel-serialized with wait)
- Watcher `active`, `deadline`, `heap_index`
- Event dispatch (`user_data` pointer). Stopping a watcher from another thread while `dispatchIo` runs is use-after-free.

`pending_count` is a loop-thread keeper count (IO + timer). The internal waker is not a keeper.

## Signal handling

`src/watcher/signal.zig`:

1. Publish the write fd with release **before** `sigaction`.
2. Trampoline: acquire-load fd; if `>= 0`, `write` the signal number (raw `linux.write` on Linux).
3. `stop`: store invalid fd, clear registry, restore previous handler, then close the pipe.

A handler already in flight may still `write` a closing fd (`EBADF` / ignored). Fd-reuse of that write is a residual window. Duplicate `start` for the same signal uses `cmpxchg` on the registry.

## Tests

- `loop wakeup from another thread`
- `requestBreak from another thread`
- `waker concurrent wake`
- `now is readable from another thread`
- `prepare callback can stop another watcher` (no mutex deadlock)
- `timer again from callback does not double-insert`

## Residual risks

- `wakeup` / `requestBreak` after `deinit` (write to closed fd).
- In-flight signal write vs `stop` close (fd reuse).
- `poll` / `select` backends are not safe for concurrent `add` and `wait`.
- Signal-handler writes go through `sys.write` (`posix.system.write`), which is async-signal-safe.
