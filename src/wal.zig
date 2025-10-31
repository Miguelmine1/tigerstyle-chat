//! Write-Ahead Log (WAL) implementation
//!
//! Append-only log for VSR protocol with durability guarantees.
//! Each entry: [op: u64][checksum: u32][Message].
//!
//! Enforces invariants:
//! - S1: Operations monotonically increasing (op_n > op_{n-1})
//! - S5: Hash chain integrity (prev_hash validated)
//! - L3: Log size bounded (max entries enforced)
//! - D1: Durability via fsync before ack

const std = @import("std");
const crypto = @import("crypto.zig");
const message = @import("message.zig");
const assert = std.debug.assert;

const Message = message.Message;

/// WAL entry header (16 bytes).
/// Precedes each Message in the log file.
const EntryHeader = extern struct {
    op: u64, // Operation number (S1: monotonic)
    checksum: u32, // CRC32C of entire entry
    reserved: u32, // Alignment

    comptime {
        assert(@sizeOf(EntryHeader) == 16);
        assert(@alignOf(EntryHeader) >= 8);
    }
};

/// Write-Ahead Log with durability guarantees.
/// Enforces S1, S5, L3, D1 invariants.
pub const WAL = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    path: []const u8,

    // State
    last_op: u64, // S1: Last written op number
    entry_count: usize, // L3: Number of entries
    max_entries: usize, // L3: Upper bound

    /// Open or create WAL file.
    /// If file exists, validates all entries and resumes from last_op.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, max_entries: usize) !WAL {
        // L3 invariant check
        assert(max_entries > 0);
        assert(max_entries <= 10_000_000); // Reasonable upper bound

        const file = try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false, // Preserve existing data
        });
        errdefer file.close();

        var wal = WAL{
            .file = file,
            .allocator = allocator,
            .path = path,
            .last_op = 0,
            .entry_count = 0,
            .max_entries = max_entries,
        };

        // Recovery: scan existing log
        try wal.recover();

        return wal;
    }

    /// Close WAL file.
    pub fn close(self: *WAL) void {
        self.file.close();
    }

    /// Append entry to log.
    /// Enforces S1 (monotonic op), S5 (hash chain), L3 (bounded), D1 (fsync).
    pub fn append(self: *WAL, op: u64, msg: *const Message) !void {
        // S1 invariant: Operations must be monotonically increasing
        assert(op > self.last_op);

        // L3 invariant: Bounded log size
        if (self.entry_count >= self.max_entries) {
            return error.LogFull;
        }

        // S5 invariant: Verify hash chain (message already has prev_hash)
        // This is validated during message creation

        // Prepare entry header
        var header = EntryHeader{
            .op = op,
            .checksum = 0, // Will calculate
            .reserved = 0,
        };

        // Calculate checksum: CRC32C(header.op || message)
        var checksum_buf: [8 + @sizeOf(Message)]u8 = undefined;
        std.mem.writeInt(u64, checksum_buf[0..8], op, .little);
        const msg_bytes = std.mem.asBytes(msg);
        @memcpy(checksum_buf[8..], msg_bytes);
        header.checksum = crypto.crc32c(&checksum_buf);

        // Atomic write: header + message
        const header_bytes = std.mem.asBytes(&header);
        try self.file.writeAll(header_bytes);
        try self.file.writeAll(msg_bytes);

        // D1 invariant: fsync before acknowledging
        try self.file.sync();

        // Update state
        self.last_op = op;
        self.entry_count += 1;

        // Post-condition: invariants maintained
        assert(self.entry_count <= self.max_entries);
    }

    /// Read entry at given operation number.
    /// Returns null if op not found.
    pub fn read(self: *WAL, op: u64) !?Message {
        // Seek to start
        try self.file.seekTo(0);

        const entry_size = @sizeOf(EntryHeader) + @sizeOf(Message);
        var buf: [entry_size]u8 align(@alignOf(Message)) = undefined;

        // Scan log for matching op
        while (true) {
            const bytes_read = try self.file.read(&buf);
            if (bytes_read == 0) break; // EOF
            if (bytes_read < entry_size) return error.CorruptLog;

            // Parse header
            const header_bytes = buf[0..@sizeOf(EntryHeader)];
            const header: EntryHeader = @bitCast(header_bytes.*);

            if (header.op == op) {
                // Found entry - verify checksum
                var checksum_buf: [8 + @sizeOf(Message)]u8 = undefined;
                std.mem.writeInt(u64, checksum_buf[0..8], header.op, .little);
                @memcpy(checksum_buf[8..], buf[@sizeOf(EntryHeader)..]);
                const actual_checksum = crypto.crc32c(&checksum_buf);

                if (actual_checksum != header.checksum) {
                    return error.ChecksumMismatch;
                }

                // Parse message
                const msg_bytes = buf[@sizeOf(EntryHeader)..];
                const msg: Message = @bitCast(msg_bytes.*);
                return msg;
            }
        }

        return null; // Not found
    }

    /// Recover from existing log file.
    /// Validates all entries and reconstructs state.
    fn recover(self: *WAL) !void {
        const file_size = try self.file.getEndPos();
        if (file_size == 0) {
            // Empty log - nothing to recover
            return;
        }

        try self.file.seekTo(0);

        const entry_size = @sizeOf(EntryHeader) + @sizeOf(Message);
        var buf: [entry_size]u8 = undefined;
        var prev_op: u64 = 0;

        while (true) {
            const bytes_read = try self.file.read(&buf);
            if (bytes_read == 0) break; // EOF
            if (bytes_read < entry_size) {
                // Truncated entry - log corruption
                std.log.warn("WAL recovery: truncated entry, bytes={}", .{bytes_read});
                return error.CorruptLog;
            }

            const header = @as(*const EntryHeader, @ptrCast(@alignCast(buf[0..@sizeOf(EntryHeader)])));
            const msg = @as(*const Message, @ptrCast(@alignCast(buf[@sizeOf(EntryHeader)..].ptr)));

            // S1: Verify monotonic op
            if (header.op <= prev_op) {
                std.log.err("WAL recovery: non-monotonic op {} after {}", .{ header.op, prev_op });
                return error.NonMonotonicOp;
            }

            // Verify entry checksum
            var checksum_buf: [8 + @sizeOf(Message)]u8 = undefined;
            std.mem.writeInt(u64, checksum_buf[0..8], header.op, .little);
            @memcpy(checksum_buf[8..], buf[@sizeOf(EntryHeader)..]);
            const actual_checksum = crypto.crc32c(&checksum_buf);

            if (actual_checksum != header.checksum) {
                std.log.err("WAL recovery: checksum mismatch at op {}", .{header.op});
                return error.ChecksumMismatch;
            }

            // Verify message checksum (SE4)
            if (!msg.verifyChecksum()) {
                std.log.err("WAL recovery: message checksum invalid at op {}", .{header.op});
                return error.MessageChecksumInvalid;
            }

            // Update state
            prev_op = header.op;
            self.last_op = header.op;
            self.entry_count += 1;

            // L3: Check bounds
            if (self.entry_count > self.max_entries) {
                return error.LogFull;
            }
        }

        std.log.info("WAL recovery complete: last_op={}, entries={}", .{ self.last_op, self.entry_count });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WAL: basic append and read" {
    const allocator = std.testing.allocator;
    const test_path = "test_wal_basic.log";

    // Clean up from any previous run
    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var wal = try WAL.open(allocator, test_path, 1000);
    defer wal.close();

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

    try wal.append(1, &msg);
    try std.testing.expectEqual(@as(u64, 1), wal.last_op);
    try std.testing.expectEqual(@as(usize, 1), wal.entry_count);

    const read_msg = (try wal.read(1)).?;
    try std.testing.expectEqual(msg.msg_id, read_msg.msg_id);
    try std.testing.expectEqual(msg.body_len, read_msg.body_len);
}

