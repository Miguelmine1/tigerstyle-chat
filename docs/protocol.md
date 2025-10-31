# TigerChat Protocol Specification

## Overview

TigerChat uses a three-layer protocol architecture:
1. **VSR Layer**: Viewstamped Replication for consensus per room shard
2. **Transport Layer**: Ed25519-signed messages with mTLS
3. **Client Layer**: WebSocket/HTTP3 edge protocol with JWT auth

---

## VSR State Machine

### Replica States

```
┌──────────┐
│  Normal  │◄─────┐
└────┬─────┘      │
     │            │
     │ timeout/   │ view_change_ok
     │ suspected  │
     │            │
     ▼            │
┌──────────┐      │
│View      ├──────┘
│Change    │
└────┬─────┘
     │
     │ recovery_needed
     │
     ▼
┌──────────┐
│Recovering│
└──────────┘
```

**Normal**: Replica accepts client ops; primary broadcasts `prepare` → `prepare_ok` → `commit`.

**View Change**: New primary election; deterministic leader = `(view_number mod 3)`.

**Recovering**: Replay from latest snapshot + log tail until caught up.

### Message Flow (Normal Case)

```
Client      Edge        Primary      Replica-2    Replica-3      Bus
  │          │            │             │            │            │
  ├─send_msg─►            │             │            │            │
  │          ├─prepare────►             │            │            │
  │          │            ├─prepare─────►            │            │
  │          │            ├─prepare──────────────────►            │
  │          │            │             │            │            │
  │          │            ◄─prepare_ok──┤            │            │
  │          │            ◄─prepare_ok───────────────┤            │
  │          │            │  (quorum=2) │            │            │
  │          │            ├─commit──────►            │            │
  │          │            ├─commit───────────────────►            │
  │          │            ├────────────────────────────fanout msg─►
  │          ◄────────────────────────────────────────────────────┤
  ◄──msg_ack─┤            │             │            │            │
```

### View Change Protocol

```
Primary-0 (suspected)
  │
Replica-1 detects timeout → broadcast start_view_change(view=1)
  │
Replica-2 ──┐
Replica-3 ──┼─► receive 2+ start_view_change → send do_view_change(view=1, log, op, commit)
            │
New Primary-1 (deterministic):
  │
  ├─ collect 2+ do_view_change
  ├─ merge logs (highest op number wins)
  ├─ broadcast start_view(view=1, log, op, commit_num)
  │
Replicas install new view ──► resume Normal state
```

**View Change Bound**: < 300 ms (50 ms timeout × 2 retries + 200 ms merge/broadcast).

---

## Transport Protocol

### Message Envelope

Every inter-node message has:

```
┌─────────────────────────────────────┐
│ Header (128 bytes, aligned)         │
├─────────────────────────────────────┤
│ Body (variable, up to 1 MB)         │
├─────────────────────────────────────┤
│ Ed25519 Signature (64 bytes)        │
└─────────────────────────────────────┘
```

**Header fields**:
- `magic: u32` = `0x54_49_47_52` ("TIGR")
- `version: u16` = `1`
- `command: u8` (see Message Types below)
- `checksum: u32` (CRC32C of header+body)
- `nonce: u64` (monotonic per sender; replay protection)
- `view: u32`
- `op: u64` (operation number)
- `commit_num: u64`
- `cluster_id: u128` (prevents cross-cluster message)
- `sender_id: u8` (replica 0..2)
- `body_size: u32`

**Signature**: Ed25519 over `header || body`. Public keys exchanged during cluster bootstrap.

**mTLS**: TLS 1.3 with certificate pinning; all replicas have pre-distributed certs.

---

## Message Types

### VSR Messages

| Command | Name | Direction | Body |
|---------|------|-----------|------|
| `0x01` | `prepare` | Primary → Replicas | `Message` (user op) |
| `0x02` | `prepare_ok` | Replicas → Primary | `{op, checksum}` |
| `0x03` | `commit` | Primary → Replicas | `{commit_num}` |
| `0x04` | `start_view_change` | Any → All | `{view}` |
| `0x05` | `do_view_change` | Replicas → New Primary | `{view, log[], op, commit}` |
| `0x06` | `start_view` | New Primary → All | `{view, log[], op, commit}` |
| `0x07` | `request` | Client → Primary | `Message` (forwarded by edge) |
| `0x08` | `reply` | Primary → Client | `{result, op}` |

### Client Messages

| Command | Name | Direction | Body |
|---------|------|-----------|------|
| `0x20` | `send_message` | Client → Edge | `SendMessageRequest` |
| `0x21` | `message_ack` | Edge → Client | `MessageAck` |
| `0x22` | `message_event` | Edge → Client | `MessageEvent` (fan-out) |
| `0x23` | `subscribe_room` | Client → Edge | `{room_id, since_op}` |
| `0x24` | `snapshot_request` | Client → Edge | `{room_id, until_op}` |
| `0x25` | `snapshot_chunk` | Edge → Client | `{messages[], has_more}` |

