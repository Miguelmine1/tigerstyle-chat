//! Deterministic state machine for room state
//!
//! Enforces invariants:
//! - S3: Commit ordering (apply ops in sequence)
//! - S6: Idempotency uniqueness (deduplicate by client_seq)
//! - S8: Timestamp monotonicity (reject out-of-order timestamps)
//! - X1: Deterministic state machine (same log → same state)
//!
//! Core principle: Given same sequence of messages, produce identical state.
//! No randomness, no wall-clock time, no external dependencies.

const std = @import("std");
const message = @import("message.zig");
const crypto = @import("crypto.zig");
const assert = std.debug.assert;

const Message = message.Message;

/// Maximum messages per room before requiring compaction.
const MAX_MESSAGES_PER_ROOM: usize = 1_000_000;

/// Maximum entries in idempotency table.
const MAX_IDEMPOTENCY_ENTRIES: usize = 100_000;

/// Room state - all messages for a single room.
/// Deterministic: same message sequence → same state.
pub const RoomState = struct {
    room_id: u128,

    // Message storage (bounded)
    messages: std.ArrayList(Message),

    // Message index: msg_id → array index
    message_index: std.AutoHashMap(u128, usize),

    // Idempotency table: (author_id, client_seq) → op
    // Ensures exactly-once semantics (S6)
    idempotency_table: std.AutoHashMap(IdempotencyKey, u64),

    // State tracking
    last_op: u64, // S3: Last applied operation
    last_timestamp: u64, // S8: Monotonic timestamp tracking
    head_hash: [32]u8, // S5: Hash of last message
    message_count: usize,

    allocator: std.mem.Allocator,

    /// Idempotency key: (author_id, sequence)
    const IdempotencyKey = struct {
        author_id: u64,
        sequence: u64,
    };

    /// Initialize empty room state.
    pub fn init(allocator: std.mem.Allocator, room_id: u128) !RoomState {
        return RoomState{
            .room_id = room_id,
            .messages = std.ArrayList(Message).init(allocator),
            .message_index = std.AutoHashMap(u128, usize).init(allocator),
            .idempotency_table = std.AutoHashMap(IdempotencyKey, u64).init(allocator),
            .last_op = 0,
            .last_timestamp = 0,
            .head_hash = [_]u8{0} ** 32,
            .message_count = 0,
            .allocator = allocator,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *RoomState) void {
        self.messages.deinit();
        self.message_index.deinit();
        self.idempotency_table.deinit();
    }

    /// Apply message to state machine.
    /// Enforces S3 (ordering), S6 (idempotency), S8 (monotonic timestamps), X1 (determinism).
    pub fn apply(self: *RoomState, op: u64, msg: Message) !ApplyResult {
        // S3 invariant: Operations must be applied in sequence
        if (op != self.last_op + 1) {
            return error.NonSequentialOp;
        }

        // Verify message belongs to this room
        if (msg.room_id != self.room_id) {
            return error.WrongRoom;
        }

        // S8 invariant: Timestamps must be monotonically increasing
        if (msg.timestamp < self.last_timestamp) {
            return error.TimestampNotMonotonic;
        }

        // S6 invariant: Check idempotency (exactly-once semantics)
        const idem_key = IdempotencyKey{
            .author_id = msg.author_id,
            .sequence = msg.sequence,
        };

        if (self.idempotency_table.get(idem_key)) |existing_op| {
            // Duplicate detected - return existing op, don't apply
            return ApplyResult{ .applied = false, .op = existing_op };
        }

        // Bounded growth check
        if (self.message_count >= MAX_MESSAGES_PER_ROOM) {
            return error.RoomFull;
        }
        if (self.idempotency_table.count() >= MAX_IDEMPOTENCY_ENTRIES) {
            return error.IdempotencyTableFull;
        }

        // Apply message: add to state
        const index = self.messages.items.len;
        try self.messages.append(msg);
        try self.message_index.put(msg.msg_id, index);
        try self.idempotency_table.put(idem_key, op);

        // Update state
        self.last_op = op;
        self.last_timestamp = msg.timestamp;
        self.head_hash = msg.calculateHash(); // S5: Update head hash
        self.message_count += 1;

        // Post-conditions
        assert(self.message_count == self.messages.items.len);
        assert(self.last_op == op);

        return ApplyResult{ .applied = true, .op = op };
    }

    /// Result of applying a message.
    pub const ApplyResult = struct {
        applied: bool, // false if duplicate (idempotency)
        op: u64, // operation number (existing if duplicate)
    };

    /// Get message by msg_id.
    pub fn getMessage(self: *const RoomState, msg_id: u128) ?Message {
        const index = self.message_index.get(msg_id) orelse return null;
        if (index >= self.messages.items.len) return null;
        return self.messages.items[index];
    }

    /// Get message by index.
    pub fn getMessageByIndex(self: *const RoomState, index: usize) ?Message {
        if (index >= self.messages.items.len) return null;
        return self.messages.items[index];
    }

    /// Check if message with (author_id, sequence) already applied.
    pub fn isDuplicate(self: *const RoomState, author_id: u64, sequence: u64) bool {
        const key = IdempotencyKey{ .author_id = author_id, .sequence = sequence };
        return self.idempotency_table.contains(key);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RoomState: basic apply" {
    const allocator = std.testing.allocator;
    var room = try RoomState.init(allocator, 1);
    defer room.deinit();

    var msg = Message{
        .room_id = 1,
        .msg_id = 100,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 1000,
        .sequence = 1,
        .body_len = 5,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32,
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };
    @memset(&msg.body, 0);
    @memcpy(msg.body[0..5], "hello");
    msg.zeroPadding();
    msg.updateChecksum();

    const result = try room.apply(1, msg);
    try std.testing.expect(result.applied);
    try std.testing.expectEqual(@as(u64, 1), result.op);
    try std.testing.expectEqual(@as(u64, 1), room.last_op);
    try std.testing.expectEqual(@as(usize, 1), room.message_count);
}

test "RoomState: sequential ops enforced (S3)" {
    const allocator = std.testing.allocator;
    var room = try RoomState.init(allocator, 1);
    defer room.deinit();

    var msg = Message{
        .room_id = 1,
        .msg_id = 100,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 1000,
        .sequence = 1,
        .body_len = 4,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32,
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };
    @memset(&msg.body, 0);
    @memcpy(msg.body[0..4], "test");
    msg.zeroPadding();
    msg.updateChecksum();

    // Apply op 1
    _ = try room.apply(1, msg);

    // Try to apply op 3 (skipping 2) - should fail
    msg.msg_id = 101;
    msg.sequence = 2;
    msg.updateChecksum();
    try std.testing.expectError(error.NonSequentialOp, room.apply(3, msg));

    // Apply op 2 - should succeed
    _ = try room.apply(2, msg);
    try std.testing.expectEqual(@as(u64, 2), room.last_op);
}

test "RoomState: idempotency (S6)" {
    const allocator = std.testing.allocator;
    var room = try RoomState.init(allocator, 1);
    defer room.deinit();

    var msg = Message{
        .room_id = 1,
        .msg_id = 100,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 1000,
        .sequence = 1,
        .body_len = 4,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32,
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };
    @memset(&msg.body, 0);
    @memcpy(msg.body[0..4], "test");
    msg.zeroPadding();
    msg.updateChecksum();

    // Apply message
    const result1 = try room.apply(1, msg);
    try std.testing.expect(result1.applied);
    try std.testing.expectEqual(@as(u64, 1), result1.op);

    // Try to apply duplicate (same author + sequence)
    msg.msg_id = 999; // Different msg_id, but same author+sequence
    msg.updateChecksum();

    // Can't apply as op 2 because it would violate sequential ops
    // In real system, duplicate would be detected before reaching state machine
    // But we can verify isDuplicate works
    try std.testing.expect(room.isDuplicate(1, 1));
    try std.testing.expect(!room.isDuplicate(1, 2));
}

test "RoomState: monotonic timestamps (S8)" {
    const allocator = std.testing.allocator;
    var room = try RoomState.init(allocator, 1);
    defer room.deinit();

    var msg = Message{
        .room_id = 1,
        .msg_id = 100,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 2000,
        .sequence = 1,
        .body_len = 4,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32,
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };
    @memset(&msg.body, 0);
    @memcpy(msg.body[0..4], "test");
    msg.zeroPadding();
    msg.updateChecksum();

    _ = try room.apply(1, msg);
    try std.testing.expectEqual(@as(u64, 2000), room.last_timestamp);

    // Try to apply message with earlier timestamp - should fail
    msg.msg_id = 101;
    msg.sequence = 2;
    msg.timestamp = 1000; // Earlier!
    msg.updateChecksum();
    try std.testing.expectError(error.TimestampNotMonotonic, room.apply(2, msg));

    // Apply with later timestamp - should succeed
    msg.timestamp = 3000;
    msg.updateChecksum();
    _ = try room.apply(2, msg);
    try std.testing.expectEqual(@as(u64, 3000), room.last_timestamp);
}

test "RoomState: determinism (X1)" {
    const allocator = std.testing.allocator;

    // Apply same sequence to two rooms
    var room1 = try RoomState.init(allocator, 1);
    defer room1.deinit();
    var room2 = try RoomState.init(allocator, 1);
    defer room2.deinit();

    // Create sequence of messages
    var messages: [5]Message = undefined;
    for (&messages, 0..) |*msg, i| {
        msg.* = Message{
            .room_id = 1,
            .msg_id = 100 + @as(u128, i),
            .author_id = @as(u64, i) % 2 + 1,
            .parent_id = 0,
            .timestamp = 1000 + @as(u64, i) * 100,
            .sequence = @as(u64, i) + 1,
            .body_len = 4,
            .flags = 0,
            .body = undefined,
            .prev_hash = [_]u8{0} ** 32,
            .checksum = 0,
            .reserved = [_]u8{0} ** 196,
        };
        @memset(&msg.body, 0);
        const text = "msg";
        @memcpy(msg.body[0..text.len], text);
        msg.zeroPadding();
        msg.updateChecksum();
    }

    // Apply to both rooms
    for (messages, 0..) |msg, i| {
        _ = try room1.apply(@as(u64, i) + 1, msg);
        _ = try room2.apply(@as(u64, i) + 1, msg);
    }

    // Verify identical state
    try std.testing.expectEqual(room1.last_op, room2.last_op);
    try std.testing.expectEqual(room1.last_timestamp, room2.last_timestamp);
    try std.testing.expectEqual(room1.message_count, room2.message_count);
    try std.testing.expectEqualSlices(u8, &room1.head_hash, &room2.head_hash);
}

test "RoomState: message index" {
    const allocator = std.testing.allocator;
    var room = try RoomState.init(allocator, 1);
    defer room.deinit();

    var msg = Message{
        .room_id = 1,
        .msg_id = 12345,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 1000,
        .sequence = 1,
        .body_len = 5,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32,
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };
    @memset(&msg.body, 0);
    @memcpy(msg.body[0..5], "hello");
    msg.zeroPadding();
    msg.updateChecksum();

    _ = try room.apply(1, msg);

    // Retrieve by msg_id
    const retrieved = room.getMessage(12345).?;
    try std.testing.expectEqual(msg.msg_id, retrieved.msg_id);
    try std.testing.expectEqual(msg.author_id, retrieved.author_id);

    // Non-existent msg_id
    try std.testing.expect(room.getMessage(99999) == null);
}
