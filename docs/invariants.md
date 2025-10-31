# TigerChat Invariants

## Purpose

Invariants are properties that **must hold at all times** in the system. Violations indicate bugs that require immediate crash (via assertion) to prevent corruption. This document catalogs all critical invariants, their verification points, and simulation coverage.

**Design principle**: Assertions downgrade catastrophic correctness bugs into liveness bugs.

---

## Classification

| Category | Description | Violation Severity |
|----------|-------------|-------------------|
| **Safety** | Correctness properties (no data loss, no reordering) | **CRITICAL** — Data corruption |
| **Liveness** | Progress guarantees (bounded delays) | **HIGH** — Service degradation |
| **Security** | Authentication, integrity, isolation | **CRITICAL** — Security breach |
| **Resource** | Bounded memory, file handles, connections | **HIGH** — DoS / OOM |

---

## Safety Invariants

### S1: Log Monotonicity

**Property**: For any replica, `op` numbers are strictly monotonic.

```zig
assert(new_op == last_op + 1);
```

**Why**: Gaps or duplicates break VSR correctness; replicas diverge.

**Verification points**:
- Before appending to WAL (`replica.zig:append_to_log`)
- On startup during log replay (`recovery.zig:replay_log`)

**Test coverage**: Simulation inject duplicate `prepare` → must panic.

---

### S2: Quorum Agreement

**Property**: If primary commits at `op=N`, at least `f+1` replicas have `op=N` in their log.

For 3 replicas, `f=1`, quorum = 2.

```zig
assert(prepare_ok_count >= quorum);  // quorum = (n + 1) / 2
```

**Why**: VSR safety depends on majority; without quorum, split-brain is possible.

**Verification points**:
- Before sending `commit` message (`primary.zig:on_prepare_ok`)
- Before advancing `commit_num` (`replica.zig:on_commit`)

**Test coverage**: Simulation with network partition → primary must not commit without quorum.

---

### S3: Commit Ordering

**Property**: If `commit_num = N`, then all ops `[1..N]` are committed and applied to state machine.

```zig
assert(commit_num <= op);
assert(state.last_applied == commit_num);
```

**Why**: Gaps in applied log break state machine consistency.

**Verification points**:
- After state machine transition (`state_machine.zig:apply`)
- On checkpoint creation (`snapshot.zig:create_snapshot`)

**Test coverage**: Fuzz test with random replica crashes → verify no gaps after recovery.

---

### S4: View Monotonicity

**Property**: `view` never decreases; `view_change` increments by exactly 1.

```zig
assert(new_view == current_view + 1);
assert(message.view >= replica.view);
```

**Why**: Stale views allow Byzantine replay attacks.

**Verification points**:
- On receiving `start_view_change` (`view_change.zig:on_start_view_change`)
- On installing new view (`view_change.zig:install_view`)

**Test coverage**: Simulation inject old `start_view` message → must be rejected.

---

### S5: Hash Chain Integrity

**Property**: Each message's `prev_hash` equals `SHA256(Message[op-1])`.

```zig
const expected_hash = sha256(&messages[op - 1]);
assert(std.mem.eql(u8, &message.prev_hash, &expected_hash));
```

**Why**: Detects WAL corruption, tampering, or out-of-order writes.

**Verification points**:
- On WAL append (`wal.zig:write_entry`)
- On log replay (`recovery.zig:verify_hash_chain`)

**Test coverage**: Inject bit-flip in WAL file → recovery must panic.

---

### S6: Idempotency Uniqueness

**Property**: Each `{client_id, client_seq}` maps to exactly one `op`.

```zig
const existing_op = idempotency_table.get(client_key);
if (existing_op) |op| {
    assert(op == current_op);  // Must match if duplicate
}
```

**Why**: Prevents duplicate message insertion on client retry.

**Verification points**:
- On receiving `send_message` from client (`edge.zig:on_send_message`)
- On state machine apply (`state_machine.zig:apply_message`)

**Test coverage**: Simulation with network retries → verify exactly-once delivery.

---

### S7: Room Isolation

**Property**: Messages for `room_id=A` never appear in `room_id=B`.

```zig
assert(message.room_id == shard.room_id);
```

**Why**: Cross-room contamination breaks multi-tenancy security.

**Verification points**:
- Before appending to shard WAL (`shard.zig:accept_message`)
- On fan-out dispatch (`fanout.zig:publish`)

**Test coverage**: Fuzz test with random `room_id` → verify isolation.

---

### S8: Timestamp Monotonicity (per room)

**Property**: Within a room, `message[N].timestamp ≥ message[N-1].timestamp`.

```zig
assert(message.timestamp >= last_message.timestamp);
```

**Why**: Client UI sorting depends on monotonic timestamps.

**Verification points**:
- On message insertion (`state_machine.zig:insert_message`)

**Test coverage**: Simulation with clock skew → verify logical clock.

---

## Liveness Invariants

### L1: View Change Completion Bound

**Property**: View change completes within 300 ms.

```zig
assert(view_change_duration_ms <= 300);
```

