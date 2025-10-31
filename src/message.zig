//! Message types and serialization
//!
//! All messages are fixed-size extern structs for deterministic layout.
//! Total message size: 2368 bytes, 16-byte aligned.
//!
//! Enforces invariants:
//! - S5: Hash chain integrity (prev_hash)
//! - SE4: Checksum integrity (CRC32C)
//!
//! Reference: docs/message-formats.md

const std = @import("std");
const crypto = @import("crypto.zig");
const assert = std.debug.assert;

// ============================================================================
// Transport Header (128 bytes)
// ============================================================================

/// Foundation for all inter-node messages.
/// Includes checksum, authentication, and protocol metadata.
pub const TransportHeader = extern struct {
    magic: u32, // 0x54494752 ("TIGR")
    version: u16, // Protocol version = 1
    command: u8, // MessageCommand
    flags: u8, // Reserved; must be 0

    checksum: u32, // CRC32C(header[12..128] ++ body)
    size: u32, // Total size including header + body

    nonce: u64, // Monotonic per sender; replay protection (SE2)
    timestamp_us: u64, // Microseconds since UNIX epoch

    cluster_id: u128, // Cluster UUID (SE3 - prevents cross-cluster)

    view: u32, // Current view number (S4)
    op: u64, // Operation number / log index (S1)
    commit_num: u64, // Highest committed op number (S2)

    sender_id: u8, // Replica ID (0, 1, 2)
    sender_reserved: [7]u8, // Alignment padding

    reserved: [48]u8, // Future use; must be zero (padded to 128 bytes)

    /// Magic value for TigerChat protocol.
    pub const MAGIC: u32 = 0x54494752; // "TIGR"

    /// Current protocol version.
    pub const VERSION: u16 = 1;

    /// Calculate checksum for header + body.
    /// Checksum covers bytes [12..128] of header plus entire body.
    pub fn calculateChecksum(self: *const TransportHeader, body: []const u8) u32 {
        const header_bytes = std.mem.asBytes(self);
        // Skip first 12 bytes (magic, version, command, flags, checksum, size)
        const header_checksum_region = header_bytes[12..];

        // Compute checksum over header[12..] ++ body
        var buf: [128 - 12 + 8192]u8 = undefined; // Max body size for now
        const header_len = header_checksum_region.len;
        @memcpy(buf[0..header_len], header_checksum_region);
        @memcpy(buf[header_len .. header_len + body.len], body);

        return crypto.crc32c(buf[0 .. header_len + body.len]);
    }

    /// Verify checksum matches expected value.
    pub fn verifyChecksum(self: *const TransportHeader, body: []const u8) bool {
        const expected = self.checksum;
        const actual = self.calculateChecksum(body);
        return expected == actual;
    }

    /// Zero all padding and reserved fields for deterministic serialization.
    pub fn zeroPadding(self: *TransportHeader) void {
        @memset(&self.sender_reserved, 0);
        @memset(&self.reserved, 0);
    }
};

comptime {
    assert(@sizeOf(TransportHeader) == 128);
    assert(@alignOf(TransportHeader) >= 16);
    assert(@offsetOf(TransportHeader, "checksum") == 8);
}

// ============================================================================
// Message Command Enum
// ============================================================================

/// Message types for VSR protocol, client protocol, and operations.
pub const MessageCommand = enum(u8) {
    // VSR protocol
    prepare = 0x01,
    prepare_ok = 0x02,
    commit = 0x03,
    start_view_change = 0x04,
    do_view_change = 0x05,
    start_view = 0x06,
    request = 0x07,
    reply = 0x08,

    // Replica coordination
    ping = 0x10,
    pong = 0x11,
    request_snapshot = 0x12,
    snapshot_chunk = 0x13,

    // Client protocol
    send_message = 0x20,
    message_ack = 0x21,
    message_event = 0x22,
    subscribe_room = 0x23,
    snapshot_request = 0x24,

    // Operator commands
    drain_start = 0x30,
    drain_status = 0x31,

    _, // non-exhaustive for forward compatibility
};

// ============================================================================
// Core Message Struct (2368 bytes)
// ============================================================================

/// Core user-generated chat message; stored in WAL.
/// Enforces S5 (hash chain) and SE4 (checksum) invariants.
pub const Message = extern struct {
    room_id: u128, // Shard key
    msg_id: u128, // UUID v7 (time-ordered)
    author_id: u64, // User ID
    parent_id: u128, // 0 = top-level; else thread parent

    timestamp: u64, // Microseconds since epoch (S8 - monotonic)
    sequence: u64, // Client-side monotonic sequence

    body_len: u32, // Actual UTF-8 byte count
    flags: u32, // bit 0 = deleted, bit 1 = edited

    body: [2048]u8, // UTF-8 content (inline)

    prev_hash: [32]u8, // SHA256(previous Message) - S5 hash chain
    checksum: u32, // CRC32C(msg_id..body) - SE4 integrity
    reserved: [196]u8, // Padding to 2368 bytes

    /// Calculate checksum for this message.
    /// Covers: msg_id, author_id, parent_id, timestamp, sequence, body_len, flags, body, prev_hash.
    pub fn calculateChecksum(self: *const Message) u32 {
        const bytes = std.mem.asBytes(self);
        // Checksum covers everything except checksum and reserved fields
        const checksum_region_end = @offsetOf(Message, "checksum");
        return crypto.crc32c(bytes[0..checksum_region_end]);
    }

    /// Verify checksum matches expected value.
    pub fn verifyChecksum(self: *const Message) bool {
        const expected = self.checksum;
        const actual = self.calculateChecksum();
        return expected == actual;
    }

    /// Calculate SHA256 hash of entire message for hash chain.
    /// Used for prev_hash in next message (S5 invariant).
    pub fn calculateHash(self: *const Message) [32]u8 {
        const bytes = std.mem.asBytes(self);
        return crypto.sha256(bytes);
    }

    /// Zero all padding in body for deterministic serialization.
    pub fn zeroPadding(self: *Message) void {
        if (self.body_len < self.body.len) {
            @memset(self.body[self.body_len..], 0);
        }
        @memset(&self.reserved, 0);
    }

    /// Update checksum after modifying message.
    pub fn updateChecksum(self: *Message) void {
        self.checksum = self.calculateChecksum();
    }
};

