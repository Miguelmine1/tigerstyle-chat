# 🐅 TigerChat

<p align="center">
  <img src="media/logo.svg" alt="TigerChat Logo" width="200"/>
</p>

**The fastest, safest, and most trustworthy chat backend on earth—engineered like a financial ledger, delivered like a message.**

---

## What is TigerChat?

TigerChat is a distributed, fault-tolerant, real-time chat infrastructure built with [Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) principles. It combines TigerBeetle-level correctness with game-server-grade latency, providing strong consistency, replayable history, and millisecond fan-out for chats ranging from small DMs to high-traffic community rooms.

## Design Goals

- **Safety before performance** — Correctness and invariants are first-class; every path is simulation-verified
- **Performance is predictable** — Microsecond tail-latency discipline; no unbounded queues
- **One binary, zero mystery** — Single static Zig binary, no dynamic dependencies
- **Transparent fault recovery** — Users never lose messages, even under leader election or restart
- **Auditable by design** — Every commit, view change, and operator action is cryptographically traceable

## Core Features

- **Strongly-ordered replication** via Viewstamped Replication (VSR) consensus per room
- **Exactly-once delivery** with idempotency keys
- **Sub-5ms P99 latency** within an availability zone
- **Zero data loss** under fault injection (30k+ simulation coverage)
- **Cryptographic integrity** with Ed25519 signatures and SHA256 hash chains
- **Built-in simulation harness** for deterministic testing

## Performance Targets

| Metric | Target |
|--------|--------|
| P99 message latency | ≤ 5 ms within AZ |
| Commit throughput | ≥ 100k ops/sec per shard |
| View-change recovery | ≤ 300 ms |
| Binary size | < 15 MB static |
| Durability | 0 lost or reordered messages |

## Project Status

🚧 **Pre-alpha** — Currently in design and specification phase. Implementation in progress.

## Documentation

- [Product Requirements](docs/prd.md)
- [Protocol Specification](docs/protocol.md)
- [Message Formats](docs/message-formats.md)
- [Invariants Table](docs/invariants.md)
- [Test Plan](docs/test-plan.md)
- [Build Structure](docs/build-structure.md)

## License

MIT
