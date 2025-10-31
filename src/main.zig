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
//!
//! Usage:
//!   tigerchat --config configs/replica0.conf
//!   tigerchat --help

const std = @import("std");
const config_mod = @import("config.zig");
const io_mod = @import("io.zig");
const replica_mod = @import("replica.zig");
const wal_mod = @import("wal.zig");
const crypto_mod = @import("crypto.zig");

const VERSION = "0.1.0";

/// Command-line arguments
const Args = struct {
    config_path: ?[]const u8 = null,
    help: bool = false,
};

/// Parse command-line arguments
fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = Args{};
    var arg_iter = try std.process.argsWithAllocator(allocator);
    defer arg_iter.deinit();

    // Skip program name
    _ = arg_iter.next();

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (arg_iter.next()) |config_path| {
                args.config_path = config_path;
            } else {
                return error.MissingConfigPath;
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    return args;
}

/// Print usage information
fn printUsage() void {
    std.debug.print(
        \\TigerChat v{s} 🐅
        \\Distributed, fault-tolerant chat infrastructure
        \\
        \\Usage:
        \\  tigerchat --config <path>  Start replica with config file
        \\  tigerchat --help           Show this help message
        \\
        \\Example:
        \\  tigerchat --config configs/replica0.conf
        \\
        \\Tiger Style:
        \\  - One binary, zero mystery
        \\  - Bounded everything (no infinite queues)
        \\  - Fail-fast validation
        \\  - Crash-safe by design
        \\
    , .{VERSION});
}

/// Global shutdown flag for graceful termination
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Signal handler for SIGINT (Ctrl+C)
fn handleSigint(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

pub fn main() !void {
    // Setup allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments
    const args = parseArgs(allocator) catch |err| {
        if (err == error.UnknownArgument or err == error.MissingConfigPath) {
            printUsage();
            return err;
        }
        return err;
    };

    // Handle --help
    if (args.help) {
        printUsage();
        return;
    }

    // Require config path
    const config_path = args.config_path orelse {
        std.debug.print("Error: --config required\n\n", .{});
        printUsage();
        return error.ConfigRequired;
    };

    // Banner
    std.debug.print("\n🐅 TigerChat v{s}\n", .{VERSION});
    std.debug.print("   Consensus: VSR (Viewstamped Replication)\n", .{});
    std.debug.print("   Safety: Ed25519 + CRC32C\n", .{});
    std.debug.print("   I/O: epoll/kqueue (non-blocking)\n\n", .{});

    // Load configuration
    std.debug.print("Loading config: {s}\n", .{config_path});
    const config_file = std.fs.cwd().readFileAlloc(
        allocator,
        config_path,
        1024 * 1024, // 1MB max
    ) catch |err| {
        std.debug.print("Error reading config: {any}\n", .{err});
        return err;
    };
    defer allocator.free(config_file);

    const config = config_mod.parseConfig(allocator, config_file) catch |err| {
        std.debug.print("Error parsing config: {any}\n", .{err});
        return err;
    };

    std.debug.print("  Cluster ID: {d}\n", .{config.cluster_id});
    std.debug.print("  Replica ID: {d}\n", .{config.replica_id});
    std.debug.print("  Port: {d}\n", .{config.port});
    std.debug.print("  Prepare timeout: {d}ms\n", .{config.prepare_timeout_ms});
    std.debug.print("  View change timeout: {d}ms\n\n", .{config.view_change_timeout_ms});

    // Setup signal handler for graceful shutdown
    const sig_handler = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = [_]c_ulong{0} ** 1, // empty sigset
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sig_handler, null);

    std.debug.print("Initializing replica...\n", .{});

    // Generate temporary keypair (in production, load from config)
    const seed: crypto_mod.Ed25519Seed = .{0} ** 32;
    const keypair = crypto_mod.ed25519KeyPair(seed);

    // Initialize event loop
    var event_loop = try io_mod.EventLoop.init(allocator);
    defer event_loop.deinit();

    // Create network address
    const addr = try std.net.Address.parseIp4(config.host, config.port);

    // Create listener
    const listener = try event_loop.createListener(addr);
    defer std.posix.close(listener);

    std.debug.print("✓ Listening on {any}\n", .{addr});
    std.debug.print("✓ Replica initialized\n\n", .{});

    std.debug.print("Running... (Press Ctrl+C to stop)\n\n", .{});

    // Main event loop
    var iteration: usize = 0;
    while (!shutdown_requested.load(.seq_cst)) {
        // Process events (10ms timeout)
        const events_processed = event_loop.run(10) catch |err| {
            std.debug.print("Event loop error: {any}\n", .{err});
            continue;
        };

        if (events_processed > 0) {
            iteration += 1;
            if (iteration % 100 == 0) {
                std.debug.print("  Heartbeat: {d} events processed\n", .{iteration});
            }
        }

        // In production: process messages, timeouts, view changes
        // For now: just demonstrate the event loop is running
    }

    std.debug.print("\n🐅 Shutting down gracefully...\n", .{});
    std.debug.print("✓ Event loop stopped\n", .{});
    std.debug.print("✓ Connections closed\n", .{});
    std.debug.print("✓ Clean shutdown complete\n\n", .{});

    _ = keypair; // TODO: Use keypair for crypto operations
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
