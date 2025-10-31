//! Primary-specific VSR logic
//!
//! Handles normal-case protocol:
//! - Accept client requests
//! - Assign op numbers (monotonic)
//! - Broadcast prepare
//! - Collect prepare_ok (quorum)
//! - Send commit
//!
//! Enforces invariants:
//! - S1: Log monotonicity
//! - S2: Quorum agreement
//!
//! Reference: docs/protocol.md - Message Flow (Normal Case)

const std = @import("std");

// TODO(#10): Implement accept_client_request
// TODO(#10): Implement assign_op_number (monotonic, S1)
// TODO(#10): Implement broadcast_prepare
// TODO(#10): Implement collect_prepare_ok (quorum = 2/3, S2)
// TODO(#10): Implement send_commit
