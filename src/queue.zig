//! Bounded queue implementation
//!
//! Fixed-size ring buffer with compile-time capacity.
//! No heap allocation. All operations are O(1).
//!
//! Enforces L2 invariant: Queue depth bounded.
//! Overflow triggers assertion failure (fail-fast).

const std = @import("std");
const assert = std.debug.assert;

/// Bounded queue (ring buffer) with compile-time capacity.
/// Generic over element type T.
/// Enforces L2: Queue depth bounded (capacity fixed at comptime).
pub fn Queue(comptime T: type, comptime capacity: usize) type {
    // L2 invariant: Capacity must be > 0 and < max reasonable size
    comptime {
        assert(capacity > 0); // Must have at least 1 slot
        assert(capacity <= 1_000_000); // Reasonable upper bound
    }

    return struct {
        buffer: [capacity]T,
        head: usize, // Index of next item to pop
        tail: usize, // Index where next item will be pushed
        count: usize, // Number of items in queue

        const Self = @This();

        /// Initialize empty queue.
        pub fn init() Self {
            return Self{
                .buffer = undefined, // Will be filled on push
                .head = 0,
                .tail = 0,
                .count = 0,
            };
        }

        /// Returns true if queue is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Returns true if queue is full.
        pub fn isFull(self: *const Self) bool {
            return self.count == capacity;
        }

        /// Returns current number of items in queue.
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Returns maximum capacity of queue.
        pub fn cap() usize {
            return capacity;
        }

        /// Push item onto queue.
        /// Asserts if queue is full (L2: bounded depth).
        /// Fail-fast: overflow is a bug, not an expected condition.
        pub fn push(self: *Self, item: T) void {
            // L2 invariant check: queue depth bounded
            assert(!self.isFull()); // Overflow = bug

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % capacity; // Wraparound
            self.count += 1;

            // Post-condition: count should never exceed capacity
            assert(self.count <= capacity);
        }

        /// Pop item from queue.
        /// Returns null if queue is empty.
        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) {
                return null;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity; // Wraparound
            self.count -= 1;

            // Post-condition: count should be valid
            assert(self.count < capacity);
            return item;
        }

        /// Peek at front item without removing.
        /// Returns null if queue is empty.
        pub fn peek(self: *const Self) ?T {
            if (self.isEmpty()) {
                return null;
            }
            return self.buffer[self.head];
        }

        /// Clear all items from queue.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Queue: basic push and pop" {
    var q = Queue(u32, 4).init();

    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), q.len());

    q.push(10);
    q.push(20);
    q.push(30);

    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expect(!q.isEmpty());
    try std.testing.expect(!q.isFull());

    try std.testing.expectEqual(@as(u32, 10), q.pop().?);
    try std.testing.expectEqual(@as(u32, 20), q.pop().?);
    try std.testing.expectEqual(@as(u32, 30), q.pop().?);

    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "Queue: wraparound" {
    var q = Queue(u8, 3).init();

    // Fill queue
    q.push(1);
    q.push(2);
    q.push(3);
    try std.testing.expect(q.isFull());

    // Pop two items
    _ = q.pop();
    _ = q.pop();

    // Push two more (should wrap around)
    q.push(4);
    q.push(5);

    // Verify order: should be 3, 4, 5
    try std.testing.expectEqual(@as(u8, 3), q.pop().?);
    try std.testing.expectEqual(@as(u8, 4), q.pop().?);
    try std.testing.expectEqual(@as(u8, 5), q.pop().?);
    try std.testing.expect(q.isEmpty());
}

test "Queue: full capacity" {
    var q = Queue(u32, 3).init();

    q.push(100);
    q.push(200);
    q.push(300);

    try std.testing.expect(q.isFull());
    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expectEqual(@as(usize, 3), Queue(u32, 3).cap());

    // Pushing to full queue would trigger assertion in debug builds
    // Can't test this without catching assertion failure
}

test "Queue: peek" {
    var q = Queue(i32, 5).init();

    try std.testing.expectEqual(@as(?i32, null), q.peek());

    q.push(-10);
    q.push(-20);

    // Peek should not remove items
    try std.testing.expectEqual(@as(i32, -10), q.peek().?);
    try std.testing.expectEqual(@as(i32, -10), q.peek().?);
    try std.testing.expectEqual(@as(usize, 2), q.len());

    // Pop should remove peeked item
    try std.testing.expectEqual(@as(i32, -10), q.pop().?);
    try std.testing.expectEqual(@as(i32, -20), q.peek().?);
}

test "Queue: clear" {
    var q = Queue(u64, 10).init();

    q.push(1);
    q.push(2);
    q.push(3);
    try std.testing.expectEqual(@as(usize, 3), q.len());

    q.clear();
    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), q.len());
    try std.testing.expectEqual(@as(?u64, null), q.pop());
}

test "Queue: different types" {
    const Point = struct { x: i32, y: i32 };
    var q = Queue(Point, 2).init();

    q.push(.{ .x = 1, .y = 2 });
    q.push(.{ .x = 3, .y = 4 });

    const p1 = q.pop().?;
    try std.testing.expectEqual(@as(i32, 1), p1.x);
    try std.testing.expectEqual(@as(i32, 2), p1.y);

    const p2 = q.pop().?;
    try std.testing.expectEqual(@as(i32, 3), p2.x);
    try std.testing.expectEqual(@as(i32, 4), p2.y);
}

test "Queue: property test - FIFO order maintained" {
    var q = Queue(usize, 100).init();
    var prng = @import("crypto.zig").PRNG.init(42);

    // Random push/pop sequence
    var expected_front: usize = 0;
    var next_value: usize = 0;

    var ops: usize = 0;
    while (ops < 1000) : (ops += 1) {
        const should_push = prng.next() % 2 == 0;

        if (should_push and !q.isFull()) {
            q.push(next_value);
            next_value += 1;
        } else if (!q.isEmpty()) {
            const popped = q.pop().?;
            try std.testing.expectEqual(expected_front, popped);
            expected_front += 1;
        }
    }

    // Drain remaining items - should maintain FIFO order
    while (q.pop()) |item| {
        try std.testing.expectEqual(expected_front, item);
        expected_front += 1;
    }
}

test "Queue: no heap allocation" {
    // Queue uses only stack allocation
    var q = Queue(u32, 1000).init();
    q.push(1);
    _ = q.pop();
    // If we got here without allocator, queue is allocation-free
}
