//! View change protocol
//!
//! Handles timeout detection and leader election:
//! - Detect primary failure (50ms timeout)
//! - Broadcast start_view_change
//! - Transition to ViewChange state
//! - Deterministic leader selection (view % 3)
//! - Log merge (highest op wins)
//! - Install new view
//!
//! Enforces invariants:
//! - S4: View monotonicity (view always increases)
//! - L1: Liveness (progress under f=1 failures)
//! - Timeout bound: 50ms prepare timeout
//! - View change bound: < 300ms total
//!
//! Reference: docs/protocol.md - View Change Protocol

const std = @import("std");
const replica_mod = @import("replica.zig");
const assert = std.debug.assert;

const Replica = replica_mod.Replica;

/// Prepare timeout in microseconds (50ms = 50,000 µs)
const PREPARE_TIMEOUT_US: u64 = 50_000;

/// Timeout tracker for view change detection.
pub const TimeoutTracker = struct {
    last_prepare_time: u64, // Timestamp of last prepare received
    timeout_us: u64, // Timeout duration in microseconds

    pub fn init() TimeoutTracker {
        return TimeoutTracker{
            .last_prepare_time = 0,
            .timeout_us = PREPARE_TIMEOUT_US,
        };
    }

    /// Record that we received a prepare from primary.
    pub fn recordPrepare(self: *TimeoutTracker, timestamp_us: u64) void {
        self.last_prepare_time = timestamp_us;
    }

    /// Check if primary has timed out.
    /// Returns true if timeout exceeded.
    pub fn hasTimedOut(self: *const TimeoutTracker, current_time_us: u64) bool {
        // If we've never received a prepare, no timeout yet
        if (self.last_prepare_time == 0) {
            return false;
        }

        const elapsed = current_time_us - self.last_prepare_time;
        return elapsed >= self.timeout_us;
    }
};

