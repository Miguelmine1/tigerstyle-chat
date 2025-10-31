# TigerChat Message Format Specification

## Design Principles

1. **Explicit sizes**: All types are explicitly sized (`u32`, `u64`, not `usize`).
2. **Alignment discipline**: Structs aligned to cache lines (64 bytes) or 16 bytes minimum.
3. **Zero parsing**: Use `extern struct` with compile-time size/alignment assertions.
4. **Bounded everything**: No variable-length arrays; fixed max sizes with length fields.
5. **Checksum all the things**: Every serialized message has CRC32C integrity check.

---

## Wire Format Encoding

All multi-byte integers: **little-endian** (x86-64 native).

Padding: **zeroed** before checksum calculation (deterministic serialization).

Strings: **UTF-8**, null-terminated if shorter than max length.

---

## Core Message Types

### 1. `TransportHeader` (128 bytes)

Foundation for all inter-node messages.

```zig
const TransportHeader = extern struct {
    magic: u32,              // 0x54494752 ("TIGR")
    version: u16,            // Protocol version = 1
    command: u8,             // Message type (see enum below)
    flags: u8,               // Reserved; must be 0
    
    checksum: u32,           // CRC32C(header[12..128] ++ body)
    size: u32,               // Total size including header + body + signature
    
    nonce: u64,              // Monotonic per sender; replay protection
    timestamp_us: u64,       // Microseconds since UNIX epoch
    
    cluster_id: u128,        // Cluster UUID (prevents cross-cluster messages)
    
    view: u32,               // Current view number
    op: u64,                 // Operation number (log index)
    commit_num: u64,         // Highest committed op number
    
    sender_id: u8,           // Replica ID (0, 1, 2)
    sender_reserved: [7]u8,  // Alignment padding
    
    reserved: [32]u8,        // Future use; must be zero
};

comptime {
    assert(@sizeOf(TransportHeader) == 128);
    assert(@alignOf(TransportHeader) == 16);
    assert(@offsetOf(TransportHeader, "checksum") == 8);
}
```

**Checksum coverage**: Starts at byte 12 (after `magic`, `version`, `command`, `flags`).

**Invariant**: `checksum` = `CRC32C(header[12..] ++ body)`.

---

### 2. `MessageCommand` Enum

```zig
const MessageCommand = enum(u8) {
    // VSR protocol
    prepare = 0x01,
    prepare_ok = 0x02,
    commit = 0x03,
    start_view_change = 0x04,
    do_view_change = 0x05,
    start_view = 0x06,
    request = 0x07,
    reply = 0x08,
    
    // Replica coordination
    ping = 0x10,
    pong = 0x11,
    request_snapshot = 0x12,
    snapshot_chunk = 0x13,
    
    // Client protocol
    send_message = 0x20,
    message_ack = 0x21,
    message_event = 0x22,
    subscribe_room = 0x23,
    snapshot_request = 0x24,
    
    // Operator commands
    drain_start = 0x30,
    drain_status = 0x31,
    
    _,  // non-exhaustive for forward compatibility
};
```

---

## VSR Messages

### 3. `PrepareMessage`

Primary broadcasts to replicas to propose a new log entry.

**Transport**: `command = 0x01`, `body = Message`

```zig
// Body is the actual user Message (defined below)
// Header contains: view, op, commit_num
```

**Preconditions**:
- `op = last_op + 1` (monotonic)
- `view` matches current view
- `commit_num ≤ op`

**Replica action**: Append to log, send `prepare_ok`.

---

### 4. `PrepareOkMessage`

Replica acknowledges receipt and persistence of `prepare`.

**Transport**: `command = 0x02`

```zig
const PrepareOkBody = extern struct {
    op: u64,
    msg_checksum: u32,   // Checksum of the Message body
    reserved: u32,
};

comptime {
    assert(@sizeOf(PrepareOkBody) == 16);
}
```

**Primary action**: When quorum (2/3) `prepare_ok` received → send `commit`.

---

### 5. `CommitMessage`

Primary instructs replicas to apply log entry.

**Transport**: `command = 0x03`

```zig
const CommitBody = extern struct {
    commit_num: u64,     // Highest consecutive committed op
};

comptime {
    assert(@sizeOf(CommitBody) == 8);
}
```

**Replica action**: Apply ops `[last_commit+1 .. commit_num]` to state machine.

---

### 6. `StartViewChangeMessage`

