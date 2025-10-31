//! Fan-out pub/sub bus
//!
//! In-memory pub/sub per room for committed messages.
//!
//! Enforces invariants:
//! - R1: No allocations in hot path (pre-allocated pool)

const std = @import("std");

// TODO(#25): Implement in-memory pub/sub per room
// TODO(#25): Implement subscribe clients to room_id
// TODO(#25): Implement publish committed messages
// TODO(#25): Implement bounded subscriber list per room
