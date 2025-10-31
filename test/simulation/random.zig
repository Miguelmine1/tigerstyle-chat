//! Random simulation suite
//!
//! Run N simulations with random seeds and workloads.

const std = @import("std");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: sim-random <count>\n", .{});
        return error.InvalidArgs;
    }

    const count = try std.fmt.parseInt(u32, args[1], 10);
    std.debug.print("Running {d} random simulations...\n", .{count});

    // TODO(#33): Implement random simulation suite
    return error.NotImplementedYet;
}
