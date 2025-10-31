//! Transport layer with Ed25519 signatures
//!
//! Message envelope: header + body + signature
//!
//! Enforces invariants:
//! - SE1: Signature validation (Ed25519)
//! - SE4: Checksum validation (CRC32C)
//!
//! Every inter-node message consists of:
//! 1. TransportHeader (128 bytes, aligned)
//! 2. Body (variable, up to 1 MB)
//! 3. Ed25519 Signature (64 bytes)
//!
//! Reference: docs/protocol.md - Transport Protocol

const std = @import("std");
const crypto_mod = @import("crypto.zig");
const message_mod = @import("message.zig");
const assert = std.debug.assert;

const Message = message_mod.Message;

/// Magic number for TigerChat transport ("TIGR")
const TRANSPORT_MAGIC: u32 = 0x54494752;

/// Protocol version
const TRANSPORT_VERSION: u16 = 1;

/// Maximum body size (1 MB)
const MAX_BODY_SIZE: u32 = 1024 * 1024;

/// Transport header for wire protocol (128 bytes, aligned).
pub const TransportHeader = extern struct {
    magic: u32, // 0x54494752 ("TIGR")
    version: u16, // Protocol version (1)
    command: u8, // Message type
    reserved1: u8, // Padding
    checksum: u32, // CRC32C of header+body
    nonce: u64, // Monotonic nonce (replay protection)
    view: u32, // Current view
    op: u64, // Operation number
    commit_num: u64, // Commit number
    cluster_id: u128, // Cluster ID (cross-cluster protection)
    sender_id: u8, // Replica ID (0-2)
    reserved2: [3]u8, // Padding
    body_size: u32, // Size of body in bytes
    reserved3: [52]u8, // Reserved for future use

    comptime {
        assert(@sizeOf(TransportHeader) == 128);
    }

    pub fn init(
        command: u8,
        nonce: u64,
        view: u32,
        op: u64,
        commit_num: u64,
        cluster_id: u128,
        sender_id: u8,
        body_size: u32,
    ) TransportHeader {
        return TransportHeader{
            .magic = TRANSPORT_MAGIC,
            .version = TRANSPORT_VERSION,
            .command = command,
            .reserved1 = 0,
            .checksum = 0, // Will be computed separately
            .nonce = nonce,
            .view = view,
            .op = op,
            .commit_num = commit_num,
            .cluster_id = cluster_id,
            .sender_id = sender_id,
            .reserved2 = [_]u8{0} ** 3,
            .body_size = body_size,
            .reserved3 = [_]u8{0} ** 52,
        };
    }

    /// Verify magic number and version.
    pub fn isValid(self: *const TransportHeader) bool {
        return self.magic == TRANSPORT_MAGIC and self.version == TRANSPORT_VERSION;
    }
};

/// Signed message envelope.
pub const Envelope = struct {
    header: TransportHeader,
    body: []const u8,
    signature: [64]u8,

    /// Create and sign an envelope.
    pub fn sign(
        allocator: std.mem.Allocator,
        header: TransportHeader,
        body: []const u8,
        secret_key: *const [64]u8,
    ) !Envelope {
        // Validate body size
        if (body.len != header.body_size or body.len > MAX_BODY_SIZE) {
            return error.InvalidBodySize;
        }

        // Compute checksum over header + body
        var header_copy = header;
        header_copy.checksum = 0; // Zero out checksum field before computing

        // Compute CRC32C checksum (SE4)
        const header_bytes = std.mem.asBytes(&header_copy);
        const combined_len = header_bytes.len + body.len;
        const combined = try allocator.alloc(u8, combined_len);
        defer allocator.free(combined);
        @memcpy(combined[0..header_bytes.len], header_bytes);
        @memcpy(combined[header_bytes.len..], body);
        header_copy.checksum = crypto_mod.crc32c(combined);

        // Sign header + body with Ed25519
        const to_sign = try allocator.alloc(u8, @sizeOf(TransportHeader) + body.len);
        defer allocator.free(to_sign);

        @memcpy(to_sign[0..@sizeOf(TransportHeader)], std.mem.asBytes(&header_copy));
        @memcpy(to_sign[@sizeOf(TransportHeader)..], body);

        const signature = crypto_mod.ed25519Sign(to_sign, secret_key.*);

        return Envelope{
            .header = header_copy,
            .body = body,
            .signature = signature,
        };
    }

    /// Verify signature and checksum.
    pub fn verify(
        self: *const Envelope,
        allocator: std.mem.Allocator,
        public_key: *const [32]u8,
    ) !void {
        // SE1: Verify magic and version
        if (!self.header.isValid()) {
            return error.InvalidMagicOrVersion;
        }

        // SE4: Verify checksum
        var header_copy = self.header;
        const expected_checksum = header_copy.checksum;
        header_copy.checksum = 0;

        // Compute CRC32C checksum
        const header_bytes = std.mem.asBytes(&header_copy);
        const combined_len = header_bytes.len + self.body.len;
        const combined = try allocator.alloc(u8, combined_len);
        defer allocator.free(combined);
        @memcpy(combined[0..header_bytes.len], header_bytes);
        @memcpy(combined[header_bytes.len..], self.body);
        const actual_checksum = crypto_mod.crc32c(combined);

        if (actual_checksum != expected_checksum) {
            return error.ChecksumMismatch;
        }

        // SE1: Verify Ed25519 signature
        const to_verify = try allocator.alloc(u8, @sizeOf(TransportHeader) + self.body.len);
        defer allocator.free(to_verify);

        @memcpy(to_verify[0..@sizeOf(TransportHeader)], std.mem.asBytes(&self.header));
        @memcpy(to_verify[@sizeOf(TransportHeader)..], self.body);

        if (!crypto_mod.ed25519Verify(to_verify, self.signature, public_key.*)) {
            return error.InvalidSignature;
        }
    }
};