---

## Client Protocol (WebSocket)

### Connection Lifecycle

```
Client                    Edge Gateway
  │                           │
  ├──WS handshake + JWT───────►
  │                           ├─validate JWT
  │                           ├─rate limit check
  ◄──────────────────accept───┤
  │                           │
  ├──subscribe_room(room_id)──►
  │                           ├─forward to primary
  ◄──────────────────ack──────┤
  │                           │
  ├──send_message─────────────►
  │                           ├─assign idempotency key
  │                           ├─prepare to VSR primary
  │                           ├─wait quorum commit
  ◄──message_ack(op=1234)─────┤
  │                           │
  ◄──message_event────────────┤ (fan-out from bus)
  ◄──message_event────────────┤
  │                           │
```

**Idempotency**: Edge assigns `{client_id, client_seq}` → `op` mapping. Duplicate `send_message` returns cached `op`.

**Catch-up**: If client reconnects, sends `subscribe_room(since_op=last_seen)`. Edge sends buffered events or triggers snapshot.

---

## Data Structures

### Message (Log Entry)

```zig
const Message = extern struct {
    room_id: u128,        // shard key
    msg_id: u128,         // unique (UUID v7)
    author_id: u64,
    parent_id: u128,      // 0 for top-level; else thread parent
    timestamp: u64,       // microseconds since epoch
    body_len: u32,
    body: [2048]u8,       // max inline; larger → external blob
    checksum: u32,        // CRC32C(msg_id..body)
};
comptime {
    assert(@sizeOf(Message) == 2240);  // cache-line friendly
    assert(@alignOf(Message) == 16);
}
```

### RoomState (Deterministic State Machine)

```zig
const RoomState = struct {
    room_id: u128,
    op: u64,                  // last applied op
    commit_num: u64,
    message_count: u64,
    head_hash: [32]u8,        // SHA256 chain
    
    // in-memory index (not persisted; rebuilt from log)
    message_index: std.AutoHashMap(u128, u64),  // msg_id → op
};
```

### WAL Entry

```
┌────────────────────┐
│ op: u64            │
├────────────────────┤
│ checksum: u32      │ ─┐
├────────────────────┤  │ CRC32C of this region
│ Message (2240 B)   │ ─┘
└────────────────────┘
```

WAL append is **atomic**: write entry → fsync → update op pointer (atomic rename of metadata file).

---

## Crash Recovery

### On Restart

1. Read last checkpoint (snapshot at `op=N`).
2. Scan WAL from `N+1` to EOF.
3. Replay each entry through state machine.
4. Verify `head_hash` chain integrity (each message includes `prev_hash`).
5. If corruption detected → panic (operator must restore from replica).

### Snapshot Format

```
┌──────────────────────────┐
│ magic: u64 = 0x544947_534E4150 ("TIG_SNAP")
├──────────────────────────┤
│ version: u16 = 1         │
├──────────────────────────┤
│ room_id: u128            │
├──────────────────────────┤
│ op: u64                  │
├──────────────────────────┤
│ message_count: u64       │
├──────────────────────────┤
│ Message[0]               │
│ Message[1]               │
│ ...                      │
│ Message[N-1]             │
├──────────────────────────┤
│ Ed25519 signature        │
└──────────────────────────┘
```

Snapshot triggered every 10,000 ops or 1 GB WAL size.

---

## Security Properties

1. **Message Integrity**: Every WAL entry has CRC32C; every snapshot has Ed25519 signature.
2. **Replay Protection**: Nonce field in transport header; replicas reject `nonce ≤ last_seen[sender]`.
3. **View Monotonicity**: `view` must increase; replicas ignore `start_view` with `view ≤ current_view`.
4. **Cluster Isolation**: `cluster_id` prevents cross-cluster message injection.

---

## Performance Characteristics

- **Single-writer WAL**: No lock contention; one `fsync` per commit (group commit in future).
- **Bounded message size**: 2 KB inline → predictable latency, no heap allocation per message.
- **Zero-copy fan-out**: Edge replicas mmap committed log; send via `sendfile(2)`.
- **Tail latency**: All queues bounded; worst-case = 2× timeout (view change).

---

## Failure Scenarios

| Scenario | Detection | Recovery | Bound |
|----------|-----------|----------|-------|
| Primary crash | Prepare timeout (50 ms) | View change | 300 ms |
| Replica crash | Heartbeat miss | Ignore; quorum=2 sufficient | N/A |
| Network partition | Prepare timeout | View change if quorum lost | 300 ms |
| WAL corruption | CRC32C or hash chain failure | Panic → operator restore from peer | Manual |
| Byzantine message | Signature verification failure | Drop + alert | Immediate |

**Key invariant**: If 2+ replicas survive, no data loss.

---

## References

- Viewstamped Replication Revisited (Liskov & Cowling, 2012)
- TigerBeetle VOC protocol (visual consensus)
- NASA Power of Ten (bounded everything)
