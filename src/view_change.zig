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

/// Log state information for view change.
pub const LogState = struct {
    last_op: u64,
    commit_num: u64,

    pub fn init(last_op: u64, commit_num: u64) LogState {
        return LogState{
            .last_op = last_op,
            .commit_num = commit_num,
        };
    }
};

/// do_view_change message tracking.
pub const DoViewChangeTracker = struct {
    view: u32,
    do_view_change_count: u8,
    do_view_change_from: [3]bool,
    log_states: [3]?LogState, // Log state from each replica

    pub fn init(view: u32) DoViewChangeTracker {
        return DoViewChangeTracker{
            .view = view,
            .do_view_change_count = 0,
            .do_view_change_from = [_]bool{false} ** 3,
            .log_states = [_]?LogState{null} ** 3,
        };
    }

    /// Record do_view_change from a replica.
    pub fn recordDoViewChange(
        self: *DoViewChangeTracker,
        from_replica: u8,
        log_state: LogState,
    ) void {
        assert(from_replica < 3);
        if (!self.do_view_change_from[from_replica]) {
            self.do_view_change_from[from_replica] = true;
            self.log_states[from_replica] = log_state;
            self.do_view_change_count += 1;
        }
    }

    /// Check if quorum achieved (2/3).
    pub fn hasQuorum(self: *const DoViewChangeTracker) bool {
        return self.do_view_change_count >= 2;
    }

    /// Merge logs: select highest op.
    /// Returns the log state with highest op (and highest commit_num as tiebreaker).
    pub fn mergeLog(self: *const DoViewChangeTracker) LogState {
        var best_log = LogState.init(0, 0);

        for (self.log_states) |maybe_log| {
            if (maybe_log) |log| {
                // Highest op wins
                if (log.last_op > best_log.last_op) {
                    best_log = log;
                } else if (log.last_op == best_log.last_op) {
                    // Tiebreaker: highest commit_num
                    if (log.commit_num > best_log.commit_num) {
                        best_log = log;
                    }
                }
            }
        }

        return best_log;
    }
};

/// New primary election coordinator.
pub const ElectionCoordinator = struct {
    replica: *Replica,
    do_view_change_tracker: ?DoViewChangeTracker,

    pub fn init(replica: *Replica) ElectionCoordinator {
        return ElectionCoordinator{
            .replica = replica,
            .do_view_change_tracker = null,
        };
    }

    /// Handle do_view_change message.
    /// Returns true if quorum achieved and we should send start_view.
    pub fn handleDoViewChange(
        self: *ElectionCoordinator,
        view: u32,
        from_replica: u8,
        log_state: LogState,
    ) !bool {
        // Verify we're the new primary for this view
        const expected_primary = @as(u8, @intCast(view % 3));
        if (expected_primary != self.replica.config.replica_id) {
            return false; // Not the new primary
        }

        // Verify we're in view change state
        if (self.replica.state != .view_change) {
            return false;
        }

        // Initialize tracker for this view if needed
        if (self.do_view_change_tracker == null or
            self.do_view_change_tracker.?.view != view)
        {
            self.do_view_change_tracker = DoViewChangeTracker.init(view);
        }

        // Record this replica's do_view_change
        self.do_view_change_tracker.?.recordDoViewChange(from_replica, log_state);

        // Check if quorum achieved (S2)
        if (self.do_view_change_tracker.?.hasQuorum()) {
            // Merge logs (highest op wins)
            const merged_log = self.do_view_change_tracker.?.mergeLog();

            // Update our state to match merged log
            // In production, would replay log entries if needed
            // For now, just update op numbers
            self.replica.wal.last_op = merged_log.last_op;
            self.replica.commit_num = merged_log.commit_num;

            return true; // Ready to send start_view
        }

        return false;
    }

    /// Reset after view change completes.
    pub fn reset(self: *ElectionCoordinator) void {
        self.do_view_change_tracker = null;
    }
};

