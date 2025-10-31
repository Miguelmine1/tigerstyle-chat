//! Primary-specific VSR logic
//!
//! Handles normal-case protocol:
//! - Accept client requests
//! - Assign op numbers (monotonic, S1)
//! - Broadcast prepare to replicas
//! - Collect prepare_ok responses
//! - Send commit when quorum achieved (S2)
//!
//! Enforces invariants:
//! - S1: Log monotonicity (op numbers strictly increasing)
//! - S2: Quorum agreement (2/3 replicas = 2 out of 3)
//!
//! Reference: docs/protocol.md - Message Flow (Normal Case)

const std = @import("std");
const replica_mod = @import("replica.zig");
const message_mod = @import("message.zig");
const assert = std.debug.assert;

const Replica = replica_mod.Replica;
const Message = message_mod.Message;

/// Cluster size (3 replicas for VSR)
const CLUSTER_SIZE: usize = 3;

/// Quorum size (2/3 = 2 replicas)
const QUORUM_SIZE: usize = 2;

/// In-flight prepare tracking.
/// Tracks prepare_ok responses for pending operations.
pub const PrepareTracker = struct {
    op: u64,
    prepare_ok_count: u8, // Number of prepare_ok received
    prepare_ok_from: [CLUSTER_SIZE]bool, // Which replicas responded

    pub fn init(op: u64) PrepareTracker {
        return PrepareTracker{
            .op = op,
            .prepare_ok_count = 0,
            .prepare_ok_from = [_]bool{false} ** CLUSTER_SIZE,
        };
    }

    /// Record prepare_ok from a replica.
    pub fn recordPrepareOk(self: *PrepareTracker, replica_id: u8) void {
        assert(replica_id < CLUSTER_SIZE);
        if (!self.prepare_ok_from[replica_id]) {
            self.prepare_ok_from[replica_id] = true;
            self.prepare_ok_count += 1;
        }
    }

    /// Check if quorum achieved (S2: 2/3 replicas).
    pub fn hasQuorum(self: *const PrepareTracker) bool {
        return self.prepare_ok_count >= QUORUM_SIZE;
    }
};