**Why**: Unbounded view changes cause indefinite unavailability.

**Verification points**:
- Measure time from `start_view_change` to `start_view` (`metrics.zig:record_view_change`)

**Test coverage**: Simulation with primary crash → measure recovery time.

---

### L2: Queue Bounded Depth

**Property**: All queues have fixed upper bounds.

```zig
const max_pending_prepares = 1000;
assert(pending_queue.len <= max_pending_prepares);
```

**Why**: Unbounded queues cause OOM and tail latency spikes.

**Verification points**:
- Before enqueue (`queue.zig:push`)

**Test coverage**: Stress test with backpressure → verify queue caps enforced.

---

### L3: WAL Append Latency

**Property**: `fsync` completes within 10 ms (P99).

```zig
const fsync_start = std.time.microTimestamp();
try file.sync();
const fsync_duration = std.time.microTimestamp() - fsync_start;
assert(fsync_duration < 10_000);  // 10 ms
```

**Why**: Slow `fsync` cascades to client-visible latency.

**Verification points**:
- After WAL write (`wal.zig:fsync`)

**Test coverage**: Benchmark suite with SSD/NVMe → verify P99.

---

### L4: No Infinite Loops

**Property**: All loops have explicit termination bounds or timeout.

```zig
var iterations: u32 = 0;
while (condition) : (iterations += 1) {
    assert(iterations < max_iterations);  // Fail-fast
    // ...
}
```

**Why**: Infinite loops violate liveness; system hangs.

**Verification points**:
- Code review + static analysis (Zig comptime check where possible)

**Test coverage**: Fuzzing with adversarial inputs.

---

## Security Invariants

### SE1: Signature Validation

**Property**: All inter-node messages have valid Ed25519 signatures.

```zig
const valid = ed25519.verify(header.signature, message_bytes, sender_pubkey);
assert(valid);
```

**Why**: Prevents message injection and Byzantine attacks.

**Verification points**:
- Before processing any VSR message (`transport.zig:receive_message`)

**Test coverage**: Inject message with wrong signature → must be rejected.

---

### SE2: Nonce Anti-Replay

**Property**: For each sender, `nonce` is strictly increasing.

```zig
const last_nonce = nonce_table.get(sender_id);
assert(message.nonce > last_nonce);
nonce_table.put(sender_id, message.nonce);
```

**Why**: Prevents replay attacks.

**Verification points**:
- On message receipt (`transport.zig:check_nonce`)

**Test coverage**: Inject duplicate `nonce` → must be rejected.

---

### SE3: Cluster Isolation

**Property**: Messages with wrong `cluster_id` are rejected.

```zig
assert(message.cluster_id == config.cluster_id);
```

**Why**: Prevents cross-cluster message injection.

**Verification points**:
- On message receipt (`transport.zig:validate_cluster`)

**Test coverage**: Send message from different cluster → must be dropped.

---

### SE4: Checksum Integrity

**Property**: All messages have valid CRC32C checksums.

```zig
const calculated = crc32c(message_bytes);
assert(calculated == message.checksum);
```

**Why**: Detects corruption in transit or storage.

**Verification points**:
- On message receipt (`transport.zig:validate_checksum`)
- On WAL read (`wal.zig:read_entry`)

**Test coverage**: Inject bit-flip → must be detected and rejected.

---

## Resource Invariants

### R1: Fixed Memory Allocation

**Property**: No heap allocations in hot path (message processing).

```zig
// Use stack buffers or pre-allocated pools
var buffer: [4096]u8 align(64) = undefined;
```

**Why**: Predictable latency; no GC pauses or fragmentation.

**Verification points**:
- Code review + allocator tracking in debug builds

**Test coverage**: Run with `testing.FailingAllocator` on hot paths.

---

### R2: File Descriptor Bound

**Property**: Total open FDs ≤ `max_fds = 1000`.

```zig
assert(open_fds_count <= max_fds);
```

**Why**: Prevents FD exhaustion.

**Verification points**:
- Before opening file or socket (`io.zig:open`)

**Test coverage**: Stress test with connection flood → verify limit enforced.

---

### R3: Message Size Bound

**Property**: All messages ≤ 1 MB.

```zig
assert(message.size <= max_message_size);  // max_message_size = 1 << 20
```

**Why**: Prevents DoS via oversized messages.

**Verification points**:
- On message receipt (`transport.zig:receive`)

**Test coverage**: Send 10 MB message → must be rejected.

---

### R4: WAL Size Bound (before snapshot)

**Property**: WAL triggers snapshot when size ≥ 1 GB or op count ≥ 10,000.

```zig
if (wal.size >= max_wal_size or wal.op_count >= max_ops_before_snapshot) {
    try create_snapshot();
}
```

**Why**: Prevents unbounded disk usage and slow recovery.

**Verification points**:
- After WAL append (`wal.zig:maybe_snapshot`)

**Test coverage**: Fill WAL → verify snapshot triggered.

---

## Cross-Cutting Invariants

### X1: Deterministic State Machine

**Property**: Same sequence of `Message` → same `RoomState`.