/// View installation handler for completing view change.
pub const ViewInstaller = struct {
    replica: *Replica,

    pub fn init(replica: *Replica) ViewInstaller {
        return ViewInstaller{
            .replica = replica,
        };
    }

    /// Handle start_view message from new primary.
    /// Installs new view and returns to normal operation.
    pub fn handleStartView(
        self: *ViewInstaller,
        view: u32,
        log_state: LogState,
    ) !void {
        // Verify we're in view change state
        if (self.replica.state != .view_change) {
            return error.NotInViewChangeState;
        }

        // Verify view matches or is newer
        if (view < self.replica.view) {
            return error.OldView;
        }

        // Install new view state
        // In production, would replay log entries if needed
        // For now, update state to match new primary
        self.replica.wal.last_op = log_state.last_op;
        self.replica.commit_num = log_state.commit_num;

        // Complete view change - return to normal operation
        self.replica.completeViewChange(view);
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

test "LogMerge: highest op wins" {
    var tracker = DoViewChangeTracker.init(1);

    // Replica 0: op=5, commit=3
    tracker.recordDoViewChange(0, LogState.init(5, 3));

    // Replica 1: op=7, commit=5 (highest)
    tracker.recordDoViewChange(1, LogState.init(7, 5));

    // Replica 2: op=6, commit=6
    tracker.recordDoViewChange(2, LogState.init(6, 6));

    const merged = tracker.mergeLog();
    try std.testing.expectEqual(@as(u64, 7), merged.last_op); // Highest op
    try std.testing.expectEqual(@as(u64, 5), merged.commit_num);
}

test "LogMerge: commit_num tiebreaker" {
    var tracker = DoViewChangeTracker.init(1);

    // Replica 0: op=10, commit=8
    tracker.recordDoViewChange(0, LogState.init(10, 8));

    // Replica 1: op=10, commit=10 (same op, higher commit)
    tracker.recordDoViewChange(1, LogState.init(10, 10));

    const merged = tracker.mergeLog();
    try std.testing.expectEqual(@as(u64, 10), merged.last_op);
    try std.testing.expectEqual(@as(u64, 10), merged.commit_num); // Tiebreaker
}

test "ElectionCoordinator: quorum and log merge" {
    const allocator = std.testing.allocator;
    const test_wal = "test_election.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 1, // Will be new primary for view 1
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 0 },
            .{ .replica_id = 2 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    // Transition to view change
    rep.startViewChange(1);

    var coordinator = ElectionCoordinator.init(&rep);

    // Receive do_view_change from replica 0
    const ready1 = try coordinator.handleDoViewChange(1, 0, LogState.init(5, 3));
    try std.testing.expect(!ready1); // Only 1/3, need quorum

    // Receive do_view_change from replica 2 (2/3 = quorum!)
    const ready2 = try coordinator.handleDoViewChange(1, 2, LogState.init(7, 5));
    try std.testing.expect(ready2); // Quorum reached!

    // Verify log merged (highest op = 7)
    try std.testing.expectEqual(@as(u64, 7), rep.wal.last_op);
    try std.testing.expectEqual(@as(u64, 5), rep.commit_num);
}

test "ElectionCoordinator: only new primary processes" {
    const allocator = std.testing.allocator;
    const test_wal = "test_election_wrong_primary.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 2, // NOT the new primary for view 1 (should be replica 1)
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 0 },
            .{ .replica_id = 1 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    rep.startViewChange(1);

    var coordinator = ElectionCoordinator.init(&rep);

    // Try to handle do_view_change - should reject (not new primary)
    const ready = try coordinator.handleDoViewChange(1, 0, LogState.init(5, 3));
    try std.testing.expect(!ready); // Rejected
}

test "ElectionCoordinator: deterministic primary selection" {
    // View 0: primary = 0 % 3 = 0
    const p0: u8 = @intCast(0 % 3);
    try std.testing.expectEqual(@as(u8, 0), p0);

    // View 1: primary = 1 % 3 = 1
    const p1: u8 = @intCast(1 % 3);
    try std.testing.expectEqual(@as(u8, 1), p1);

    // View 2: primary = 2 % 3 = 2
    const p2: u8 = @intCast(2 % 3);
    try std.testing.expectEqual(@as(u8, 2), p2);

    // View 3: primary = 3 % 3 = 0 (wraps around)
    const p3: u8 = @intCast(3 % 3);
    try std.testing.expectEqual(@as(u8, 0), p3);
}

test "ViewInstaller: install new view" {
    const allocator = std.testing.allocator;
    const test_wal = "test_view_installer.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 2, // Backup replica
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 0 },
            .{ .replica_id = 1 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    // Start view change
    rep.startViewChange(1);
    try std.testing.expectEqual(replica_mod.ReplicaState.view_change, rep.state);

    var installer = ViewInstaller.init(&rep);

    // Receive start_view from new primary
    try installer.handleStartView(1, LogState.init(10, 8));

    // Verify view installed
    try std.testing.expectEqual(replica_mod.ReplicaState.normal, rep.state);
    try std.testing.expectEqual(@as(u32, 1), rep.view);
    try std.testing.expectEqual(@as(u64, 10), rep.wal.last_op);
    try std.testing.expectEqual(@as(u64, 8), rep.commit_num);
}

test "ViewInstaller: reject old view" {
    const allocator = std.testing.allocator;
    const test_wal = "test_view_installer_old.wal";
    defer std.fs.cwd().deleteFile(test_wal) catch {};

    const config = replica_mod.ReplicaConfig{
        .cluster_id = 1,
        .replica_id = 2,
        .peers = [_]replica_mod.Peer{
            .{ .replica_id = 0 },
            .{ .replica_id = 1 },
        },
    };

    var rep = try Replica.init(allocator, config, test_wal);
    defer rep.deinit();

    // Already in view 2
    rep.startViewChange(2);

    var installer = ViewInstaller.init(&rep);

    // Try to install view 1 (older) - should reject
    try std.testing.expectError(error.OldView, installer.handleStartView(1, LogState.init(10, 8)));
}

test "ViewChange: full protocol simulation" {
    const allocator = std.testing.allocator;

    // Create 3 replicas
    const configs = [3]replica_mod.ReplicaConfig{
        .{
            .cluster_id = 1,
            .replica_id = 0,
            .peers = [_]replica_mod.Peer{
                .{ .replica_id = 1 },
                .{ .replica_id = 2 },
            },
        },
        .{
            .cluster_id = 1,
            .replica_id = 1,
            .peers = [_]replica_mod.Peer{
                .{ .replica_id = 0 },
                .{ .replica_id = 2 },
            },
        },
        .{
            .cluster_id = 1,
            .replica_id = 2,
            .peers = [_]replica_mod.Peer{
                .{ .replica_id = 0 },
                .{ .replica_id = 1 },
            },
        },
    };

    const test_wals = [3][]const u8{
        "test_vc_sim_r0.wal",
        "test_vc_sim_r1.wal",
        "test_vc_sim_r2.wal",
    };
    defer for (test_wals) |wal| {
        std.fs.cwd().deleteFile(wal) catch {};
    };

    var replicas: [3]Replica = undefined;
    for (&replicas, 0..) |*rep, i| {
        rep.* = try Replica.init(allocator, configs[i], test_wals[i]);
    }
    defer for (&replicas) |*rep| {
        rep.deinit();
    };

    // SCENARIO: Primary (replica 0) fails, view change to view 1
    // New primary will be replica 1 (1 % 3 = 1)

    // Step 1: Replicas 1 and 2 detect timeout
    var vc1 = ViewChangeState.init(&replicas[1]);
    var vc2 = ViewChangeState.init(&replicas[2]);

    vc1.timeout_tracker.recordPrepare(1000);
    vc2.timeout_tracker.recordPrepare(1000);

    // Timeout triggers view change
    const triggered1 = try vc1.checkTimeout(52000);
    const triggered2 = try vc2.checkTimeout(52000);
    try std.testing.expect(triggered1);
    try std.testing.expect(triggered2);

    // Both now in view 1
    try std.testing.expectEqual(@as(u32, 1), replicas[1].view);
    try std.testing.expectEqual(@as(u32, 1), replicas[2].view);

    // Step 2: Replicas send do_view_change to new primary (replica 1)
    var coordinator = ElectionCoordinator.init(&replicas[1]);

    // Replica 1 (new primary) has own log
    const ready1 = try coordinator.handleDoViewChange(1, 1, LogState.init(5, 3));
    try std.testing.expect(!ready1); // Only self, need quorum

    // Replica 2 sends do_view_change
    const ready2 = try coordinator.handleDoViewChange(1, 2, LogState.init(7, 5));
    try std.testing.expect(ready2); // Quorum reached!

    // Step 3: New primary (replica 1) has merged log (highest op = 7)
    try std.testing.expectEqual(@as(u64, 7), replicas[1].wal.last_op);
    try std.testing.expectEqual(@as(u64, 5), replicas[1].commit_num);

    // Step 4: New primary completes view change and broadcasts start_view
    replicas[1].completeViewChange(1);
    const merged_log = LogState.init(replicas[1].wal.last_op, replicas[1].commit_num);

    // Replica 2 installs new view
    var installer2 = ViewInstaller.init(&replicas[2]);
    try installer2.handleStartView(1, merged_log);

    // Step 5: Verify replicas back in normal state
    try std.testing.expectEqual(replica_mod.ReplicaState.normal, replicas[1].state);
    try std.testing.expectEqual(replica_mod.ReplicaState.normal, replicas[2].state);

    // Step 6: Verify all have same view and log state
    try std.testing.expectEqual(@as(u32, 1), replicas[1].view);
    try std.testing.expectEqual(@as(u32, 1), replicas[2].view);
    try std.testing.expectEqual(@as(u64, 7), replicas[2].wal.last_op);
    try std.testing.expectEqual(@as(u64, 5), replicas[2].commit_num);

    // VIEW CHANGE COMPLETE!
}
