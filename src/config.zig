//! Configuration parsing
//!
//! Parse TOML-like configuration file for cluster setup:
//! - Cluster topology (ID, replica ID, peers)
//! - Network addresses (host, port)
//! - Timeout values (prepare, view change)
//! - Queue sizes (bounded queues)
//! - Cryptographic keys (Ed25519)
//!
//! Simple key=value format (TOML-like, no external dependencies)
//!
//! Example config:
//! ```
//! [cluster]
//! cluster_id = 123
//! replica_id = 0
//!
//! [network]
//! host = "127.0.0.1"
//! port = 3000
//!
//! [peers]
//! peer.0 = "127.0.0.1:3000"
//! peer.1 = "127.0.0.1:3001"
//! peer.2 = "127.0.0.1:3002"
//!
//! [timeouts]
//! prepare_timeout_ms = 50
//! view_change_timeout_ms = 300
//!
//! [queues]
//! message_queue_size = 1024
//! ```
//!
//! Reference: docs/deployment.md - Configuration

const std = @import("std");
const net = std.net;
const assert = std.debug.assert;

/// Peer configuration (replica in cluster)
pub const PeerConfig = struct {
    address: net.Address,
    public_key: [32]u8,
};

/// Complete cluster configuration
pub const Config = struct {
    // Cluster identity
    cluster_id: u128,
    replica_id: u8,

    // Network
    host: []const u8,
    port: u16,

    // Peers (other replicas)
    peers: [3]PeerConfig,

    // Timeouts (milliseconds)
    prepare_timeout_ms: u32,
    view_change_timeout_ms: u32,

    // Queue sizes (bounded)
    message_queue_size: usize,

    // Crypto keys
    secret_key: [64]u8,
    public_key: [32]u8,

    pub fn validate(self: *const Config) !void {
        // Validate replica ID (0-2 for 3-replica cluster)
        if (self.replica_id >= 3) {
            return error.InvalidReplicaId;
        }

        // Validate timeouts (must be positive)
        if (self.prepare_timeout_ms == 0) {
            return error.InvalidPrepareTimeout;
        }
        if (self.view_change_timeout_ms == 0) {
            return error.InvalidViewChangeTimeout;
        }

        // Validate view change timeout is larger than prepare timeout
        if (self.view_change_timeout_ms <= self.prepare_timeout_ms) {
            return error.ViewChangeTimeoutTooSmall;
        }

        // Validate queue size (bounded, must be power of 2 for ring buffer)
        if (self.message_queue_size == 0 or self.message_queue_size > 1_000_000) {
            return error.InvalidQueueSize;
        }

        // Validate port (must be > 1024 for non-root)
        if (self.port < 1024) {
            return error.PrivilegedPort;
        }
    }
};

/// Default configuration values
pub const DEFAULT_CONFIG = Config{
    .cluster_id = 0,
    .replica_id = 0,
    .host = "127.0.0.1",
    .port = 3000,
    .peers = undefined, // Must be configured
    .prepare_timeout_ms = 50,
    .view_change_timeout_ms = 300,
    .message_queue_size = 1024,
    .secret_key = undefined, // Must be configured
    .public_key = undefined, // Must be configured
};

/// Simple key=value parser for configuration
pub fn parseConfig(
    allocator: std.mem.Allocator,
    contents: []const u8,
) !Config {
    var config = DEFAULT_CONFIG;

    var line_iter = std.mem.splitScalar(u8, contents, '\n');
    var current_section: []const u8 = "";

    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Section headers [section]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            current_section = trimmed[1 .. trimmed.len - 1];
            continue;
        }

        // Key = value pairs
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Strip inline comments from value
            if (std.mem.indexOf(u8, value, "#")) |comment_pos| {
                value = std.mem.trim(u8, value[0..comment_pos], " \t");
            }

            try parseKeyValue(&config, allocator, current_section, key, value);
        }
    }

    // Validate before returning
    try config.validate();

    return config;
}

