//! Message types and serialization
//!
//! All messages are fixed-size extern structs for deterministic layout.
//! Total message size: 2368 bytes, 16-byte aligned.
//!
//! Reference: docs/message-formats.md

const std = @import("std");

// TODO(#4): Implement TransportHeader (128 bytes)
// TODO(#4): Implement Message extern struct (2368 bytes total)
// TODO(#4): Implement MessageCommand enum
// TODO(#4): Implement checksum calculation
// TODO(#4): Implement hash chain (prev_hash) support
// TODO(#4): Add compile-time size assertions
