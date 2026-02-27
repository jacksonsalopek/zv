# Security Considerations for zv

This document outlines security considerations when using zv in production systems.

## Current Security Posture

### ✅ Strong Points

**1. Memory Safety**
- Zig's compile-time checks prevent many memory errors
- Explicit allocator management (no hidden allocations)
- No use-after-free possible with proper ownership
- Bounds checking on array access

**2. Error Handling**
- All errors explicitly handled via Zig error unions
- No silent failures or error suppression
- Syscall errors properly propagated

**3. Type Safety**
- Strong typing prevents many common C vulnerabilities
- No void* casting without explicit user acknowledgment
- Compile-time validation of data structure layouts

## ⚠️ Potential Security Concerns

### 1. Integer Overflow in Type Conversions

**Location**: Multiple `@intCast` operations throughout codebase

**Risk**: File descriptor or timeout values could overflow on conversion

```zig
// backend/kqueue.zig:56
.ident = @intCast(fd),  // fd_t -> kevent.ident

// backend/epoll.zig:83
break :blk @intCast(@min(ms, std.math.maxInt(i32)));  // Protected

// time.zig:12
return @intCast(std.time.nanoTimestamp());  // i128 -> u64
```

**Mitigation**:
- Most casts are protected with `@min(value, maxInt(T))`
- File descriptors are system-limited (<1M on most systems)
- Consider adding runtime validation for user-provided values

**Severity**: Low (system limits prevent most overflow scenarios)

### 2. Incomplete Signal Handling Implementation

**Location**: `src/watcher/signal.zig`

**Issue**: Signal watcher creates pipe but **doesn't actually register signal handlers**

```zig
pub fn start(self: *Watcher) !void {
    const fds = try std.posix.pipe();  // Creates pipe
    // ❌ Missing: sigaction() to register signal handler
    // ❌ Missing: Write to pipe from signal handler
    self.pipe_fds = .{ .read = fds[0], .write = fds[1] };
}
```

**Risk**:
- Signal watcher appears to work but never receives signals
- False sense of security in signal-handling code
- Resource leak (pipe fds not used)

**Mitigation Needed**:
- Implement proper signal handler registration using `sigaction()`
- Use self-pipe trick to make signals work with event loop
- Document that signal handling is not production-ready

**Severity**: **High** (broken functionality, misleading API)

### 3. File Descriptor Exhaustion

**Risk**: No limit on number of watchers

**Attack Vector**:
```zig
// Attacker could exhaust file descriptors
while (true) {
    var watcher = io.Watcher.init(&loop, fd, .read, callback);
    try watcher.start();  // Eventually hits ulimit
}
```

**Mitigation**:
- Document maximum watcher limits
- Consider adding optional max_watchers limit in Loop.Options
- Rely on OS ulimit as defense

**Severity**: Medium (DoS possible, but requires application misuse)

### 4. Pointer Cast Safety

**Location**: Event dispatch in `loop.zig`

```zig
const watcher: *IoWatcher = @ptrCast(@alignCast(user_data));
```

**Risk**: If user_data is corrupted, this could crash or execute arbitrary code

**Mitigation**:
- user_data is always set by zv internally (not user-provided)
- Alignment is guaranteed by allocator
- Type is guaranteed by registration flow

**Severity**: Low (internal-only, controlled flow)

### 5. Time-Based Integer Overflow

**Location**: `src/time.zig`

```zig
pub fn now() Timestamp {
    return @intCast(std.time.nanoTimestamp());  // i128 -> u64
}
```

**Risk**: Year 2554 problem (u64 nanoseconds overflow in ~584 years)

**Mitigation**:
- Sufficient for practical use
- Document the limitation
- Consider i64 for relative time calculations

**Severity**: Very Low (584 years until overflow)

### 6. Race Conditions in Signal Handler (if implemented)

**Future Risk**: When signal handling is properly implemented

**Issue**: Signal handlers run asynchronously and have restrictions:
- Only async-signal-safe functions allowed
- Cannot allocate memory
- Cannot acquire locks
- Must use atomic operations

**Mitigation**:
- Use self-pipe trick (write single byte to pipe)
- Keep signal handler minimal
- Document signal safety requirements

**Severity**: **High** (when signal handling is implemented)

## Recommended Actions

### Critical Priority

1. **Fix or Remove Signal Watcher**
   - Current implementation is non-functional and misleading
   - Either implement properly or document as experimental

2. **Validate Signal Handler Safety** (when implemented)
   - Ensure async-signal-safe operations only
   - Use atomic operations for shared state
   - Comprehensive testing

### Medium Priority

3. **Add Watcher Limit Option**
   ```zig
   pub const Options = struct {
       max_watchers: ?usize = null,  // Optional limit
       // ...
   };
   ```

4. **Document Security Limits**
   - Maximum file descriptors (OS-dependent)
   - Timer overflow behavior (year 2554)
   - Thread safety (currently single-threaded only)

### Low Priority

5. **Consider Defensive Casts**
   ```zig
   // Instead of @intCast(fd)
   const ident: usize = std.math.cast(usize, fd) orelse return error.FdTooLarge;
   ```

6. **Add Fuzzing Tests**
   - Test with extreme values
   - Random fd values
   - Very large timeout values

## Thread Safety

**Current State**: ❌ **Not thread-safe**

- No synchronization primitives
- Shared mutable state (Loop, watchers)
- Syscalls not atomic across threads

**If multi-threading is needed:**
- One Loop per thread (recommended)
- External synchronization if sharing Loop
- Document thread-safety guarantees explicitly

## Resource Limits

**System Limits Applied:**
- File descriptors: Limited by `ulimit -n` (typically 1024-65535)
- Memory: Limited by system RAM
- Timers: Limited only by memory

**Recommendations:**
- Document expected resource usage
- Provide examples of resource cleanup
- Test with resource exhaustion scenarios

## Comparison with libev Security

| Aspect | libev | zv |
|--------|-------|-----|
| Memory safety | Manual (unsafe) | Zig-guaranteed (safe) |
| Buffer overflows | Possible | Prevented by compiler |
| Use-after-free | Possible | Prevented by compiler |
| Integer overflows | Unchecked | Mostly checked |
| Signal handling | Production-ready | **Incomplete** ⚠️ |
| Type safety | Weak (void*) | Strong (generic types) |

## Disclosure

If you discover security vulnerabilities in zv, please report them via GitHub issues or security advisory.

## Conclusion

**Overall Security**: Good for IO and timer workloads, **not production-ready for signal handling**.

**Strengths**:
- Zig's memory safety eliminates entire classes of vulnerabilities
- Explicit error handling
- No hidden allocations or state

**Weaknesses**:
- Signal handling incomplete/non-functional
- No thread safety guarantees
- Some unchecked integer conversions

zv is **safer than libev** for memory-related vulnerabilities but requires signal handling completion before production use with signals.