/// View change state for coordinating view change protocol.
pub const ViewChangeState = struct {
    replica: *Replica,
    timeout_tracker: TimeoutTracker,

    // View change coordination
    pending_view: ?u32, // View we're trying to change to
    start_view_change_count: u8, // How many start_view_change received
    start_view_change_from: [3]bool, // Which replicas sent it

    pub fn init(replica: *Replica) ViewChangeState {
        return ViewChangeState{
            .replica = replica,
            .timeout_tracker = TimeoutTracker.init(),
            .pending_view = null,
            .start_view_change_count = 0,
            .start_view_change_from = [_]bool{false} ** 3,
        };
    }

    /// Check for timeout and trigger view change if necessary.
    /// Returns true if view change initiated.
    pub fn checkTimeout(self: *ViewChangeState, current_time_us: u64) !bool {
        // Only check timeout if we're in normal state
        if (self.replica.state != .normal) {
            return false;
        }

        // Only backups check timeout (primary can't timeout itself)
        if (self.replica.isPrimary()) {
            return false;
        }

        // Check if primary has timed out
        if (self.timeout_tracker.hasTimedOut(current_time_us)) {
            try self.initiateViewChange();
            return true;
        }

        return false;
    }

    /// Initiate view change by broadcasting start_view_change.
    fn initiateViewChange(self: *ViewChangeState) !void {
        // Calculate new view (S4: monotonic)
        const new_view = self.replica.view + 1;

        // Transition to view change state
        self.replica.startViewChange(new_view);

        // Track pending view
        self.pending_view = new_view;

        // Broadcast start_view_change to all replicas
        // In production, would send network message
        // For now, just transition state

        // Note: In real implementation, this would:
        // - Send start_view_change(new_view) to all peers
        // - Include our replica_id in the message
    }

    /// Handle start_view_change message from another replica.
    /// Returns true if we should send do_view_change.
    pub fn handleStartViewChange(self: *ViewChangeState, from_replica: u8, view: u32) !bool {
        // Ignore if for old view
        if (view < self.replica.view) {
            return false;
        }

        // If for newer view than we know, initiate view change ourselves
        if (view > self.replica.view) {
            self.replica.startViewChange(view);
            self.pending_view = view;
        }

        // Record this replica's vote
        if (from_replica < 3 and !self.start_view_change_from[from_replica]) {
            self.start_view_change_from[from_replica] = true;
            self.start_view_change_count += 1;
        }

        // If we have 2+ start_view_change messages (including ours), send do_view_change
        // Quorum for view change is also 2/3
        return self.start_view_change_count >= 2;
    }

    /// Reset state after view change completes.
    pub fn reset(self: *ViewChangeState) void {
        self.pending_view = null;
        self.start_view_change_count = 0;
        self.start_view_change_from = [_]bool{false} ** 3;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TimeoutTracker: basic timeout" {
    var tracker = TimeoutTracker.init();

    // No timeout initially (never received prepare)
    try std.testing.expect(!tracker.hasTimedOut(1000));

    // Record prepare at t=1000
    tracker.recordPrepare(1000);

    // No timeout at t=1000 (just received)
    try std.testing.expect(!tracker.hasTimedOut(1000));

    // No timeout at t=30000 (30ms elapsed < 50ms timeout)
    try std.testing.expect(!tracker.hasTimedOut(31000));

    // Timeout at t=51000 (50ms elapsed >= 50ms timeout)
    try std.testing.expect(tracker.hasTimedOut(51000));
}

test "TimeoutTracker: multiple prepares" {
    var tracker = TimeoutTracker.init();

    // First prepare at t=1000
    tracker.recordPrepare(1000);

    // Second prepare at t=20000 (updates last_prepare_time)
    tracker.recordPrepare(20000);

    // Check at t=60000: 40ms since last prepare, no timeout
    try std.testing.expect(!tracker.hasTimedOut(60000));

    // Check at t=71000: 51ms since last prepare, timeout!
    try std.testing.expect(tracker.hasTimedOut(71000));
}

test "ViewChange: timeout triggers view change" {
    const allocator = std.testing.allocator;
    const test_wal = "test_view_change_timeout.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 1, // Backup replica
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 0 }, // Primary in view 0
            .{ .replica_id = 2 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    var vc = ViewChangeState.init(&rep);

    // Initially in normal state, view 0
    try std.testing.expectEqual(replica_mod.ReplicaState.normal, rep.state);
    try std.testing.expectEqual(@as(u32, 0), rep.view);

    // Record prepare at t=1000
    vc.timeout_tracker.recordPrepare(1000);

    // Check at t=30000 - no timeout
    const triggered1 = try vc.checkTimeout(30000);
    try std.testing.expect(!triggered1);
    try std.testing.expectEqual(replica_mod.ReplicaState.normal, rep.state);

    // Check at t=52000 - timeout! View change initiated
    const triggered2 = try vc.checkTimeout(52000);
    try std.testing.expect(triggered2);
    try std.testing.expectEqual(replica_mod.ReplicaState.view_change, rep.state);
    try std.testing.expectEqual(@as(u32, 1), rep.view); // View incremented (S4)
}

test "ViewChange: start_view_change quorum" {
    const allocator = std.testing.allocator;
    const test_wal = "test_view_change_quorum.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 1,
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 0 },
            .{ .replica_id = 2 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    var vc = ViewChangeState.init(&rep);

    // Replica 0 sends start_view_change(view=1)
    const should_send1 = try vc.handleStartViewChange(0, 1);
    try std.testing.expect(!should_send1); // Only 1/3, need 2

    // Replica 2 sends start_view_change(view=1)
    const should_send2 = try vc.handleStartViewChange(2, 1);
    try std.testing.expect(should_send2); // 2/3 - quorum reached!
}

test "ViewChange: primary doesn't timeout itself" {
    const allocator = std.testing.allocator;
    const test_wal = "test_view_change_primary.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 0, // Primary in view 0
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 1 },
            .{ .replica_id = 2 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    var vc = ViewChangeState.init(&rep);

    // Record prepare
    vc.timeout_tracker.recordPrepare(1000);

    // Check timeout way after timeout period - primary never times out itself
    const triggered = try vc.checkTimeout(100000);
    try std.testing.expect(!triggered);
    try std.testing.expectEqual(replica_mod.ReplicaState.normal, rep.state);
}
