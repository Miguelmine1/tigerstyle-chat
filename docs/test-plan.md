# TigerChat Test Plan

## Philosophy

> "Testing can show the presence of bugs, but not their absence." — Edsger Dijkstra

TigerChat uses **simulation-driven development**: every state transition, fault scenario, and invariant is tested in a deterministic discrete-event simulator before running on real hardware.

**Coverage goals**:
1. **100% of invariants** have negative tests (injected violations → panic).
2. **100% of message types** exercised in simulation.
3. **All failure modes** from PRD tested (primary crash, partition, corruption).
4. **30,000 random simulations** pass before release.

---

## Test Hierarchy

```
Unit Tests          (zig test)
    ↓
Property Tests      (zig test --property)
    ↓
Simulation Tests    (zig build sim)
    ↓
Stress Tests        (zig build stress)
    ↓
Fuzzing Harness     (zig build fuzz)
    ↓
Integration Tests   (zig build integration)
```

**Fast CI**: Unit + property tests (< 5 min).

**Slow CI**: Nightly simulation + fuzz (4 hours).

---

## 1. Unit Tests

### Purpose

Test individual functions and data structures in isolation.

### Coverage

| Module | Test Count | Focus |
|--------|-----------|-------|
| `message.zig` | 15 | Serialization, checksum, alignment |
| `wal.zig` | 20 | Append, read, fsync, corruption detection |
| `state_machine.zig` | 25 | Message insert, idempotency, hash chain |
| `transport.zig` | 18 | Header parsing, signature verify, nonce |
| `queue.zig` | 10 | Bounded depth, push/pop, wraparound |
| `view_change.zig` | 30 | View transitions, log merging |

**Total**: ~120 unit tests.

### Example: `message.zig` tests

```zig
test "Message: size and alignment" {
    try testing.expectEqual(2368, @sizeOf(Message));
    try testing.expectEqual(16, @alignOf(Message));
}

test "Message: checksum validation" {
    var msg = Message{
        .room_id = 1,
        .msg_id = 123,
        .author_id = 456,
        .parent_id = 0,
        .timestamp = 1000,
        .sequence = 1,
        .body_len = 5,
        .flags = 0,
        .body = undefined,
        .prev_hash = [_]u8{0} ** 32,
        .checksum = 0,
        .reserved = 0,
    };
    @memcpy(msg.body[0..5], "hello");
    msg.checksum = msg.calculate_checksum();
    
    try testing.expect(msg.verify_checksum());
    
    // Corrupt checksum
    msg.checksum ^= 0x1;
    try testing.expect(!msg.verify_checksum());
}

test "Message: hash chain" {
    var msg1 = create_test_message(1);
    var msg2 = create_test_message(2);
    
    msg2.prev_hash = sha256(&msg1);
    try testing.expect(msg2.verify_prev_hash(&msg1));
}
```

### Running

```bash
zig build test                    # All unit tests
zig build test -Dfilter=message   # Specific module
```

---

## 2. Property Tests

### Purpose

Generative testing with randomized inputs to find edge cases.

### Strategy

Use Zig's built-in property testing (when available) or custom fuzz loops.

### Example: Idempotency property

```zig
test "Property: idempotency table enforces uniqueness" {
    var table = IdempotencyTable.init(testing.allocator);
    defer table.deinit();
    
    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();
    
    var i: u32 = 0;
    while (i < 10000) : (i += 1) {
        const client_id = random.int(u64);
        const client_seq = random.int(u64);
        const op = random.int(u64);
        
        const result1 = try table.get_or_put(client_id, client_seq, op);
        const result2 = try table.get_or_put(client_id, client_seq, op);
        
        // Second call must return same op
        try testing.expectEqual(result1, result2);
    }
}
```

### Running

```bash
zig build test --property         # Enable property tests
zig build test -Dseed=42          # Reproducible seed
```

---

## 3. Simulation Tests

### Purpose

Deterministic discrete-event simulation of distributed system with fault injection.

### Architecture

```
Simulator
    ├── Virtual Time (no wall clock)
    ├── Deterministic PRNG (seeded)
    ├── Network (controllable delays, drops, reorders)
    ├── Disk I/O (inject corruption, latency)
    └── Replicas (3-node cluster)
```

