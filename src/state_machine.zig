//! Deterministic state machine for room state
//!
//! Enforces invariants:
//! - S3: Commit ordering
//! - S6: Idempotency uniqueness
//! - S8: Timestamp monotonicity
//! - X1: Deterministic state machine (same log → same state)
//!
//! Reference: docs/protocol.md - RoomState

const std = @import("std");

// TODO(#8): Implement RoomState struct
// TODO(#8): Implement apply(message) - deterministic state transition
// TODO(#8): Implement idempotency table for exactly-once
// TODO(#8): Implement message index (msg_id → op)
// TODO(#8): Implement head hash calculation
