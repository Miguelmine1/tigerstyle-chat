//! Cryptographic primitives for TigerChat
//!
//! All functions are designed for zero heap allocation in hot paths.
//! Test vectors verify correctness against known-good implementations.
//!
//! Enforces invariants:
//! - SE1: Signature validation (Ed25519)
//! - SE4: Checksum integrity (CRC32C)
//! - S5: Hash chain integrity (SHA256)

const std = @import("std");
const assert = std.debug.assert;

// ============================================================================
// CRC32C (Castagnoli) - Fast checksums with hardware acceleration
// ============================================================================

/// CRC32C polynomial (Castagnoli): 0x1EDC6F41
/// Used for message integrity checks (SE4 invariant).
/// Hardware acceleration via SSE4.2 on x86_64 if available.
pub fn crc32c(data: []const u8) u32 {
    // TODO: Detect and use hardware CRC32C instruction on x86_64
    // For now, software implementation
    return crc32cSoftware(data);
}

fn crc32cSoftware(data: []const u8) u32 {
    const polynomial: u32 = 0x82F63B78; // Reversed 0x1EDC6F41
    var crc: u32 = 0xFFFFFFFF;

    for (data) |byte| {
        crc ^= byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            crc = if (crc & 1 != 0)
                (crc >> 1) ^ polynomial
            else
                crc >> 1;
        }
    }

    return ~crc;
}

// ============================================================================
// SHA256 - Hash chain integrity
// ============================================================================

pub const Sha256Hash = [32]u8;

/// Compute SHA256 hash of input data.
/// Used for hash chain integrity (S5 invariant).
pub fn sha256(data: []const u8) Sha256Hash {
    var hash: Sha256Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

// ============================================================================
// Ed25519 - Digital signatures
// ============================================================================

pub const Ed25519PublicKey = [32]u8;
pub const Ed25519SecretKey = [64]u8;
pub const Ed25519Signature = [64]u8;
pub const Ed25519Seed = [32]u8;

/// Generate Ed25519 keypair from seed.
/// Seed must be cryptographically random in production.
/// For simulation, use PRNG with deterministic seed.
pub fn ed25519KeyPair(seed: Ed25519Seed) struct {
    public_key: Ed25519PublicKey,
    secret_key: Ed25519SecretKey,
} {
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    return .{
        .public_key = kp.public_key.bytes,
        .secret_key = kp.secret_key.toBytes(),
    };
}

/// Sign message with Ed25519 secret key.
/// Used for message authentication (SE1 invariant).
pub fn ed25519Sign(message: []const u8, secret_key: Ed25519SecretKey) Ed25519Signature {
    // Reconstruct keypair from secret key bytes
    const sk = std.crypto.sign.Ed25519.SecretKey.fromBytes(secret_key) catch unreachable;
    const pk_bytes = sk.publicKeyBytes();
    const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(pk_bytes) catch unreachable;
    const kp = std.crypto.sign.Ed25519.KeyPair{ .secret_key = sk, .public_key = pk };
    const sig = kp.sign(message, null) catch unreachable;
    return sig.toBytes();
}

/// Verify Ed25519 signature.
/// Returns true if signature is valid, false otherwise.
/// Used for message authentication (SE1 invariant).
pub fn ed25519Verify(message: []const u8, signature: Ed25519Signature, public_key: Ed25519PublicKey) bool {
    const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch return false;
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);
    sig.verify(message, pk) catch return false;
    return true;
}

// ============================================================================
// PRNG - Deterministic random for simulation
// ============================================================================

/// Deterministic PRNG for simulation testing.
/// Uses same seed → same sequence (X1: deterministic invariant).
/// NOT cryptographically secure. For simulation only.
pub const PRNG = struct {
    state: u64,

    /// Initialize PRNG with seed.
    /// Same seed produces same sequence.
    pub fn init(seed: u64) PRNG {
        return .{ .state = seed };
    }

    /// Generate next random u64.
    /// Uses xorshift64* algorithm.
    pub fn next(self: *PRNG) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// Generate random u32.
    pub fn nextU32(self: *PRNG) u32 {
        return @truncate(self.next());
    }

    /// Generate random bytes.
    pub fn fill(self: *PRNG, buf: []u8) void {
        var i: usize = 0;
        while (i + 8 <= buf.len) : (i += 8) {
            const val = self.next();
            std.mem.writeInt(u64, buf[i..][0..8], val, .little);
        }
        if (i < buf.len) {
            const val = self.next();
            @memcpy(buf[i..], std.mem.asBytes(&val)[0 .. buf.len - i]);
        }
    }
};

// ============================================================================
// Tests with test vectors
// ============================================================================

test "crc32c: empty string" {
    const result = crc32c("");
    try std.testing.expectEqual(@as(u32, 0x00000000), result);
}

test "crc32c: test vector 1" {
    const result = crc32c("123456789");
    try std.testing.expectEqual(@as(u32, 0xe3069283), result);
}

test "crc32c: test vector 2" {
    const result = crc32c("The quick brown fox jumps over the lazy dog");
    try std.testing.expectEqual(@as(u32, 0x22620404), result);
}

test "sha256: empty string" {
    const result = sha256("");
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "sha256: test vector" {
    const result = sha256("abc");
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try std.testing.expectEqualSlices(u8, &expected, &result);
}

test "ed25519: sign and verify" {
    const seed: Ed25519Seed = [_]u8{1} ** 32;
    const kp = ed25519KeyPair(seed);

    const message = "TigerChat: correctness first";
    const signature = ed25519Sign(message, kp.secret_key);

    // Valid signature
    try std.testing.expect(ed25519Verify(message, signature, kp.public_key));

    // Wrong message
    try std.testing.expect(!ed25519Verify("wrong message", signature, kp.public_key));

    // Wrong public key
    const wrong_seed: Ed25519Seed = [_]u8{2} ** 32;
    const wrong_kp = ed25519KeyPair(wrong_seed);
    try std.testing.expect(!ed25519Verify(message, signature, wrong_kp.public_key));
}

test "ed25519: deterministic" {
    const seed: Ed25519Seed = [_]u8{42} ** 32;
    const kp1 = ed25519KeyPair(seed);
    const kp2 = ed25519KeyPair(seed);

    // Same seed produces same keys
    try std.testing.expectEqualSlices(u8, &kp1.public_key, &kp2.public_key);
    try std.testing.expectEqualSlices(u8, &kp1.secret_key, &kp2.secret_key);
}

test "PRNG: deterministic" {
    var prng1 = PRNG.init(12345);
    var prng2 = PRNG.init(12345);

    // Same seed produces same sequence
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(prng1.next(), prng2.next());
    }
}

test "PRNG: different seeds produce different sequences" {
    var prng1 = PRNG.init(12345);
    var prng2 = PRNG.init(54321);

    // Different seeds produce different values
    try std.testing.expect(prng1.next() != prng2.next());
}

test "PRNG: fill buffer" {
    var prng = PRNG.init(9999);
    var buf: [64]u8 = undefined;
    prng.fill(&buf);

    // Buffer should not be all zeros
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "no heap allocations" {
    // Verify all crypto functions work without allocator
    const seed: Ed25519Seed = [_]u8{1} ** 32;
    const kp = ed25519KeyPair(seed);
    const message = "test";

    _ = crc32c(message);
    _ = sha256(message);
    _ = ed25519Sign(message, kp.secret_key);
    _ = ed25519Verify(message, ed25519Sign(message, kp.secret_key), kp.public_key);

    var prng = PRNG.init(1234);
    _ = prng.next();

    // If we got here without allocator, all functions are allocation-free
}