```zig
// Given two replicas with identical logs:
assert(replica1.state.head_hash == replica2.state.head_hash);
```

**Why**: VSR requires deterministic replicas for consensus.

**Verification points**:
- Simulation with multiple replicas → compare final states

**Test coverage**: Replay log on two replicas → assert identical output.

---

### X2: No Undefined Behavior

**Property**: All memory accesses within bounds; no uninitialized reads.

```zig
// Zig's safety checks (in ReleaseSafe mode):
// - Bounds checking on array access
// - Null pointer dereference detection
```

**Why**: UB causes non-determinism and security vulnerabilities.

**Verification points**:
- Compile with `ReleaseSafe` in production
- Run AddressSanitizer in CI

**Test coverage**: Fuzz all parsers and deserializers.

---

## Invariant Enforcement Strategy

### Compile-Time Assertions

```zig
comptime {
    // Struct layout
    assert(@sizeOf(Message) == 2368);
    assert(@alignOf(TransportHeader) == 16);
    
    // Configuration
    assert(quorum == (replica_count + 1) / 2);
}
```

### Runtime Assertions (Release Safe)

```zig
// Always enabled, even in production
assert(op == last_op + 1);
assert(checksum_valid);
```

**Note**: Use `std.debug.assert` only for debug builds; use bare `assert` for production.

### Simulation Coverage

Each invariant must have:
1. **Positive test**: Normal operation satisfies invariant.
2. **Negative test**: Injected fault triggers assertion (verified to panic).

Example:
```zig
test "S1: log monotonicity violation panics" {
    var replica = try Replica.init();
    try replica.append_op(1);
    
    // Attempt to append duplicate op → should panic
    expect_panic(replica.append_op(1));
}
```

---

## Invariant Checklist for Code Review

Before merging any PR:

- [ ] All new functions assert preconditions (inputs) and postconditions (outputs).
- [ ] All loops have explicit bounds or timeout.
- [ ] All array accesses use bounded indices.
- [ ] All message parsing validates checksums before use.
- [ ] No heap allocation in VSR hot path.
- [ ] Simulation test covers new invariant.

---

## Invariant Violations in Production

**Incident response**:

1. **Crash immediately** (by design).
2. Capture core dump + logs.
3. Alert operator via metrics/audit log.
4. Operator restores from healthy replica.

**Root cause analysis**:

- Reproduce in simulation with recorded trace.
- Fix bug, add regression test.
- Verify fix passes 30k random simulations.

---

## Summary Table

| ID | Invariant | Category | Assert Location | Sim Test ID |
|----|-----------|----------|-----------------|-------------|
| S1 | Log monotonicity | Safety | `replica.zig:210` | `sim_duplicate_op` |
| S2 | Quorum agreement | Safety | `primary.zig:156` | `sim_partition_quorum` |
| S3 | Commit ordering | Safety | `replica.zig:340` | `sim_gap_commit` |
| S4 | View monotonicity | Safety | `view_change.zig:89` | `sim_stale_view` |
| S5 | Hash chain integrity | Safety | `wal.zig:120` | `sim_wal_corruption` |
| S6 | Idempotency uniqueness | Safety | `edge.zig:234` | `sim_duplicate_send` |
| S7 | Room isolation | Safety | `shard.zig:67` | `fuzz_room_id` |
| S8 | Timestamp monotonicity | Safety | `state_machine.zig:145` | `sim_clock_skew` |
| L1 | View change < 300ms | Liveness | `metrics.zig:45` | `sim_view_change_latency` |
| L2 | Queue depth bounded | Liveness | `queue.zig:78` | `stress_backpressure` |
| L3 | fsync < 10ms P99 | Liveness | `wal.zig:89` | `bench_fsync` |
| L4 | No infinite loops | Liveness | (code review) | `fuzz_adversarial` |
| SE1 | Signature valid | Security | `transport.zig:123` | `sim_invalid_signature` |
| SE2 | Nonce anti-replay | Security | `transport.zig:134` | `sim_replay_attack` |
| SE3 | Cluster isolation | Security | `transport.zig:99` | `sim_cross_cluster` |
| SE4 | Checksum valid | Security | `transport.zig:112` | `sim_bit_flip` |
| R1 | No hot-path allocs | Resource | (allocator test) | `stress_no_alloc` |
| R2 | FD count ≤ 1000 | Resource | `io.zig:56` | `stress_fd_exhaustion` |
| R3 | Message ≤ 1 MB | Resource | `transport.zig:89` | `fuzz_oversized_msg` |
| R4 | WAL snapshot trigger | Resource | `wal.zig:234` | `stress_wal_fill` |
| X1 | Deterministic SM | Cross-cutting | `simulation.zig:567` | `sim_determinism` |
| X2 | No UB | Cross-cutting | (sanitizers) | `fuzz_all_parsers` |

**Total invariants**: 22

**Simulation coverage requirement**: 100% of invariants must have at least one negative test (injected violation → panic).

**Release gate**: Zero invariant violations in 30,000 random simulations.
