//! Intrusive min-heap for efficient timer management
//!
//! Uses intrusive indexing where each timer stores its heap position.
//! This provides O(log n) for all operations including specific timer removal.

const std = @import("std");
const TimerWatcher = @import("watcher/timer.zig").Watcher;

pub const TimerHeap = struct {
    items: std.ArrayList(*TimerWatcher),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TimerHeap {
        return .{
            .items = std.ArrayList(*TimerWatcher){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimerHeap) void {
        self.items.deinit(self.allocator);
    }

    pub fn count(self: *TimerHeap) usize {
        return self.items.items.len;
    }

    /// Insert timer into heap - O(log n)
    pub fn insert(self: *TimerHeap, timer: *TimerWatcher) !void {
        const idx = self.items.items.len;
        try self.items.append(self.allocator, timer);
        timer.heap_index = idx;
        self.siftUp(idx);
    }

    /// Peek at the next timer without removing - O(1)
    pub fn peek(self: *TimerHeap) ?*TimerWatcher {
        if (self.items.items.len == 0) return null;
        return self.items.items[0];
    }

    /// Remove and return the next timer - O(log n)
    pub fn removeMin(self: *TimerHeap) ?*TimerWatcher {
        if (self.items.items.len == 0) return null;
        
        const min = self.items.items[0];
        const last_idx = self.items.items.len - 1;
        
        if (last_idx == 0) {
            _ = self.items.pop();
            return min;
        }
        
        self.items.items[0] = self.items.items[last_idx];
        self.items.items[0].heap_index = 0;
        _ = self.items.pop();
        self.siftDown(0);
        
        return min;
    }

    /// Remove specific timer - O(log n) with intrusive index
    pub fn remove(self: *TimerHeap, timer: *TimerWatcher) void {
        if (timer.heap_index >= self.items.items.len) return;
        if (self.items.items[timer.heap_index] != timer) return;
        
        self.removeAt(timer.heap_index);
    }

    /// Update timer position after deadline change - O(log n) with intrusive index
    pub fn update(self: *TimerHeap, timer: *TimerWatcher) void {
        if (timer.heap_index >= self.items.items.len) return;
        if (self.items.items[timer.heap_index] != timer) return;
        
        self.siftUp(timer.heap_index);
        self.siftDown(timer.heap_index);
    }

    fn removeAt(self: *TimerHeap, idx: usize) void {
        if (idx >= self.items.items.len) return;
        
        const last_idx = self.items.items.len - 1;
        
        if (idx == last_idx) {
            _ = self.items.pop();
            return;
        }
        
        self.items.items[idx] = self.items.items[last_idx];
        self.items.items[idx].heap_index = idx;
        _ = self.items.pop();
        
        self.siftUp(idx);
        self.siftDown(idx);
    }

    fn findIndex(self: *TimerHeap, timer: *TimerWatcher) ?usize {
        for (self.items.items, 0..) |t, i| {
            if (t == timer) return i;
        }
        return null;
    }

    fn siftUp(self: *TimerHeap, start_idx: usize) void {
        var idx = start_idx;
        
        while (idx > 0) {
            const parent_idx = (idx - 1) / 2;
            
            if (!self.less(idx, parent_idx)) break;
            
            self.swap(idx, parent_idx);
            idx = parent_idx;
        }
    }

    fn siftDown(self: *TimerHeap, start_idx: usize) void {
        var idx = start_idx;
        const size = self.items.items.len;
        
        while (true) {
            const left = 2 * idx + 1;
            const right = 2 * idx + 2;
            var smallest = idx;
            
            if (left < size and self.less(left, smallest)) {
                smallest = left;
            }
            
            if (right < size and self.less(right, smallest)) {
                smallest = right;
            }
            
            if (smallest == idx) break;
            
            self.swap(idx, smallest);
            idx = smallest;
        }
    }

    fn less(self: *TimerHeap, i: usize, j: usize) bool {
        const a = self.items.items[i];
        const b = self.items.items[j];
        return a.deadline < b.deadline;
    }

    fn swap(self: *TimerHeap, i: usize, j: usize) void {
        const temp = self.items.items[i];
        self.items.items[i] = self.items.items[j];
        self.items.items[j] = temp;
        
        self.items.items[i].heap_index = i;
        self.items.items[j].heap_index = j;
    }
};

test "heap insert and peek" {
    const testing = std.testing;
    const Loop = @import("loop.zig");
    
    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();
    
    var heap = TimerHeap.init(testing.allocator);
    defer heap.deinit();
    
    const callback = struct {
        fn cb(_: *TimerWatcher) void {}
    }.cb;
    
    var t1 = TimerWatcher.init(&loop, 100, 0, callback);
    t1.deadline = 100;
    var t2 = TimerWatcher.init(&loop, 50, 0, callback);
    t2.deadline = 50;
    var t3 = TimerWatcher.init(&loop, 200, 0, callback);
    t3.deadline = 200;
    
    try heap.insert(&t1);
    try heap.insert(&t2);
    try heap.insert(&t3);
    
    try testing.expectEqual(3, heap.count());
    
    const min = heap.peek().?;
    try testing.expectEqual(50, min.deadline);
}

test "heap remove min" {
    const testing = std.testing;
    const Loop = @import("loop.zig");
    
    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();
    
    var heap = TimerHeap.init(testing.allocator);
    defer heap.deinit();
    
    const callback = struct {
        fn cb(_: *TimerWatcher) void {}
    }.cb;
    
    var t1 = TimerWatcher.init(&loop, 100, 0, callback);
    t1.deadline = 100;
    var t2 = TimerWatcher.init(&loop, 50, 0, callback);
    t2.deadline = 50;
    var t3 = TimerWatcher.init(&loop, 200, 0, callback);
    t3.deadline = 200;
    
    try heap.insert(&t1);
    try heap.insert(&t2);
    try heap.insert(&t3);
    
    const min1 = heap.removeMin().?;
    try testing.expectEqual(50, min1.deadline);
    
    const min2 = heap.removeMin().?;
    try testing.expectEqual(100, min2.deadline);
    
    const min3 = heap.removeMin().?;
    try testing.expectEqual(200, min3.deadline);
    
    try testing.expectEqual(null, heap.removeMin());
}

test "heap remove specific" {
    const testing = std.testing;
    const Loop = @import("loop.zig");
    
    var loop = try Loop.init(testing.allocator, .{});
    defer loop.deinit();
    
    var heap = TimerHeap.init(testing.allocator);
    defer heap.deinit();
    
    const callback = struct {
        fn cb(_: *TimerWatcher) void {}
    }.cb;
    
    var t1 = TimerWatcher.init(&loop, 100, 0, callback);
    t1.deadline = 100;
    var t2 = TimerWatcher.init(&loop, 50, 0, callback);
    t2.deadline = 50;
    var t3 = TimerWatcher.init(&loop, 200, 0, callback);
    t3.deadline = 200;
    
    try heap.insert(&t1);
    try heap.insert(&t2);
    try heap.insert(&t3);
    
    heap.remove(&t1);
    try testing.expectEqual(2, heap.count());
    
    const min = heap.peek().?;
    try testing.expectEqual(50, min.deadline);
}