**Key properties**:
- **Deterministic**: Same seed → same execution.
- **Fast**: No actual I/O; events scheduled in memory.
- **Controllable**: Inject faults at specific virtual timestamps.

### Core Simulation Harness

Located in `src/simulation.zig`.

```zig
const Simulator = struct {
    prng: std.rand.DefaultPrng,
    time: u64,  // Virtual microseconds
    events: PriorityQueue(Event),
    network: VirtualNetwork,
    replicas: [3]Replica,
    
    pub fn init(seed: u64) Simulator { ... }
    
    pub fn run_until(self: *Simulator, max_time: u64) void {
        while (self.time < max_time and !self.events.isEmpty()) {
            const event = self.events.dequeue();
            self.time = event.timestamp;
            self.handle_event(event);
        }
    }
    
    pub fn inject_fault(self: *Simulator, fault: Fault) void { ... }
};
```

### Event Types

```zig
const Event = union(enum) {
    client_send: struct { room_id: u128, body: []const u8 },
    replica_prepare: struct { replica: u8, message: Message },
    replica_prepare_ok: struct { replica: u8, op: u64 },
    replica_commit: struct { replica: u8, commit_num: u64 },
    replica_crash: struct { replica: u8 },
    replica_recover: struct { replica: u8 },
    network_deliver: struct { from: u8, to: u8, message: TransportHeader },
    timeout: struct { replica: u8 },
};
```

### Fault Injection

```zig
const Fault = union(enum) {
    primary_crash: struct { at_time: u64 },
    network_partition: struct { at_time: u64, duration: u64, isolated: u8 },
    disk_corruption: struct { replica: u8, op: u64 },
    message_drop: struct { from: u8, to: u8, probability: f64 },
    message_delay: struct { min_us: u64, max_us: u64 },
    clock_skew: struct { replica: u8, skew_us: i64 },
};
```

### Simulation Test Catalog

#### Basic VSR Flow

```zig
test "Simulation: normal case commit" {
    var sim = Simulator.init(1234);
    
    // Client sends message
    sim.schedule(.{ .client_send = .{
        .room_id = 1,
        .body = "hello",
    }}, 0);
    
    sim.run_until(1_000_000);  // 1 second
    
    // All replicas should commit
    for (sim.replicas) |replica| {
        try testing.expectEqual(1, replica.commit_num);
        try testing.expectEqual(1, replica.state.message_count);
    }
}
```

#### View Change Scenarios

```zig
test "Simulation: primary crash triggers view change" {
    var sim = Simulator.init(5678);
    
    // Send message, then crash primary mid-prepare
    sim.schedule(.{ .client_send = .{ .room_id = 1, .body = "msg1" }}, 0);
    sim.inject_fault(.{ .primary_crash = .{ .at_time = 50_000 }});  // 50ms
    
    sim.run_until(10_000_000);  // 10 seconds
    
    // View change should complete
    try testing.expect(sim.replicas[1].view == 1 or sim.replicas[2].view == 1);
    
    // Message should eventually commit
    const committed = sim.replicas[1].commit_num > 0 or sim.replicas[2].commit_num > 0;
    try testing.expect(committed);
    
    // Measure view change duration
    const vc_duration = sim.get_view_change_duration();
    try testing.expect(vc_duration < 300_000);  // < 300ms
}
```

#### Network Partition

```zig
test "Simulation: network partition with quorum" {
    var sim = Simulator.init(9999);
    
    // Partition replica 2 (primary + replica 1 still have quorum)
    sim.inject_fault(.{ .network_partition = .{
        .at_time = 0,
        .duration = 5_000_000,  // 5 seconds
        .isolated = 2,
    }});
    
    // Send messages
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        sim.schedule(.{ .client_send = .{
            .room_id = 1,
            .body = "test",
        }}, i * 10_000);  // 10ms apart
    }
    
    sim.run_until(10_000_000);
    
    // Primary and replica 1 should commit all
    try testing.expectEqual(100, sim.replicas[0].commit_num);
    try testing.expectEqual(100, sim.replicas[1].commit_num);
    
    // After partition heals, replica 2 catches up
    try testing.expectEqual(100, sim.replicas[2].commit_num);
}
```

