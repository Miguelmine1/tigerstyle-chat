//! Operator CLI (tigerctl)
//!
//! Commands:
//! - status: Show replica state
//! - drain: Gracefully drain replica
//! - metrics: Query metrics
//! - audit: View audit log

const std = @import("std");

pub fn main() !void {
    std.debug.print("tigerctl v0.1.0 🐅\n", .{});
    std.debug.print("Operator CLI (stub)\n", .{});

    // TODO(#38): Implement status command
    // TODO(#38): Implement drain command
    // TODO(#38): Implement metrics command
    // TODO(#38): Implement audit command

    return error.NotImplementedYet;
}