Replica suspects primary failure; initiates view change.

**Transport**: `command = 0x04`

```zig
const StartViewChangeBody = extern struct {
    new_view: u32,       // Proposed view = current_view + 1
    reserved: u32,
};
```

**Broadcast** to all replicas.

---

### 7. `DoViewChangeMessage`

Replica sends log state to new primary during view change.

**Transport**: `command = 0x05`

```zig
const DoViewChangeBody = extern struct {
    new_view: u32,
    last_normal_view: u32,
    op: u64,
    commit_num: u64,
    
    // Log suffix (last 100 ops)
    log_count: u32,
    reserved: u32,
    log: [100]LogEntry,
};

const LogEntry = extern struct {
    op: u64,
    checksum: u32,
    reserved: u32,
};

comptime {
    assert(@sizeOf(DoViewChangeBody) == 24 + 100 * 16);
}
```

**New primary action**: Collect quorum of `do_view_change`, merge logs.

---

### 8. `StartViewMessage`

New primary broadcasts updated log to install new view.

**Transport**: `command = 0x06`

```zig
const StartViewBody = extern struct {
    new_view: u32,
    op: u64,
    commit_num: u64,
    
    log_count: u32,
    reserved: u32,
    log: [100]LogEntry,
};

comptime {
    assert(@sizeOf(StartViewBody) == 20 + 100 * 16);
}
```

**Replica action**: Install log, transition to `Normal` state.

---

## Client Protocol Messages

### 9. `Message` (Chat Message)

Core user-generated message; stored in WAL.

```zig
const Message = extern struct {
    room_id: u128,           // Shard key
    msg_id: u128,            // UUID v7 (time-ordered)
    author_id: u64,          // User ID
    parent_id: u128,         // 0 = top-level; else thread parent
    
    timestamp: u64,          // Microseconds since epoch
    sequence: u64,           // Client-side monotonic sequence
    
    body_len: u32,           // Actual UTF-8 byte count
    flags: u32,              // bit 0 = deleted, bit 1 = edited
    
    body: [2048]u8,          // UTF-8 content (inline)
    
    prev_hash: [32]u8,       // SHA256(previous Message)
    checksum: u32,           // CRC32C(msg_id..body)
    reserved: u32,
};

comptime {
    assert(@sizeOf(Message) == 2368);
    assert(@alignOf(Message) == 16);
}
```

**Hash chain**: Each message includes `prev_hash = SHA256(Message[op-1])`.

**Root message** (op=0): `prev_hash = zeros`.

---

### 10. `SendMessageRequest`

Client → Edge → Primary.

**Transport**: `command = 0x20`

```zig
const SendMessageRequest = extern struct {
    room_id: u128,
    author_id: u64,
    parent_id: u128,
    
    client_seq: u64,         // Client's idempotency sequence
    
    body_len: u32,
    reserved: u32,
    body: [2048]u8,
};

comptime {
    assert(@sizeOf(SendMessageRequest) == 2096);
}
```

**Edge responsibility**:
- Assign `msg_id` (UUID v7).
- Check `{author_id, client_seq}` for duplicate → return cached ack.
- Convert to `Message`, forward as VSR `prepare`.

---

### 11. `MessageAck`

Edge → Client after VSR commit.

**Transport**: `command = 0x21`

```zig
const MessageAck = extern struct {
    msg_id: u128,
    op: u64,                 // Log index
    timestamp: u64,          // Server-assigned timestamp
    client_seq: u64,         // Echo back for correlation
};

comptime {
    assert(@sizeOf(MessageAck) == 40);
}
```

**Client action**: Update UI with server-assigned `op` and `timestamp`.

---

### 12. `MessageEvent`

Edge → Client (fan-out from commit bus).

**Transport**: `command = 0x22`

```zig
const MessageEvent = extern struct {
    message: Message,        // Full 2368-byte message
};

comptime {
    assert(@sizeOf(MessageEvent) == 2368);
}
```

**Client action**: Append to local UI message list if `msg_id` not seen.

---

### 13. `SubscribeRoomRequest`

Client requests live updates for a room.

**Transport**: `command = 0x23`

```zig
const SubscribeRoomRequest = extern struct {
    room_id: u128,
    since_op: u64,           // 0 = subscribe from latest; else catch-up from since_op+1
    reserved: u64,
};

comptime {
    assert(@sizeOf(SubscribeRoomRequest) == 32);
}
```

