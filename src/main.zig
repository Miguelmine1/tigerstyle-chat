//! TigerChat: Distributed, fault-tolerant real-time chat infrastructure
//!
//! Built with Tiger Style principles:
//! - Safety before performance
//! - Predictable performance (no unbounded queues, no GC)
//! - One binary, zero mystery
//! - Transparent fault recovery
//! - Auditable by design
//!
//! Entry point for the replica binary.

const std = @import("std");

pub fn main() !void {
    // TODO: Parse CLI arguments
    // TODO: Load configuration
    // TODO: Initialize replica
    // TODO: Start event loop

    std.debug.print("TigerChat v0.1.0 🐅\n", .{});
    std.debug.print("Replica starting... (stub)\n", .{});

    return error.NotImplementedYet;
}

test {
    // Import all modules to run their tests
    _ = @import("crypto.zig");
    _ = @import("message.zig");
    _ = @import("queue.zig");
    _ = @import("wal.zig");
    _ = @import("state_machine.zig");
    _ = @import("replica.zig");
    _ = @import("primary.zig");
    _ = @import("view_change.zig");
    _ = @import("transport.zig");
    _ = @import("io.zig");
    _ = @import("config.zig");
    _ = @import("fanout.zig");
    _ = @import("edge.zig");
    _ = @import("metrics.zig");
    _ = @import("audit.zig");
}