#### Invariant Violation Detection

```zig
test "Simulation: duplicate op panics" {
    var sim = Simulator.init(4242);
    
    // Manually inject duplicate prepare (should never happen in correct code)
    const msg = create_test_message(1);
    sim.replicas[1].append_to_log(1, msg);
    
    // Attempt duplicate
    const result = sim.replicas[1].append_to_log(1, msg);
    try testing.expectError(error.InvariantViolation, result);
}
```

### Simulation Test Suite

| Test ID | Scenario | Faults | Invariants Checked | Duration |
|---------|----------|--------|-------------------|----------|
| `sim_001` | Normal commit | None | S1, S2, S3 | 1s |
| `sim_002` | Primary crash | Replica 0 crash at 50ms | S4, L1 | 10s |
| `sim_003` | Replica crash | Replica 2 crash at 100ms | S2 | 5s |
| `sim_004` | Network partition (quorum) | Partition replica 2 | S7 | 10s |
| `sim_005` | Network partition (no quorum) | Partition replicas 1,2 | L1 | 10s |
| `sim_006` | Message reorder | Random delays | S3, S8 | 5s |
| `sim_007` | Message drop 10% | Drop probability 0.1 | S2, L1 | 10s |
| `sim_008` | Clock skew | Skew ±1s | S8 | 5s |
| `sim_009` | WAL corruption | Bit flip at op 50 | S5 | 5s |
| `sim_010` | Duplicate client send | Same msg sent 3× | S6 | 2s |
| `sim_011` | Concurrent rooms | 10 rooms, 100 msgs each | S7 | 30s |
| `sim_012` | View change cascade | Crash new primary immediately | L1 | 15s |
| `sim_013` | Replay attack | Inject old nonce | SE2 | 5s |
| `sim_014` | Invalid signature | Flip signature bit | SE1 | 2s |
| `sim_015` | Cross-cluster message | Wrong cluster_id | SE3 | 2s |

**Total**: 15 deterministic simulations.

### Random Simulation Suite

```zig
test "Simulation: 30k random scenarios" {
    var seed: u64 = 1;
    while (seed <= 30_000) : (seed += 1) {
        var sim = Simulator.init(seed);
        
        // Random workload
        const msg_count = sim.prng.random().intRangeAtMost(u32, 10, 1000);
        const fault_count = sim.prng.random().intRangeAtMost(u32, 0, 5);
        
        // Inject random faults
        var f: u32 = 0;
        while (f < fault_count) : (f += 1) {
            const fault = generate_random_fault(&sim.prng);
            sim.inject_fault(fault);
        }
        
        // Send messages
        var m: u32 = 0;
        while (m < msg_count) : (m += 1) {
            sim.schedule_client_send(m * 1000);
        }
        
        sim.run_until(60_000_000);  // 60 seconds virtual time
        
        // Verify all invariants
        try verify_all_invariants(&sim);
    }
}
```

**Release gate**: All 30k seeds pass with zero invariant violations.

### Running Simulations

```bash
zig build sim                     # Run deterministic suite
zig build sim -Dseed=12345        # Specific seed
zig build sim-random -Dcount=30000  # Random suite (nightly CI)
```

---

## 4. Stress Tests

### Purpose

Push system to resource limits; verify bounded behavior.

### Tests

#### High Throughput

```zig
test "Stress: 100k messages per second" {
    var cluster = try start_test_cluster();
    defer cluster.stop();
    
    const start = std.time.milliTimestamp();
    
    var sent: u32 = 0;
    while (sent < 100_000) : (sent += 1) {
        try cluster.send_message(1, "test message");
    }
    
    // Wait for all commits
    while (cluster.replicas[0].commit_num < 100_000) {
        std.time.sleep(1 * std.time.ns_per_ms);
    }
    
    const duration_ms = std.time.milliTimestamp() - start;
    const throughput = 100_000 * 1000 / duration_ms;
    
    std.debug.print("Throughput: {} ops/sec\n", .{throughput});
    try testing.expect(throughput >= 100_000);
}
```