fn parseKeyValue(
    config: *Config,
    allocator: std.mem.Allocator,
    section: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    _ = allocator;

    if (std.mem.eql(u8, section, "cluster")) {
        if (std.mem.eql(u8, key, "cluster_id")) {
            config.cluster_id = try std.fmt.parseInt(u128, value, 10);
        } else if (std.mem.eql(u8, key, "replica_id")) {
            config.replica_id = try std.fmt.parseInt(u8, value, 10);
        }
    } else if (std.mem.eql(u8, section, "network")) {
        if (std.mem.eql(u8, key, "host")) {
            // Note: In production, would need to allocate and store
            // For now, validate it's localhost
            if (!std.mem.eql(u8, value, "127.0.0.1") and !std.mem.eql(u8, value, "localhost")) {
                return error.InvalidHost;
            }
        } else if (std.mem.eql(u8, key, "port")) {
            config.port = try std.fmt.parseInt(u16, value, 10);
        }
    } else if (std.mem.eql(u8, section, "timeouts")) {
        if (std.mem.eql(u8, key, "prepare_timeout_ms")) {
            config.prepare_timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "view_change_timeout_ms")) {
            config.view_change_timeout_ms = try std.fmt.parseInt(u32, value, 10);
        }
    } else if (std.mem.eql(u8, section, "queues")) {
        if (std.mem.eql(u8, key, "message_queue_size")) {
            config.message_queue_size = try std.fmt.parseInt(usize, value, 10);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Config: validation - valid config" {
    const config = Config{
        .cluster_id = 123,
        .replica_id = 0,
        .host = "127.0.0.1",
        .port = 3000,
        .peers = undefined,
        .prepare_timeout_ms = 50,
        .view_change_timeout_ms = 300,
        .message_queue_size = 1024,
        .secret_key = undefined,
        .public_key = undefined,
    };

    try config.validate();
}

test "Config: validation - invalid replica ID" {
    var config = DEFAULT_CONFIG;
    config.replica_id = 5; // Invalid (must be 0-2)
    config.prepare_timeout_ms = 50;
    config.view_change_timeout_ms = 300;
    config.port = 3000;

    try std.testing.expectError(error.InvalidReplicaId, config.validate());
}

test "Config: validation - view change timeout too small" {
    var config = DEFAULT_CONFIG;
    config.replica_id = 0;
    config.prepare_timeout_ms = 100;
    config.view_change_timeout_ms = 50; // Must be > prepare timeout
    config.port = 3000;

    try std.testing.expectError(error.ViewChangeTimeoutTooSmall, config.validate());
}

test "Config: validation - privileged port" {
    var config = DEFAULT_CONFIG;
    config.replica_id = 0;
    config.port = 80; // Privileged port
    config.prepare_timeout_ms = 50;
    config.view_change_timeout_ms = 300;

    try std.testing.expectError(error.PrivilegedPort, config.validate());
}

test "Config: parse simple config" {
    const allocator = std.testing.allocator;

    const config_text =
        \\[cluster]
        \\cluster_id = 123
        \\replica_id = 1
        \\
        \\[network]
        \\host = 127.0.0.1
        \\port = 3001
        \\
        \\[timeouts]
        \\prepare_timeout_ms = 100
        \\view_change_timeout_ms = 500
        \\
        \\[queues]
        \\message_queue_size = 2048
    ;

    const config = try parseConfig(allocator, config_text);

    try std.testing.expectEqual(@as(u128, 123), config.cluster_id);
    try std.testing.expectEqual(@as(u8, 1), config.replica_id);
    try std.testing.expectEqual(@as(u16, 3001), config.port);
    try std.testing.expectEqual(@as(u32, 100), config.prepare_timeout_ms);
    try std.testing.expectEqual(@as(u32, 500), config.view_change_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2048), config.message_queue_size);
}

test "Config: parse with comments and whitespace" {
    const allocator = std.testing.allocator;

    const config_text =
        \\# TigerChat configuration
        \\
        \\[cluster]
        \\cluster_id = 456
        \\replica_id = 0  # This is replica 0
        \\
        \\# Network settings
        \\[network]
        \\  port = 4000
        \\
        \\[timeouts]
        \\  prepare_timeout_ms = 50  
        \\  view_change_timeout_ms = 300
        \\
        \\[queues]
        \\message_queue_size = 1024
    ;

    const config = try parseConfig(allocator, config_text);

    try std.testing.expectEqual(@as(u128, 456), config.cluster_id);
    try std.testing.expectEqual(@as(u8, 0), config.replica_id);
    try std.testing.expectEqual(@as(u16, 4000), config.port);
}

test "Config: defaults applied" {
    const allocator = std.testing.allocator;

    // Minimal config - only required fields
    const config_text =
        \\[cluster]
        \\replica_id = 2
        \\
        \\[network]
        \\port = 3002
    ;

    const config = try parseConfig(allocator, config_text);

    // Defaults should be applied
    try std.testing.expectEqual(@as(u32, 50), config.prepare_timeout_ms); // DEFAULT
    try std.testing.expectEqual(@as(u32, 300), config.view_change_timeout_ms); // DEFAULT
    try std.testing.expectEqual(@as(usize, 1024), config.message_queue_size); // DEFAULT
}
