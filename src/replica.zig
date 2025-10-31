//! VSR Replica implementation
//!
//! State machine: Normal, ViewChange, Recovering
//!
//! Enforces invariants:
//! - SE2: Nonce anti-replay
//! - SE3: Cluster isolation
//!
//! Reference: docs/protocol.md - VSR State Machine

const std = @import("std");

// TODO(#9): Implement Replica struct with state enum
// TODO(#9): Implement configuration (cluster_id, replica_id, peers)
// TODO(#9): Integrate WAL and state machine
// TODO(#9): Implement nonce tracking for replay protection
// TODO(#11): Implement handle_prepare
// TODO(#11): Implement handle_commit