/// Transport connection for sending/receiving signed messages.
pub const Transport = struct {
    allocator: std.mem.Allocator,
    cluster_id: u128,
    replica_id: u8,
    secret_key: [64]u8,
    public_key: [32]u8,
    peer_keys: [3][32]u8, // Public keys of all replicas
    nonce: u64, // Monotonic nonce for replay protection (SE2)

    pub fn init(
        allocator: std.mem.Allocator,
        cluster_id: u128,
        replica_id: u8,
        secret_key: [64]u8,
        peer_keys: [3][32]u8,
    ) Transport {
        // Extract public key from secret key
        var public_key: [32]u8 = undefined;
        @memcpy(&public_key, secret_key[32..64]);

        return Transport{
            .allocator = allocator,
            .cluster_id = cluster_id,
            .replica_id = replica_id,
            .secret_key = secret_key,
            .public_key = public_key,
            .peer_keys = peer_keys,
            .nonce = 0,
        };
    }

    /// Send a message (sign and create envelope).
    pub fn send(
        self: *Transport,
        command: u8,
        view: u32,
        op: u64,
        commit_num: u64,
        body: []const u8,
    ) !Envelope {
        // Increment nonce (monotonic, SE2)
        self.nonce += 1;

        const header = TransportHeader.init(
            command,
            self.nonce,
            view,
            op,
            commit_num,
            self.cluster_id,
            self.replica_id,
            @intCast(body.len),
        );

        return try Envelope.sign(
            self.allocator,
            header,
            body,
            &self.secret_key,
        );
    }

    /// Receive a message (verify signature and checksum).
    pub fn receive(self: *Transport, envelope: *const Envelope) !void {
        // Verify sender is in cluster
        if (envelope.header.sender_id >= 3) {
            return error.InvalidSenderId;
        }

        // SE3: Verify cluster ID
        if (envelope.header.cluster_id != self.cluster_id) {
            return error.ClusterIdMismatch;
        }

        // Verify signature with sender's public key
        const sender_key = &self.peer_keys[envelope.header.sender_id];
        try envelope.verify(self.allocator, sender_key);

        // Note: Nonce checking (replay protection) would be done by caller
        // based on sender_id and previous nonces seen
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TransportHeader: size" {
    try std.testing.expectEqual(128, @sizeOf(TransportHeader));
}

test "TransportHeader: magic and version validation" {
    const header = TransportHeader.init(1, 100, 0, 1, 0, 123, 0, 10);

    try std.testing.expect(header.isValid());
    try std.testing.expectEqual(TRANSPORT_MAGIC, header.magic);
    try std.testing.expectEqual(TRANSPORT_VERSION, header.version);
}

test "Envelope: sign and verify" {
    const allocator = std.testing.allocator;

    // Generate keypair
    var seed: [32]u8 = undefined;
    @memset(&seed, 42);
    const keypair = crypto_mod.ed25519KeyPair(seed);

    // Create header
    const header = TransportHeader.init(
        1, // command
        100, // nonce
        0, // view
        1, // op
        0, // commit_num
        123, // cluster_id
        0, // sender_id
        5, // body_size
    );

    // Create and sign envelope
    const body = "hello";
    const envelope = try Envelope.sign(allocator, header, body, &keypair.secret_key);

    // Verify signature
    try envelope.verify(allocator, &keypair.public_key);
}

test "Envelope: invalid signature rejected" {
    const allocator = std.testing.allocator;

    // Generate two keypairs
    var seed1: [32]u8 = undefined;
    @memset(&seed1, 1);
    const keypair1 = crypto_mod.ed25519KeyPair(seed1);

    var seed2: [32]u8 = undefined;
    @memset(&seed2, 2);
    const keypair2 = crypto_mod.ed25519KeyPair(seed2);

    // Sign with keypair1
    const header = TransportHeader.init(1, 100, 0, 1, 0, 123, 0, 5);
    const body = "hello";
    const envelope = try Envelope.sign(allocator, header, body, &keypair1.secret_key);

    // Try to verify with keypair2 (wrong key) - should fail
    try std.testing.expectError(error.InvalidSignature, envelope.verify(allocator, &keypair2.public_key));
}

test "Envelope: corrupted checksum rejected" {
    const allocator = std.testing.allocator;

    // Generate keypair
    var seed: [32]u8 = undefined;
    @memset(&seed, 42);
    const keypair = crypto_mod.ed25519KeyPair(seed);

    // Create and sign envelope
    const header = TransportHeader.init(1, 100, 0, 1, 0, 123, 0, 5);
    const body = "hello";
    var envelope = try Envelope.sign(allocator, header, body, &keypair.secret_key);

    // Corrupt the checksum
    envelope.header.checksum ^= 0xFFFFFFFF;

    // Verification should fail (SE4)
    try std.testing.expectError(error.ChecksumMismatch, envelope.verify(allocator, &keypair.public_key));
}

test "Envelope: invalid magic rejected" {
    const allocator = std.testing.allocator;

    // Generate keypair
    var seed: [32]u8 = undefined;
    @memset(&seed, 42);
    const keypair = crypto_mod.ed25519KeyPair(seed);

    // Create and sign envelope
    const header = TransportHeader.init(1, 100, 0, 1, 0, 123, 0, 5);
    const body = "hello";
    var envelope = try Envelope.sign(allocator, header, body, &keypair.secret_key);

    // Corrupt the magic number
    envelope.header.magic = 0xDEADBEEF;

    // Verification should fail (SE1)
    try std.testing.expectError(error.InvalidMagicOrVersion, envelope.verify(allocator, &keypair.public_key));
}

test "Transport: send and receive" {
    const allocator = std.testing.allocator;

    // Generate 3 keypairs for cluster
    var seed1: [32]u8 = undefined;
    @memset(&seed1, 1);
    const kp1 = crypto_mod.ed25519KeyPair(seed1);

    var seed2: [32]u8 = undefined;
    @memset(&seed2, 2);
    const kp2 = crypto_mod.ed25519KeyPair(seed2);

    var seed3: [32]u8 = undefined;
    @memset(&seed3, 3);
    const kp3 = crypto_mod.ed25519KeyPair(seed3);

    const peer_keys = [3][32]u8{
        kp1.public_key,
        kp2.public_key,
        kp3.public_key,
    };

    // Create transports for replica 0 and replica 1
    var transport0 = Transport.init(allocator, 123, 0, kp1.secret_key, peer_keys);
    var transport1 = Transport.init(allocator, 123, 1, kp2.secret_key, peer_keys);

    // Replica 0 sends a message
    const body = "test message";
    const envelope = try transport0.send(1, 0, 1, 0, body);

    // Replica 1 receives and verifies
    try transport1.receive(&envelope);

    // Verify monotonic nonce (SE2)
    try std.testing.expectEqual(@as(u64, 1), transport0.nonce);
}

test "Transport: cluster ID mismatch rejected" {
    const allocator = std.testing.allocator;

    // Generate keypairs
    var seed1: [32]u8 = undefined;
    @memset(&seed1, 1);
    const kp1 = crypto_mod.ed25519KeyPair(seed1);

    var seed2: [32]u8 = undefined;
    @memset(&seed2, 2);
    const kp2 = crypto_mod.ed25519KeyPair(seed2);

    var seed3: [32]u8 = undefined;
    @memset(&seed3, 3);
    const kp3 = crypto_mod.ed25519KeyPair(seed3);

    const peer_keys = [3][32]u8{
        kp1.public_key,
        kp2.public_key,
        kp3.public_key,
    };

    // Create transports with DIFFERENT cluster IDs
    var transport0 = Transport.init(allocator, 123, 0, kp1.secret_key, peer_keys);
    var transport1 = Transport.init(allocator, 456, 1, kp2.secret_key, peer_keys); // Different cluster!

    // Replica 0 sends a message
    const body = "test";
    const envelope = try transport0.send(1, 0, 1, 0, body);

    // Replica 1 should reject (SE3: cluster isolation)
    try std.testing.expectError(error.ClusterIdMismatch, transport1.receive(&envelope));
}

test "Transport: monotonic nonce" {
    const allocator = std.testing.allocator;

    // Generate keypairs
    var seed: [32]u8 = undefined;
    @memset(&seed, 1);
    const kp = crypto_mod.ed25519KeyPair(seed);

    const peer_keys = [3][32]u8{
        kp.public_key,
        kp.public_key,
        kp.public_key,
    };

    var transport = Transport.init(allocator, 123, 0, kp.secret_key, peer_keys);

    // Send multiple messages
    _ = try transport.send(1, 0, 1, 0, "msg1");
    try std.testing.expectEqual(@as(u64, 1), transport.nonce);

    _ = try transport.send(1, 0, 2, 0, "msg2");
    try std.testing.expectEqual(@as(u64, 2), transport.nonce);

    _ = try transport.send(1, 0, 3, 0, "msg3");
    try std.testing.expectEqual(@as(u64, 3), transport.nonce);

    // Nonce is monotonic (SE2: replay protection)
}
