#!/bin/bash
# Create Phase 2-5 issues

cd "$(dirname "$0")/.."

echo "Creating Phase 2 issues..."

# Phase 2: Edge & Fan-out
gh issue create --title "Implement WebSocket server" --label "infrastructure,P2: Edge & Fan-out" --body "**Depends on**: #16

WebSocket support in \`src/edge.zig\`:
- WS handshake, frame parsing
- Connection lifecycle
- Bounded connection pool

**Invariants**: R2

**Acceptance**:
- [ ] WS handshake works
- [ ] Frames sent/received
- [ ] Connection limit enforced"

gh issue create --title "Implement JWT authentication" --label "safety,P2: Edge & Fan-out" --body "**Depends on**: #20

Auth in \`src/edge.zig\`:
- JWT validation on connection
- Short-lived tokens
- Room authorization

**Acceptance**:
- [ ] Valid JWT allows connection
- [ ] Expired JWT rejected
- [ ] Invalid signature rejected"

gh issue create --title "Implement rate limiting" --label "safety,P2: Edge & Fan-out" --body "**Depends on**: #20

Rate limiter in \`src/edge.zig\`:
- Per-client message rate limit
- Token bucket or sliding window
- Reject over-limit messages

**Acceptance**:
- [ ] Rate limit enforced
- [ ] Over-limit rejected
- [ ] Stress test: cannot exceed"

gh issue create --title "Implement client message forwarding" --label "safety,P2: Edge & Fan-out" --body "**Depends on**: #21, #11

Edge to VSR forwarding:
- Receive send_message from client
- Assign idempotency key
- Forward as VSR prepare
- Track pending requests

**Invariants**: S6

**Acceptance**:
- [ ] Client forwarded to primary
- [ ] Duplicate sends return cached op
- [ ] Integration: client send → commit"

gh issue create --title "Implement message acknowledgment" --label "P2: Edge & Fan-out" --body "**Depends on**: #23

Implement message_ack:
- Wait for VSR commit
- Send message_ack with op
- Handle timeouts

**Acceptance**:
- [ ] Ack sent after commit
- [ ] Timeout returns error
- [ ] Integration: client receives ack"

gh issue create --title "Implement fan-out pub/sub bus" --label "performance,P2: Edge & Fan-out" --body "**Depends on**: #11

Implement \`src/fanout.zig\`:
- In-memory pub/sub per room
- Subscribe clients to room_id
- Publish committed messages
- Bounded subscriber list

**Invariants**: R1

**Acceptance**:
- [ ] Clients subscribe
- [ ] Published messages reach all
- [ ] Subscriber limit enforced
- [ ] Performance: 10k subscribers"

gh issue create --title "Integrate fan-out with VSR commits" --label "P2: Edge & Fan-out" --body "**Depends on**: #25, #11

Hook fan-out into commit:
- After VSR commit, publish to bus
- Edge subscriptions receive message_event
- Send to WebSocket clients

**Acceptance**:
- [ ] Committed messages published
- [ ] Subscribed clients receive events
- [ ] Integration: end-to-end delivery"

gh issue create --title "Implement room subscription" --label "P2: Edge & Fan-out" --body "**Depends on**: #26

Implement subscribe_room:
- Client sends subscribe_room
- Edge registers with fan-out
- Catch-up: if since_op > 0, send buffered

**Acceptance**:
- [ ] Client subscribes
- [ ] Receives live messages
- [ ] Catch-up sends historical
- [ ] Integration: reconnect + catch-up"

gh issue create --title "Implement snapshot/history API" --label "P2: Edge & Fan-out" --body "**Depends on**: #7, #27

Snapshot request in \`src/edge.zig\`:
- Client requests history
- Stream snapshot_chunk (100 msgs each)
- Read from WAL or snapshot

**Acceptance**:
- [ ] Client requests snapshot
- [ ] Receives chunked history
- [ ] Integration: fetch 10k history"

gh issue create --title "End-to-end Phase 2 testing" --label "testing,P2: Edge & Fan-out" --body "**Depends on**: #28

Comprehensive P2 testing:
- Integration: WS client send + receive
- Integration: Multiple clients same room
- Integration: Client reconnect + catch-up
- Stress: 1000 concurrent clients
- Performance: P99 fan-out < 2ms

**Acceptance**:
- [ ] End-to-end WS works
- [ ] Multiple clients receive same message
- [ ] 1000 concurrent supported
- [ ] P99 fan-out < 2ms"

echo "Creating Phase 3 issues..."

# Phase 3: Testing
gh issue create --title "Implement simulation framework" --label "testing,P3: Testing" --body "**Depends on**: #18

Implement \`src/simulation.zig\`:
- Virtual time (no wall clock)
- Deterministic PRNG
- Event queue (priority queue)
- Virtual network
- Replica instances

**Acceptance**:
- [ ] Deterministic (same seed → same result)
- [ ] Virtual time advances correctly
- [ ] Events processed in order"

gh issue create --title "Implement fault injection framework" --label "testing,P3: Testing" --body "**Depends on**: #30

Add fault injection:
- Primary/replica crash
- Network partition
- Message drop/delay/reorder
- Disk corruption
- Clock skew

**Acceptance**:
- [ ] Faults injected at specified time
- [ ] Each fault type works
- [ ] Unit tests for fault injection"

gh issue create --title "Implement deterministic simulation tests" --label "testing,P3: Testing" --body "**Depends on**: #31

Create \`test/simulation/\` scenarios:
- Normal case commit
- Primary crash + view change
- Network partition with quorum
- Message reordering
- Concurrent rooms

**Acceptance**:
- [ ] All 15 scenarios pass
- [ ] Each verifies invariants
- [ ] Runs in < 5 min"

gh issue create --title "Implement random simulation suite" --label "testing,P3: Testing" --body "**Depends on**: #32

Create \`test/simulation/random_suite.zig\`:
- Run N sims with random seeds
- Random workload
- Random fault injection
- Verify all invariants

**Acceptance**:
- [ ] 30k random sims pass
- [ ] Zero invariant violations
- [ ] Takes ~2 hours
- [ ] Integrated into nightly CI"

gh issue create --title "Implement fuzzing harnesses" --label "testing,P3: Testing" --body "**Depends on**: #4, #6

Create fuzz targets in \`test/fuzz/\`:
- message_parse.zig
- wal_parse.zig
- state_machine.zig

**Acceptance**:
- [ ] Fuzz targets compile with libFuzzer
- [ ] 24-hour fuzz finds no crashes
- [ ] Corpus size > 10k inputs"

gh issue create --title "Implement stress tests" --label "testing,performance,P3: Testing" --body "**Depends on**: #18, #29

Create \`test/stress/\`:
- Throughput: 100k msgs/sec
- Latency: P99 < 5ms under load
- Memory: No hot-path allocations
- Connection flood: 10k concurrent

**Acceptance**:
- [ ] 100k ops/sec achieved
- [ ] P99 < 5ms maintained
- [ ] No hot-path allocations
- [ ] Connection limit enforced"

echo "Creating Phase 4 issues..."

# Phase 4: Operations
gh issue create --title "Implement metrics subsystem" --label "operator-ux,P4: Operations" --body "**Depends on**: #18

Implement \`src/metrics.zig\`:
- Prometheus-style endpoint
- Counters: messages committed, view changes
- Histograms: latency (prepare, commit, view change)
- Gauges: current view, commit_num, queue depths

**Acceptance**:
- [ ] Metrics exposed on HTTP
- [ ] All key metrics tracked
- [ ] Prometheus can scrape"

gh issue create --title "Implement audit log subsystem" --label "safety,operator-ux,P4: Operations" --body "**Depends on**: #3

Implement \`src/audit.zig\`:
- JSON Lines format
- Ed25519 signature chain
- Log operator actions
- Log view changes
- Log config changes

**Acceptance**:
- [ ] Audit log created on startup
- [ ] All operator actions logged
- [ ] Signature chain verified"

gh issue create --title "Implement operator CLI (tigerctl)" --label "operator-ux,P4: Operations" --body "**Depends on**: #1, #36

Implement \`src/cli/tigerctl.zig\`:
- status: Show replica state
- drain: Gracefully drain replica
- metrics: Query metrics
- audit: View audit log

**Acceptance**:
- [ ] All commands implemented
- [ ] CLI connects to replica
- [ ] Output human-readable
- [ ] Integration: run all commands"

gh issue create --title "Implement drain operation" --label "operator-ux,P4: Operations" --body "**Depends on**: #38

Implement drain in replica:
- Receive drain_start
- Stop accepting new prepares
- Flush pending commits
- Send drain_status when complete

**Acceptance**:
- [ ] Drain completes successfully
- [ ] No new prepares during drain
- [ ] Pending ops committed
- [ ] Integration: drain + restart"

gh issue create --title "End-to-end Phase 4 testing" --label "testing,P4: Operations" --body "**Depends on**: #39

Comprehensive P4 testing:
- Integration: Metrics via Prometheus
- Integration: All tigerctl commands
- Integration: Drain + restart + recovery
- Verify audit log integrity

**Acceptance**:
- [ ] Metrics exportable
- [ ] CLI commands functional
- [ ] Drain operation reliable
- [ ] Audit log verifiable"

echo "Creating Phase 5 issues..."

# Phase 5: MVP
gh issue create --title "Create example applications" --label "P5: MVP" --body "**Depends on**: #29

Create \`examples/\`:
- Simple chat client (Go or JavaScript)
- Demo web UI (React + TailwindCSS)
- Load generator

**Acceptance**:
- [ ] Example client connects
- [ ] Demo UI runs in browser
- [ ] Load generator creates traffic"

gh issue create --title "Write operator guide" --label "P5: MVP" --body "**Depends on**: #40

Create \`docs/operator-guide.md\`:
- Deployment guide
- Configuration reference
- Monitoring best practices
- Troubleshooting
- Backup and recovery

**Acceptance**:
- [ ] Guide covers all tasks
- [ ] Examples for all configs
- [ ] Troubleshooting comprehensive"

gh issue create --title "Write developer SDK docs" --label "P5: MVP" --body "**Depends on**: #41

Create \`docs/sdk-guide.md\`:
- Client protocol overview
- WebSocket connection guide
- API reference
- Example code
- Error handling

**Acceptance**:
- [ ] SDK covers all operations
- [ ] Code examples for all types
- [ ] Error codes documented"

gh issue create --title "Performance benchmarking and tuning" --label "performance,P5: MVP" --body "**Depends on**: #29, #35

Performance validation:
- Run full benchmark suite
- Verify P99 < 5ms
- Verify throughput > 100k ops/sec
- Verify view change < 300ms
- Profile and optimize hot paths

**Acceptance**:
- [ ] All targets met
- [ ] No regressions
- [ ] Profile shows no bottlenecks"

gh issue create --title "Security audit and hardening" --label "safety,P5: MVP" --body "**Depends on**: #29

Security review:
- Review all invariants enforced
- Check integer overflow
- Verify signature validation everywhere
- Review timing attacks
- Run sanitizers (ASan, UBSan)

**Acceptance**:
- [ ] All invariants verified
- [ ] No sanitizer warnings
- [ ] No timing attacks
- [ ] Security checklist complete"

gh issue create --title "Final integration testing" --label "testing,P5: MVP" --body "**Depends on**: #44, #45

Final MVP validation:
- Integration: Full 3-node cluster with clients
- Integration: Multi-room concurrent usage
- Chaos: Random faults during operation
- Soak: 24-hour continuous operation

**Acceptance**:
- [ ] All integration tests pass
- [ ] 24-hour soak: zero crashes
- [ ] No memory leaks
- [ ] Performance targets maintained"

gh issue create --title "Release preparation" --label "P5: MVP" --body "**Depends on**: #46

Final release tasks:
- Tag v0.1.0
- Build release binaries (Linux x86_64, ARM64)
- Generate checksums and sign
- Create GitHub release
- Update README with install instructions

**Acceptance**:
- [ ] v0.1.0 tagged
- [ ] Binaries built and signed
- [ ] Release published
- [ ] Install docs complete"

echo "All 47 issues created!"
echo "View: https://github.com/copyleftdev/tigerstyle-chat/issues"
