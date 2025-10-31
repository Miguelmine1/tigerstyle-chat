#!/bin/bash
# Script to create remaining TigerChat issues

cd "$(dirname "$0")/.."

# Issue #5
gh issue create --title "Implement bounded queue" --label "safety,P1: Core VSR" --body "**Priority**: High
**Depends on**: #2

Implement \`src/queue.zig\`:
- Fixed-size ring buffer
- Push/pop with bounds checking
- No heap allocation

**Invariants**: L2: Queue depth bounded

**Acceptance Criteria**:
- [ ] Fixed upper bound enforced
- [ ] Wraparound logic correct
- [ ] Assertion on overflow
- [ ] Unit tests for full queue
- [ ] Property test with random ops"

# Issue #6
gh issue create --title "Implement Write-Ahead Log (WAL)" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #4

Implement \`src/wal.zig\`:
- Append-only log with fsync
- Entry format: [op: u64][checksum: u32][Message]
- Atomic writes
- Hash chain verification

**Invariants**: S1, S5, L3

**Acceptance Criteria**:
- [ ] Append enforces monotonic ops
- [ ] fsync after each write
- [ ] Recovery validates all entries
- [ ] Corruption detection
- [ ] Stress test fsync latency < 10ms P99"

# Issue #7
gh issue create --title "Implement snapshot mechanism" --label "safety,P1: Core VSR" --body "**Priority**: High
**Depends on**: #6

Implement snapshot in \`src/wal.zig\`:
- Trigger at 10k ops or 1GB size
- Ed25519 signature
- Atomic rename for crash safety

**Invariants**: R4

**Acceptance Criteria**:
- [ ] Snapshot at thresholds
- [ ] Signature verification
- [ ] Atomic file operations
- [ ] Recovery from snapshot + log tail"

# Issue #8
gh issue create --title "Implement deterministic state machine" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #4, #6

Implement \`src/state_machine.zig\`:
- RoomState struct
- apply(message) - deterministic
- Idempotency table
- Message index

**Invariants**: S3, S6, S8, X1

**Acceptance Criteria**:
- [ ] Same log → same state
- [ ] Idempotency works
- [ ] Timestamp monotonic
- [ ] Property test: replay random sequences"

# Issue #9
gh issue create --title "Implement Replica base structure" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #6, #8

Implement \`src/replica.zig\`:
- Replica struct with state enum
- Config (cluster_id, replica_id, peers)
- WAL + state machine integration
- Nonce tracking

**Invariants**: SE2, SE3

**Acceptance Criteria**:
- [ ] Replica initializes
- [ ] State transitions defined
- [ ] Nonce table prevents replay
- [ ] Cluster ID validation"

# Issue #10
gh issue create --title "Implement Primary normal-case protocol" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #9

Implement \`src/primary.zig\`:
- Accept client request
- Assign op number (monotonic)
- Broadcast prepare
- Collect prepare_ok
- Send commit when quorum

**Invariants**: S1, S2

**Acceptance Criteria**:
- [ ] Op numbers strictly increasing
- [ ] Quorum = 2/3 enforced
- [ ] commit_num updated after quorum
- [ ] Simulation: 3-node commit"

# Issue #11
gh issue create --title "Implement Replica normal-case protocol" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #9, #10

Implement handlers in \`src/replica.zig\`:
- Handle prepare: append WAL, send prepare_ok
- Handle commit: apply ops
- Verify view, op, signature

**Invariants**: S3, SE1

**Acceptance Criteria**:
- [ ] Replica appends prepare
- [ ] Sends prepare_ok
- [ ] Commit applies consecutively
- [ ] Signature verification
- [ ] Simulation: end-to-end commit"

# Issue #12
gh issue create --title "Implement view change detection" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #11

Implement timeout in \`src/view_change.zig\`:
- Prepare timeout (50ms)
- Broadcast start_view_change
- Transition to ViewChange state

**Invariants**: S4, L1

**Acceptance Criteria**:
- [ ] Timeout triggers view change
- [ ] View increments by 1
- [ ] Simulation: primary crash triggers view change"

# Issue #13
gh issue create --title "Implement new primary election" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #12

Implement election in \`src/view_change.zig\`:
- Deterministic leader: view % replica_count
- Collect do_view_change from quorum
- Merge logs (highest op wins)
- Broadcast start_view

**Invariants**: S2, S4

**Acceptance Criteria**:
- [ ] Deterministic primary selection
- [ ] Log merging preserves highest op
- [ ] Quorum collection enforced
- [ ] Simulation: view change completes"

# Issue #14
gh issue create --title "Implement view change completion" --label "safety,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #13

Implement start_view handler:
- Install new log
- Update view and op
- Transition to Normal

**Invariants**: L1 (< 300ms)

**Acceptance Criteria**:
- [ ] Replicas install new view
- [ ] State transitions to Normal
- [ ] View change < 300ms measured
- [ ] Simulation: full view change
- [ ] Simulation: view change with message loss"

# Issue #15
gh issue create --title "Implement transport layer" --label "safety,infrastructure,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #3, #4

Implement \`src/transport.zig\`:
- Message envelope (header + body + signature)
- Ed25519 sign/verify
- Checksum validation
- Send/receive primitives

**Invariants**: SE1, SE4

**Acceptance Criteria**:
- [ ] Messages signed with Ed25519
- [ ] Signatures verified
- [ ] Checksums validated
- [ ] Invalid messages rejected
- [ ] Fuzz test for malformed messages"

# Issue #16
gh issue create --title "Implement async I/O layer" --label "infrastructure,performance,P1: Core VSR" --body "**Priority**: High
**Depends on**: #15

Implement \`src/io.zig\`:
- epoll (Linux) / kqueue (macOS)
- Non-blocking TCP sockets
- Event loop
- Bounded connection pool

**Invariants**: R2 (FD bound)

**Acceptance Criteria**:
- [ ] Event loop processes messages
- [ ] Non-blocking I/O
- [ ] FD limit enforced
- [ ] Integration: 3-node cluster on localhost"

# Issue #17
gh issue create --title "Implement configuration parsing" --label "infrastructure,P1: Core VSR" --body "**Priority**: Medium
**Depends on**: #2

Implement \`src/config.zig\`:
- TOML config file parsing
- Replica ID, cluster ID, peers
- Timeout values, queue sizes
- Validate at startup

**Acceptance Criteria**:
- [ ] TOML file parsed
- [ ] Required fields validated
- [ ] Sane defaults
- [ ] Example configs in repo"

# Issue #18
gh issue create --title "Implement main replica binary" --label "infrastructure,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #1, #9, #16, #17

Implement \`src/main.zig\`:
- Parse CLI args
- Load config
- Initialize replica
- Start event loop
- Graceful shutdown on SIGINT

**Acceptance Criteria**:
- [ ] Binary accepts --config flag
- [ ] Replica starts and listens
- [ ] SIGINT graceful shutdown
- [ ] Integration: start 3-node cluster"

# Issue #19
gh issue create --title "End-to-end Phase 1 testing" --label "testing,P1: Core VSR" --body "**Priority**: Critical
**Depends on**: #18

Comprehensive P1 testing:
- Integration: 3-node cluster commits
- Simulation: primary crash + view change
- Simulation: network partition (quorum maintained)
- Stress: 100k messages zero loss

**Acceptance Criteria**:
- [ ] 3-node cluster commits end-to-end
- [ ] View change < 300ms
- [ ] Zero message loss under faults
- [ ] P99 latency < 5ms (local cluster)"

echo "Created Phase 1 issues (#5-#19)"