#### Memory Stability

```zig
test "Stress: no allocations in hot path" {
    var cluster = try start_test_cluster();
    defer cluster.stop();
    
    // Use FailingAllocator to detect allocations
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, 0);
    cluster.replicas[0].allocator = failing_allocator.allocator();
    
    // Send messages (should not allocate)
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try cluster.send_message(1, "test");
    }
    
    try testing.expectEqual(0, failing_allocator.allocated_bytes);
}
```

#### Connection Flood

```zig
test "Stress: 10k concurrent WebSocket connections" {
    var edge = try start_test_edge();
    defer edge.stop();
    
    var connections: [10_000]WebSocketClient = undefined;
    
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        connections[i] = try WebSocketClient.connect(edge.address);
    }
    
    // All should be accepted (up to FD limit)
    const accepted = count_connected(&connections);
    try testing.expect(accepted <= 1000);  // R2: FD limit enforced
    
    // Cleanup
    for (connections) |*conn| conn.close();
}
```

### Running Stress Tests

```bash
zig build stress                  # All stress tests
zig build stress -Dduration=3600  # Run for 1 hour
```

---

## 5. Fuzzing Harness

### Purpose

Discover crashes, hangs, and memory corruption with adversarial inputs.

### Tools

- **AFL++**: American Fuzzy Lop for parser fuzzing.
- **libFuzzer**: LLVM's coverage-guided fuzzer.
- **Custom harness**: Zig-based fuzzer with domain knowledge.

### Fuzz Targets

#### Message Deserialization

```zig
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    if (size < @sizeOf(TransportHeader)) return 0;
    
    const buffer = data[0..size];
    
    // Attempt to parse
    const result = parse_transport_message(buffer);
    
    // Should either succeed or return error (not crash)
    _ = result catch |err| {
        assert(err == error.InvalidChecksum or 
               err == error.InvalidSignature or
               err == error.MessageTooLarge);
        return 0;
    };
    
    // If parsed, verify invariants
    const header = result;
    assert(header.magic == 0x54494752);
    assert(header.version <= 1);
    
    return 0;
}
```

#### WAL Parser

```zig
export fn fuzz_wal_parse(data: [*]const u8, size: usize) c_int {
    if (size < 16) return 0;
    
    var wal = WAL.init_from_bytes(data[0..size]) catch return 0;
    defer wal.deinit();
    
    // Scan all entries
    while (wal.next_entry()) |entry| {
        // Verify each entry
        _ = entry.verify() catch return 0;
    }
    
    return 0;
}
```

#### State Machine Operations

```zig
export fn fuzz_state_machine(data: [*]const u8, size: usize) c_int {
    var sm = StateMachine.init();
    defer sm.deinit();
    
    // Interpret data as sequence of operations
    var offset: usize = 0;
    while (offset + @sizeOf(Message) <= size) {
        const msg_bytes = data[offset..offset + @sizeOf(Message)];
        const msg = @ptrCast(*const Message, @alignCast(@alignOf(Message), msg_bytes.ptr));
        
        // Attempt to apply
        _ = sm.apply(msg) catch {};
        
        offset += @sizeOf(Message);
    }
    
    // Verify final invariants
    assert(sm.message_count == sm.messages.len);
    
    return 0;
}
```

### Fuzzing Campaign

```bash
# Build fuzz targets
zig build fuzz-targets

# Run AFL++
afl-fuzz -i corpus/ -o findings/ ./zig-out/bin/fuzz_message

# Run libFuzzer
./zig-out/bin/fuzz_wal -max_total_time=3600  # 1 hour

# Reproduce crash
./zig-out/bin/fuzz_message < findings/crashes/id:000000
```

### Coverage Goals

- **Line coverage**: > 90% for parsing code.
- **Branch coverage**: > 85% for state machine.
- **Corpus size**: > 10,000 inputs without crashes.

---

## 6. Integration Tests

### Purpose

End-to-end tests with real network and disk I/O.

### Setup

