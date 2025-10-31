//! Async I/O layer
//!
//! epoll (Linux) / kqueue (macOS) event loop
//!
//! Enforces invariants:
//! - R2: File descriptor bound
//!
//! Reference: docs/build-structure.md - src/io.zig

const std = @import("std");

// TODO(#16): Implement epoll/kqueue wrapper
// TODO(#16): Implement non-blocking TCP sockets
// TODO(#16): Implement event loop for message dispatch
// TODO(#16): Implement bounded connection pool
