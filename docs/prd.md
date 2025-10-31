🐅 TigerChat — Product Requirements Document (PRD)
Document Purpose

To define the product vision, user experience, functional and non-functional requirements, and system constraints for TigerChat, a distributed, fault-tolerant, real-time chat infrastructure designed according to Tiger Style principles.

1. Vision Statement

“The fastest, safest, and most trustworthy chat backend on earth—engineered like a financial ledger, delivered like a message.”

TigerChat combines TigerBeetle-level correctness with game-server-grade latency, providing strong consistency, replayable history, and millisecond fan-out for chats ranging from small DMs to high-traffic community rooms.

2. Philosophy & Principles

Safety before performance — correctness and invariants are first-class; every path is simulation-verified.

Performance is predictable — microsecond tail-latency discipline; no unbounded queues.

One binary, zero mystery — single static Zig binary, no dynamic dependencies.

Whole-picture engineering — design, code, simulation, and operator UX evolve together.

Transparent fault recovery — users never lose messages, even under leader election or restart.

Auditable by design — every commit, view change, and operator action is cryptographically traceable.

3. Target Users
Persona	Description	Core Need
Developers / Integrators	SaaS or game teams needing embedded chat	Stable, low-latency, strong consistency
Operators	SREs maintaining TigerChat clusters	Simple visibility, immutable audit trails
End Users	Humans using apps powered by TigerChat	Instant message delivery, no duplicates, always available
4. Key Use Cases

Direct Messaging (DM): strongly ordered, private 1:1 channels.

Room Chat: replicated VSR log per room; sub-2 ms write latency in a region.

Threaded Discussions: partitioned logs under a parent room key.

Audit-critical Messaging: compliance-grade immutable history.

Developer Embedding: simple gRPC/WS API with SDKs for Go, JS, Rust.

5. Success Metrics
Metric	Target
P99 message latency	≤ 5 ms within AZ
Message durability	0 lost or reordered messages under fault injection
Commit throughput	≥ 100 k ops/sec per shard
View-change recovery	≤ 300 ms
Simulation coverage	100% of message types in swarm tests
Binary size	< 15 MB static
6. Core Features
Functional

Strongly-ordered replication (VSR consensus) per room.

Exactly-once delivery with idempotency keys.

Multi-tenant sharding and dynamic leader placement.

Message persistence with cryptographic hash chain.

Snapshot + replay API for catch-up.

Secure fan-out over WebSockets or HTTP/3 push.

Non-Functional

Single static Zig binary; no GC, no runtime deps.

Deterministic state machine per shard.

Built-in simulation harness (zig build sim).

Operator metrics and audit log subsystem.

Config-driven quorum and timeout policies.

7. Architecture Overview
Logical Components

Edge Gateway: handles WS, auth, rate limits, forwards to leader.

Room Shard: 3-node VSR group with WAL and deterministic state machine.

Transport: mTLS and Ed25519-signed inter-node messages.

Fanout Bus: ephemeral pub/sub (in-memory or Redis) for committed messages.

Simulation Harness: discrete-event testbed for fault injection.

Data Flow
Client → Edge → VSR Primary → Quorum → Commit → Bus → Edge → Clients

8. Reliability & Recovery

Crash safety: WAL with fsync; atomic rename on commit.

View change: deterministic new-view election in <300 ms.

Replay: state restored from last snapshot + replay log.

Audit trail: signed operator actions.

9. Security Requirements

mTLS + certificate pinning within cluster.

Ed25519 message signatures with nonce/replay protection.

AES-GCM encryption for persisted data.

Authentication via short-lived JWT per client room session.

10. Operator Experience

Prometheus-style metrics endpoint.

Structured audit logs (JSON Lines + Ed25519 chain).

CLI (tigerctl) for cluster inspection and shard draining.

Simulation output integrated with CI (zig build ci-sim).

11. Development & Testing Workflow

Design-first: write invariants and message/state diagrams before code.

Simulation-driven development: all changes must pass simulation suites before merge.

Property tests: run via zig test --property.

Fast CI: ≤ 5 min; Slow CI: nightly swarm/fuzz.

Release gates: no invariant violations in 30 k random simulations; performance within 2 % of baseline.

12. Future Extensions

Multi-region async replication.

Federation bridges (Matrix-style).

CRDT-assisted eventual merges for global rooms.

E2E encryption on the client layer.

13. Risks & Mitigations
Risk	Mitigation
Consensus complexity	Full simulation coverage before release
WAL corruption	Hash-chain integrity + fsync discipline
Operator misuse	Signed audit logs, command whitelisting
Scaling cost	Horizontal sharding; stateless fan-out edges
14. Deliverables & Timeline (Phase 1 MVP)
Phase	Milestone	Target
P1	Core VSR replica + log commit	Week 4
P2	WebSocket edge + fan-out bus	Week 6
P3	Simulation + property test harness	Week 8
P4	Operator CLI + metrics + audit log	Week 10
P5	Public SDK + docs + demo	Week 12
15. Success Definition (MVP Exit Criteria)

End-to-end chat room with <5 ms P99 latency.

Zero lost messages under fault-injection simulation.

Operators can drain, restart, and recover shards with zero manual repair.

Codebase ≤ 15 MB binary, no unsafe external dependencies.