**Edge action**:
- Register WS connection to fan-out bus for `room_id`.
- If `since_op > 0` and gap exists, trigger snapshot send.

---

### 14. `SnapshotChunk`

Edge → Client for catch-up.

**Transport**: `command = 0x13` or `0x24`

```zig
const SnapshotChunk = extern struct {
    room_id: u128,
    start_op: u64,
    count: u32,              // Number of messages in this chunk (max 100)
    has_more: u32,           // 1 = more chunks coming; 0 = final
    
    messages: [100]Message,  // Batch of historical messages
};

comptime {
    assert(@sizeOf(SnapshotChunk) == 32 + 100 * 2368);
}
```

**Client action**: Batch-insert messages, request next chunk if `has_more == 1`.

---

## Operator Messages

### 15. `DrainStartRequest`

Operator CLI → Replica to begin graceful shutdown.

**Transport**: `command = 0x30`

```zig
const DrainStartRequest = extern struct {
    operator_id: u64,        // Operator identity (from cert CN)
    timeout_ms: u32,         // Max wait for pending ops
    reserved: u32,
};

comptime {
    assert(@sizeOf(DrainStartRequest) == 16);
}
```

**Replica action**:
- Stop accepting new `prepare` messages.
- Flush pending commits.
- Respond with `drain_status` when complete or timeout.

---

### 16. `DrainStatusReply`

Replica → Operator CLI.

**Transport**: `command = 0x31`

```zig
const DrainStatusReply = extern struct {
    status: u32,             // 0 = in_progress, 1 = drained, 2 = timeout
    pending_ops: u32,        // Ops not yet committed
    last_op: u64,
    last_commit: u64,
};

comptime {
    assert(@sizeOf(DrainStatusReply) == 24);
}
```

---

## Signature Envelope

All inter-node messages appended with:

```zig
const MessageSignature = extern struct {
    signature: [64]u8,       // Ed25519(header ++ body)
};
```

**Wire layout**:

```
[ TransportHeader (128 B) ][ Body (variable) ][ MessageSignature (64 B) ]
```

**Total size** = `128 + body_size + 64` (must match `header.size`).

---

## Serialization Rules

1. **Deterministic padding**: Zero all `reserved` fields before checksum.
2. **CRC32C calculation**: Use hardware `crc32c` instruction (SSE 4.2).
3. **Endianness**: Little-endian for all integers (assert on big-endian platforms).
4. **Alignment**: Always use `@alignCast` in Zig when casting buffers.

```zig
// Example: deserialize from socket
const header = @ptrCast(*const TransportHeader, @alignCast(@alignOf(TransportHeader), buffer.ptr));
assert(header.magic == 0x54494752);
assert(header.version == 1);

const calculated_checksum = crc32c(buffer[12..header.size - 64]);
assert(calculated_checksum == header.checksum);
```

---

## Size Limits

| Type | Max Size | Rationale |
|------|----------|-----------|
| `Message.body` | 2048 B | Single cache line cluster; predictable latency |
| `DoViewChangeBody.log` | 100 entries | View change bounded to ~2 KB |
| `SnapshotChunk.messages` | 100 | ~237 KB per chunk; reasonable WS frame |
| Total transport message | 1 MB | Hard limit to prevent DoS |

**Invariant**: All messages fit in pre-allocated buffers (no heap allocation in hot path).

---

## Versioning Strategy

- **Breaking changes**: Increment `TransportHeader.version`.
- **New commands**: Add to `MessageCommand` enum (non-exhaustive).
- **Field additions**: Use `reserved` space; old clients ignore.

**Compatibility**: Replicas of version `N` can interop with version `N-1` during rolling upgrade (dual-version support for 1 minor release).

---

## Security Notes

1. **No raw pointers in serialization**: Use `@ptrCast` with alignment checks.
2. **Validate all lengths**: `body_len ≤ 2048`, `log_count ≤ 100` before access.
3. **Checksum before parse**: Reject invalid checksums immediately (fail-fast).
4. **Signature verification**: Ed25519 verify before processing any VSR message.

---

## Testing Hooks

For simulation:

```zig
// Inject corruption
message.checksum ^= 0x1234;  // Flip bits

// Inject replay
message.header.nonce = old_nonce;

// Inject time skew
message.header.timestamp_us += std.time.ms_per_hour;
```

Each injection should trigger **immediate rejection** and **alert in audit log**.
