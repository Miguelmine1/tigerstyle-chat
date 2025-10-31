# TigerChat Implementation Plan

Complete strategic breakdown - 47 issues ordered by dependency.

## Phase 0: Foundation (4 issues)
- #1: Build system setup
- #2: Directory structure
- #3: Crypto primitives
- #4: Message struct

## Phase 1: Core VSR (15 issues)  
- #5: Bounded queue
- #6: WAL implementation
- #7: Snapshot mechanism
- #8: State machine
- #9: Replica base
- #10: Primary protocol
- #11: Replica protocol
- #12: View change detection
- #13: New primary election
- #14: View change completion
- #15: Transport layer
- #16: Async I/O
- #17: Config parsing
- #18: Main binary
- #19: P1 testing

## Phase 2: Edge & Fan-out (10 issues)
- #20: WebSocket server
- #21: JWT auth
- #22: Rate limiting
- #23: Client forwarding
- #24: Message ack
- #25: Fan-out bus
- #26: VSR integration
- #27: Room subscription
- #28: Snapshot API
- #29: P2 testing

## Phase 3: Testing (6 issues)
- #30: Simulation framework
- #31: Fault injection
- #32: Deterministic sims
- #33: Random sim suite (30k)
- #34: Fuzz harnesses
- #35: Stress tests

## Phase 4: Operations (5 issues)
- #36: Metrics subsystem
- #37: Audit log
- #38: Operator CLI
- #39: Drain operation
- #40: P4 testing

## Phase 5: MVP (7 issues)
- #41: Example apps
- #42: Operator guide
- #43: SDK docs
- #44: Performance tuning
- #45: Security audit
- #46: Final testing
- #47: Release prep

**Total: 47 issues across 5 phases**
