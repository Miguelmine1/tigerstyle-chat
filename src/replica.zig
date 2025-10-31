//! VSR Replica implementation
//!
//! State machine: Normal, ViewChange, Recovering
//!
//! Enforces invariants:
//! - SE2: Nonce anti-replay (per-sender monotonic nonce)
//! - SE3: Cluster isolation (reject wrong cluster_id)
//! - S1: Monotonic operations (via WAL)
//! - S3: Sequential commit ordering (via state machine)
//!
//! Reference: docs/protocol.md - VSR State Machine

const std = @import("std");
const wal_mod = @import("wal.zig");
const state_machine_mod = @import("state_machine.zig");
const message_mod = @import("message.zig");
const assert = std.debug.assert;

const WAL = wal_mod.WAL;
const RoomState = state_machine_mod.RoomState;
const Message = message_mod.Message;
const TransportHeader = message_mod.TransportHeader;

/// Replica state in VSR protocol.
pub const ReplicaState = enum {
    /// Normal operation: primary broadcasts prepare, replicas respond.
    normal,
    /// View change in progress: electing new primary.
    view_change,
    /// Recovering: replaying log to catch up.
    recovering,
};

/// Peer replica address.
pub const Peer = struct {
    replica_id: u8,
    // TODO(#15): Add network address when transport layer implemented
};

/// Replica configuration.
pub const ReplicaConfig = struct {
    cluster_id: u128, // SE3: Cluster isolation
    replica_id: u8, // This replica's ID (0, 1, or 2)
    peers: [2]Peer, // Other replicas in cluster

    /// Validate configuration.
    pub fn validate(self: *const ReplicaConfig) !void {
        // Replica ID must be 0, 1, or 2
        if (self.replica_id > 2) {
            return error.InvalidReplicaId;
        }

        // Peer IDs must be different from this replica and each other
        if (self.peers[0].replica_id == self.replica_id or
            self.peers[1].replica_id == self.replica_id or
            self.peers[0].replica_id == self.peers[1].replica_id)
        {
            return error.InvalidPeerConfiguration;
        }
    }
};