comptime {
    assert(@sizeOf(Message) == 2368);
    assert(@alignOf(Message) >= 16);
}

// ============================================================================
// Tests
// ============================================================================

test "TransportHeader: size and alignment" {
    try std.testing.expectEqual(128, @sizeOf(TransportHeader));
    try std.testing.expect(@alignOf(TransportHeader) >= 16);
    try std.testing.expectEqual(8, @offsetOf(TransportHeader, "checksum"));
}

test "TransportHeader: checksum calculation" {
    var header = TransportHeader{
        .magic = TransportHeader.MAGIC,
        .version = TransportHeader.VERSION,
        .command = @intFromEnum(MessageCommand.prepare),
        .flags = 0,
        .checksum = 0, // Will be calculated
        .size = 128,
        .nonce = 12345,
        .timestamp_us = 1234567890,
        .cluster_id = 0xDEADBEEF,
        .view = 1,
        .op = 100,
        .commit_num = 99,
        .sender_id = 0,
        .sender_reserved = undefined,
        .reserved = undefined,
    };

    header.zeroPadding();

    const body = "test body";
    const checksum = header.calculateChecksum(body);

    header.checksum = checksum;
    try std.testing.expect(header.verifyChecksum(body));

    // Tamper with body
    try std.testing.expect(!header.verifyChecksum("tampered"));
}

test "Message: size and alignment" {
    try std.testing.expectEqual(2368, @sizeOf(Message));
    try std.testing.expect(@alignOf(Message) >= 16);
}

test "Message: checksum calculation" {
    var msg = Message{
        .room_id = 0x1234,
        .msg_id = 0x5678,
        .author_id = 999,
        .parent_id = 0,
        .timestamp = 1234567890,
        .sequence = 1,
        .body_len = 11,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32,
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };

    @memset(&msg.body, 0);
    @memcpy(msg.body[0..11], "hello world");
    msg.zeroPadding();

    msg.updateChecksum();
    try std.testing.expect(msg.verifyChecksum());

    // Tamper with body
    msg.body[0] = 'X';
    try std.testing.expect(!msg.verifyChecksum());
}

test "Message: hash chain" {
    var msg1 = Message{
        .room_id = 1,
        .msg_id = 100,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 1000,
        .sequence = 1,
        .body_len = 5,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32, // Root message
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };

    @memset(&msg1.body, 0);
    @memcpy(msg1.body[0..5], "first");
    msg1.zeroPadding();
    msg1.updateChecksum();

    // Calculate hash for msg1
    const hash1 = msg1.calculateHash();

    // Create msg2 with prev_hash = hash(msg1)
    var msg2 = Message{
        .room_id = 1,
        .msg_id = 101,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 2000,
        .sequence = 2,
        .body_len = 6,
        .flags = 0,
        .body = undefined,
        .prev_hash = hash1, // Hash chain link
        .checksum = 0,
        .reserved = [_]u8{0} ** 196,
    };

    @memset(&msg2.body, 0);
    @memcpy(msg2.body[0..6], "second");
    msg2.zeroPadding();
    msg2.updateChecksum();

    // Verify hash chain: msg2.prev_hash == hash(msg1)
    try std.testing.expectEqualSlices(u8, &hash1, &msg2.prev_hash);

    // Verify both messages have valid checksums
    try std.testing.expect(msg1.verifyChecksum());
    try std.testing.expect(msg2.verifyChecksum());
}

test "Message: zero padding for determinism" {
    var msg1 = Message{
        .room_id = 1,
        .msg_id = 1,
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

    // Fill body with garbage
    @memset(&msg1.body, 0xFF);
    @memcpy(msg1.body[0..5], "hello");
    msg1.zeroPadding(); // Should zero bytes [5..2048]
    msg1.updateChecksum();

    // Create identical message
    var msg2 = msg1;

    // Both should have identical serialization
    const bytes1 = std.mem.asBytes(&msg1);
    const bytes2 = std.mem.asBytes(&msg2);
    try std.testing.expectEqualSlices(u8, bytes1, bytes2);

    // Checksums should match
    try std.testing.expectEqual(msg1.checksum, msg2.checksum);
}

test "MessageCommand: enum values" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(MessageCommand.prepare));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(MessageCommand.send_message));
    try std.testing.expectEqual(@as(u8, 0x30), @intFromEnum(MessageCommand.drain_start));
}
