//! Transport layer with Ed25519 signatures
//!
//! Message envelope: header + body + signature
//!
//! Enforces invariants:
//! - SE1: Signature validation
//! - SE4: Checksum validation
//!
//! Reference: docs/protocol.md - Transport Protocol

const std = @import("std");

// TODO(#15): Implement message envelope
// TODO(#15): Implement Ed25519 sign outgoing messages
// TODO(#15): Implement Ed25519 verify incoming messages
// TODO(#15): Implement checksum validation
// TODO(#15): Implement send/receive primitives