/// VSR Replica - core consensus participant.
pub const Replica = struct {
    config: ReplicaConfig,
    state: ReplicaState,

    // View state
    view: u32, // Current view number (S4)
    commit_num: u64, // Highest committed operation (S2)

    // Storage
    wal: WAL,
    rooms: std.AutoHashMap(u128, RoomState), // room_id → state

    // SE2: Nonce tracking for replay protection
    // Maps sender_id → last seen nonce
    nonce_table: std.AutoHashMap(u8, u64),

    allocator: std.mem.Allocator,

    /// Initialize replica.
    pub fn init(
        allocator: std.mem.Allocator,
        config: ReplicaConfig,
        wal_path: []const u8,
    ) !Replica {
        // Validate configuration
        try config.validate();

        // Open WAL (will recover if exists)
        var wal = try WAL.open(allocator, wal_path, 10_000_000);
        errdefer wal.close();

        var replica = Replica{
            .config = config,
            .state = .recovering, // Start in recovering state
            .view = 0,
            .commit_num = 0,
            .wal = wal,
            .rooms = std.AutoHashMap(u128, RoomState).init(allocator),
            .nonce_table = std.AutoHashMap(u8, u64).init(allocator),
            .allocator = allocator,
        };

        // Replay WAL to rebuild state
        try replica.recover();

        return replica;
    }

    /// Clean up resources.
    pub fn deinit(self: *Replica) void {
        self.wal.close();

        // Clean up all room states
        var room_iter = self.rooms.valueIterator();
        while (room_iter.next()) |room| {
            room.deinit();
        }
        self.rooms.deinit();

        self.nonce_table.deinit();
    }

    /// Recover replica state from WAL.
    /// Replays all committed operations to rebuild state machine.
    fn recover(self: *Replica) !void {
        // WAL has already validated and set last_op during open()
        // Now we need to replay all entries to rebuild room states

        // For now, mark as normal (will be enhanced when we implement recovery)
        self.state = .normal;
        self.commit_num = self.wal.last_op;
    }

    /// Verify message is from our cluster (SE3 invariant).
    pub fn verifyCluster(self: *const Replica, header: *const TransportHeader) bool {
        return header.cluster_id == self.config.cluster_id;
    }

    /// Verify and update nonce (SE2 invariant: replay protection).
    /// Returns true if nonce is valid (greater than last seen).
    pub fn verifyNonce(self: *Replica, sender_id: u8, nonce: u64) !bool {
        const last_nonce = self.nonce_table.get(sender_id) orelse 0;

        // SE2: Nonce must be monotonically increasing
        if (nonce <= last_nonce) {
            return false; // Replay attack detected
        }

        // Update nonce table
        try self.nonce_table.put(sender_id, nonce);
        return true;
    }

    /// Get or create room state.
    fn getOrCreateRoom(self: *Replica, room_id: u128) !*RoomState {
        const entry = try self.rooms.getOrPut(room_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = try RoomState.init(self.allocator, room_id);
        }
        return entry.value_ptr;
    }

    /// Transition to view change state.
    pub fn startViewChange(self: *Replica, new_view: u32) void {
        assert(new_view > self.view); // View must increase
        self.state = .view_change;
        self.view = new_view;
    }

    /// Complete view change and return to normal operation.
    pub fn completeViewChange(self: *Replica, new_view: u32) void {
        assert(new_view >= self.view);
        self.state = .normal;
        self.view = new_view;
    }

    /// Get current primary replica ID based on view.
    /// Primary = view % 3 (deterministic leader election).
    pub fn getPrimaryId(self: *const Replica) u8 {
        return @intCast(self.view % 3);
    }

    /// Check if this replica is currently primary.
    pub fn isPrimary(self: *const Replica) bool {
        return self.getPrimaryId() == self.config.replica_id;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Replica: initialization" {
    const allocator = std.testing.allocator;
    const test_wal = "test_replica_init.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = ReplicaConfig{
        .cluster_id = 0xDEADBEEF,
        .replica_id = 0,
        .peers = [_]Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var replica = try Replica.init(allocator, config, test_wal);
    defer replica.deinit();

    try std.testing.expectEqual(@as(u8, 0), replica.config.replica_id);
    try std.testing.expectEqual(@as(u128, 0xDEADBEEF), replica.config.cluster_id);
    try std.testing.expectEqual(ReplicaState.normal, replica.state);
}

test "Replica: cluster ID validation (SE3)" {
    const allocator = std.testing.allocator;
    const test_wal = "test_replica_cluster.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = ReplicaConfig{
        .cluster_id = 12345,
        .replica_id = 0,
        .peers = [_]Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var replica = try Replica.init(allocator, config, test_wal);
    defer replica.deinit();

    // Valid cluster ID
    var header = TransportHeader{
        .magic = TransportHeader.MAGIC,
        .version = TransportHeader.VERSION,
        .command = 0x01,
        .flags = 0,
        .checksum = 0,
        .size = 128,
        .nonce = 1,
        .timestamp_us = 1000,
        .cluster_id = 12345, // Correct
        .view = 0,
        .op = 1,
        .commit_num = 0,
        .sender_id = 1,
        .sender_reserved = undefined,
        .reserved = undefined,
    };
    header.zeroPadding();

    try std.testing.expect(replica.verifyCluster(&header));

    // Wrong cluster ID
    header.cluster_id = 99999;
    try std.testing.expect(!replica.verifyCluster(&header));
}

test "Replica: nonce replay protection (SE2)" {
    const allocator = std.testing.allocator;
    const test_wal = "test_replica_nonce.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0,
        .peers = [_]Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var replica = try Replica.init(allocator, config, test_wal);
    defer replica.deinit();

    // First nonce from sender 1
    try std.testing.expect(try replica.verifyNonce(1, 100));

    // Higher nonce - valid
    try std.testing.expect(try replica.verifyNonce(1, 101));

    // Same nonce - replay attack
    try std.testing.expect(!try replica.verifyNonce(1, 101));

    // Lower nonce - replay attack
    try std.testing.expect(!try replica.verifyNonce(1, 50));

    // Different sender - independent nonce
    try std.testing.expect(try replica.verifyNonce(2, 1));
}

test "Replica: view change transitions" {
    const allocator = std.testing.allocator;
    const test_wal = "test_replica_view.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0,
        .peers = [_]Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var replica = try Replica.init(allocator, config, test_wal);
    defer replica.deinit();

    try std.testing.expectEqual(ReplicaState.normal, replica.state);
    try std.testing.expectEqual(@as(u32, 0), replica.view);

    // Start view change
    replica.startViewChange(1);
    try std.testing.expectEqual(ReplicaState.view_change, replica.state);
    try std.testing.expectEqual(@as(u32, 1), replica.view);

    // Complete view change
    replica.completeViewChange(1);
    try std.testing.expectEqual(ReplicaState.normal, replica.state);
}

test "Replica: primary election (deterministic)" {
    const allocator = std.testing.allocator;
    const test_wal = "test_replica_primary.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0,
        .peers = [_]Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var replica = try Replica.init(allocator, config, test_wal);
    defer replica.deinit();

    // View 0: primary = 0 % 3 = 0
    replica.view = 0;
    try std.testing.expectEqual(@as(u8, 0), replica.getPrimaryId());
    try std.testing.expect(replica.isPrimary());

    // View 1: primary = 1 % 3 = 1
    replica.view = 1;
    try std.testing.expectEqual(@as(u8, 1), replica.getPrimaryId());
    try std.testing.expect(!replica.isPrimary());

    // View 2: primary = 2 % 3 = 2
    replica.view = 2;
    try std.testing.expectEqual(@as(u8, 2), replica.getPrimaryId());

    // View 3: primary = 3 % 3 = 0 (wraps around)
    replica.view = 3;
    try std.testing.expectEqual(@as(u8, 0), replica.getPrimaryId());
}

test "Replica: config validation" {
    const allocator = std.testing.allocator;
    const test_wal = "test_replica_config.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    // Valid config
    const valid_config = ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0,
        .peers = [_]Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };
    var replica = try Replica.init(allocator, valid_config, test_wal);
    replica.deinit();

    // Invalid: replica_id too high
    const bad_id = ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 3, // Must be 0-2
        .peers = [_]Peer{
            .{ .replica_id = 0 },
            .{ .replica_id = 1 },
        },
    };
    try std.testing.expectError(error.InvalidReplicaId, Replica.init(allocator, bad_id, test_wal));
}