```zig
test "Integration: 3-node cluster with real I/O" {
    // Start 3 replicas on localhost:9001, 9002, 9003
    var cluster = try IntegrationCluster.start(&.{
        .replica_count = 3,
        .use_real_network = true,
        .use_real_disk = true,
        .data_dir = "/tmp/tigerchat-test",
    });
    defer cluster.cleanup();
    
    // Wait for cluster ready
    try cluster.wait_healthy(5 * std.time.ns_per_s);
    
    // Client sends message
    const client = try ChatClient.connect("ws://localhost:8000");
    defer client.disconnect();
    
    try client.subscribe_room(1);
    const ack = try client.send_message(1, "Hello TigerChat!");
    
    // Verify commit
    try testing.expect(ack.op > 0);
    
    // Verify all replicas have it
    try cluster.wait_commit(ack.op);
    
    for (cluster.replicas) |replica| {
        const msg = try replica.get_message(ack.msg_id);
        try testing.expectEqualStrings("Hello TigerChat!", msg.body[0..msg.body_len]);
    }
}
```

### Scenarios

1. **Client lifecycle**: Connect, subscribe, send, receive, disconnect.
2. **Replica restart**: Graceful shutdown, recovery from WAL.
3. **Operator commands**: Drain, status check.
4. **Multi-room**: 100 concurrent rooms, 10 clients each.
5. **Snapshot restoration**: Trigger snapshot, restart, verify state.

### Running Integration Tests

```bash
zig build integration              # Local 3-node cluster
zig build integration-distributed  # 3 VMs (CI only)
```

---

## 7. Performance Benchmarks

### Purpose

Verify latency and throughput targets from PRD.

### Benchmarks

```zig
test "Benchmark: message latency P99 < 5ms" {
    var cluster = try start_test_cluster();
    defer cluster.stop();
    
    var latencies: [10_000]u64 = undefined;
    
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const start = std.time.microTimestamp();
        const ack = try cluster.send_message(1, "bench");
        const end = std.time.microTimestamp();
        
        latencies[i] = @intCast(u64, end - start);
    }
    
    std.sort.sort(u64, &latencies, {}, comptime std.sort.asc(u64));
    
    const p50 = latencies[5_000];
    const p99 = latencies[9_900];
    const p999 = latencies[9_990];
    
    std.debug.print("Latency: P50={}us P99={}us P99.9={}us\n", .{p50, p99, p999});
    
    try testing.expect(p99 < 5_000);  // 5ms target
}
```

### Running Benchmarks

```bash
zig build bench                    # All benchmarks
zig build bench -Drelease=fast     # Optimized build
```

---

## Release Checklist

Before tagging a release:

- [ ] All unit tests pass: `zig build test`
- [ ] All simulation tests pass: `zig build sim`
- [ ] 30k random simulations pass: `zig build sim-random -Dcount=30000`
- [ ] All stress tests pass: `zig build stress`
- [ ] Fuzz for 24 hours without crash: `zig build fuzz-campaign`
- [ ] Integration tests pass: `zig build integration`
- [ ] Benchmarks meet targets: `zig build bench`
- [ ] Zero invariant violations in CI logs
- [ ] Performance within 2% of baseline

---

## Continuous Integration

### Fast CI (< 5 min)

```yaml
- zig build test
- zig build sim -Dquick  # First 100 seeds
- zig build lint
```

### Nightly CI (4 hours)

```yaml
- zig build sim-random -Dcount=30000
- zig build fuzz-campaign -Dduration=14400  # 4 hours
- zig build stress -Dduration=3600
- zig build integration-distributed
```

---

## Summary

| Test Type | Count | Duration | CI Frequency |
|-----------|-------|----------|--------------|
| Unit | ~120 | 30s | Every commit |
| Property | ~30 | 2min | Every commit |
| Simulation | 15 deterministic | 3min | Every commit |
| Simulation | 30k random | 2hrs | Nightly |
| Stress | 5 | 30min | Nightly |
| Fuzz | 3 targets | 4hrs | Nightly |
| Integration | 5 | 10min | Every merge |
| Benchmark | 4 | 5min | Every merge |

**Total coverage**: Safety-critical code paths tested **>10,000 times** before production.