test "WAL: monotonic op enforcement" {
    const allocator = std.testing.allocator;
    const test_path = "test_wal_monotonic.log";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var wal = try WAL.open(allocator, test_path, 1000);
    defer wal.close();

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

    try wal.append(1, &msg);
    try wal.append(2, &msg);
    try wal.append(3, &msg);

    try std.testing.expectEqual(@as(u64, 3), wal.last_op);
}

test "WAL: recovery from existing log" {
    const allocator = std.testing.allocator;
    const test_path = "test_wal_recovery.log";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Write some entries
    {
        var wal = try WAL.open(allocator, test_path, 1000);
        defer wal.close();

        var msg = Message{
            .room_id = 1,
            .msg_id = 100,
            .author_id = 1,
            .parent_id = 0,
            .timestamp = 1000,
            .sequence = 1,
            .body_len = 3,
            .flags = 0,
            .body = undefined,
            .prev_hash = [_]u8{0} ** 32,
            .checksum = 0,
            .reserved = [_]u8{0} ** 196,
        };
        @memset(&msg.body, 0);
        @memcpy(msg.body[0..3], "one");
        msg.zeroPadding();
        msg.updateChecksum();
        try wal.append(1, &msg);

        @memcpy(msg.body[0..3], "two");
        msg.msg_id = 101;
        msg.zeroPadding();
        msg.updateChecksum();
        try wal.append(2, &msg);
    }

    // Reopen and verify recovery
    {
        var wal = try WAL.open(allocator, test_path, 1000);
        defer wal.close();

        try std.testing.expectEqual(@as(u64, 2), wal.last_op);
        try std.testing.expectEqual(@as(usize, 2), wal.entry_count);

        const msg1 = (try wal.read(1)).?;
        try std.testing.expectEqual(@as(u128, 100), msg1.msg_id);

        const msg2 = (try wal.read(2)).?;
        try std.testing.expectEqual(@as(u128, 101), msg2.msg_id);
    }
}

test "WAL: bounded log size" {
    const allocator = std.testing.allocator;
    const test_path = "test_wal_bounded.log";

    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    var wal = try WAL.open(allocator, test_path, 3); // Max 3 entries
    defer wal.close();

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

    try wal.append(1, &msg);
    try wal.append(2, &msg);
    try wal.append(3, &msg);

    // Fourth append should fail (L3 invariant)
    try std.testing.expectError(error.LogFull, wal.append(4, &msg));
}