/// Primary context for normal-case protocol.
/// Manages client request processing and prepare/commit protocol.
pub const Primary = struct {
    replica: *Replica,

    // In-flight prepares (bounded)
    // In production, would be a hash map op → tracker
    // For simplicity, tracking single in-flight op
    current_prepare: ?PrepareTracker,

    /// Initialize primary context.
    pub fn init(replica: *Replica) Primary {
        assert(replica.isPrimary()); // Must be primary
        return Primary{
            .replica = replica,
            .current_prepare = null,
        };
    }

    /// Accept client request and start prepare phase.
    /// S1: Assigns monotonic op number.
    pub fn acceptClientRequest(self: *Primary, msg: Message) !u64 {
        // Verify we're still primary
        if (!self.replica.isPrimary()) {
            return error.NotPrimary;
        }

        // S1: Assign monotonically increasing op number
        const op = self.assignOpNumber();

        // Write to WAL (durability)
        try self.replica.wal.append(op, &msg);

        // Apply to local state machine
        const room = try self.replica.getOrCreateRoom(msg.room_id);
        _ = try room.apply(op, msg);

        // Update commit_num (will broadcast after quorum)
        // For now, track as pending

        // Start tracking prepare_ok responses
        self.current_prepare = PrepareTracker.init(op);

        // Primary implicitly votes for itself
        self.current_prepare.?.recordPrepareOk(self.replica.config.replica_id);

        return op;
    }

    /// Assign next operation number (S1: monotonic).
    fn assignOpNumber(self: *Primary) u64 {
        const next_op = self.replica.wal.last_op + 1;
        // S1 invariant: op numbers strictly increasing
        assert(next_op > self.replica.wal.last_op);
        return next_op;
    }

    /// Record prepare_ok from replica.
    /// S2: Check if quorum achieved, trigger commit if so.
    pub fn handlePrepareOk(self: *Primary, from_replica: u8, op: u64) !bool {
        if (self.current_prepare == null) {
            return false; // No pending prepare
        }

        if (self.current_prepare.?.op != op) {
            return false; // Wrong op number
        }

        // Record response
        self.current_prepare.?.recordPrepareOk(from_replica);

        // S2: Check quorum (2/3 = 2 replicas)
        if (self.current_prepare.?.hasQuorum()) {
            // Quorum achieved - update commit_num
            self.replica.commit_num = op;

            // Clear tracker
            self.current_prepare = null;

            return true; // Quorum reached, should send commit
        }

        return false; // Still waiting for quorum
    }

    /// Get current in-flight prepare op (for testing).
    pub fn getCurrentOp(self: *const Primary) ?u64 {
        if (self.current_prepare) |tracker| {
            return tracker.op;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Primary: assign monotonic op numbers (S1)" {
    const allocator = std.testing.allocator;
    const test_wal = "test_primary_monotonic.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0, // Primary for view 0
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    var primary = Primary.init(&rep);

    var msg1 = Message{
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
    @memset(&msg1.body, 0);
    @memcpy(msg1.body[0..4], "test");
    msg1.zeroPadding();
    msg1.updateChecksum();

    const op1 = try primary.acceptClientRequest(msg1);
    try std.testing.expectEqual(@as(u64, 1), op1);

    var msg2 = msg1;
    msg2.msg_id = 101;
    msg2.sequence = 2;
    msg2.timestamp = 2000;
    msg2.updateChecksum();

    const op2 = try primary.acceptClientRequest(msg2);
    try std.testing.expectEqual(@as(u64, 2), op2);

    // S1: op2 > op1
    try std.testing.expect(op2 > op1);
}

test "Primary: prepare_ok quorum (S2)" {
    const allocator = std.testing.allocator;
    const test_wal = "test_primary_quorum.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0,
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    var primary = Primary.init(&rep);

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

    const op = try primary.acceptClientRequest(msg);
    try std.testing.expectEqual(@as(u64, 1), op);

    // Primary has already voted (1/3)
    try std.testing.expect(!primary.current_prepare.?.hasQuorum());

    // Replica 1 sends prepare_ok (2/3 = quorum!)
    const reached = try primary.handlePrepareOk(1, op);
    try std.testing.expect(reached);

    // commit_num updated
    try std.testing.expectEqual(@as(u64, 1), rep.commit_num);

    // Tracker cleared
    try std.testing.expect(primary.current_prepare == null);
}

test "Primary: quorum requires 2/3" {
    var tracker = PrepareTracker.init(1);

    // Start: 0/3
    try std.testing.expect(!tracker.hasQuorum());

    // Record from replica 0: 1/3
    tracker.recordPrepareOk(0);
    try std.testing.expect(!tracker.hasQuorum());

    // Record from replica 1: 2/3 = quorum!
    tracker.recordPrepareOk(1);
    try std.testing.expect(tracker.hasQuorum());
}

test "Primary: duplicate prepare_ok ignored" {
    var tracker = PrepareTracker.init(1);

    tracker.recordPrepareOk(0);
    try std.testing.expectEqual(@as(u8, 1), tracker.prepare_ok_count);

    // Duplicate from same replica - ignored
    tracker.recordPrepareOk(0);
    try std.testing.expectEqual(@as(u8, 1), tracker.prepare_ok_count);
}

test "Primary: integration simulation" {
    const allocator = std.testing.allocator;
    const test_wal = "test_primary_integration.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0, // Primary
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    var primary = Primary.init(&rep);

    // Simulate client request
    var msg = Message{
        .room_id = 1,
        .msg_id = 100,
        .author_id = 1,
        .parent_id = 0,
        .timestamp = 1000,
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

    // 1. Accept request (assigns op, writes WAL, applies locally)
    const op = try primary.acceptClientRequest(msg);
    try std.testing.expectEqual(@as(u64, 1), op);

    // 2. Broadcast prepare to replicas (simulated)
    // Primary has already voted

    // 3. Replica 1 responds with prepare_ok
    const quorum = try primary.handlePrepareOk(1, op);
    try std.testing.expect(quorum); // 2/3 reached!

    // 4. Commit_num updated
    try std.testing.expectEqual(@as(u64, 1), rep.commit_num);

    // 5. Send commit to replicas (simulated)
    // Would broadcast commit message here
}
