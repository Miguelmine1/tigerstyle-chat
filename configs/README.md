# TigerChat Configuration Files

Example configurations for 3-replica cluster running on localhost.

## Files

- `replica0.conf` - Primary replica (usually starts as primary)
- `replica1.conf` - Backup replica 1
- `replica2.conf` - Backup replica 2

## Configuration Sections

### `[cluster]`
- `cluster_id`: Unique cluster identifier (128-bit)
- `replica_id`: Replica identifier within cluster (0-2)

### `[network]`
- `host`: Bind address (use 127.0.0.1 for localhost)
- `port`: TCP port for cluster communication

### `[peers]`
- `peer.N`: Address of each replica in cluster
- Must include all 3 replicas (including self)

### `[timeouts]`
- `prepare_timeout_ms`: Prepare phase timeout (default: 50ms)
- `view_change_timeout_ms`: View change timeout (default: 300ms)
  - Must be > prepare_timeout_ms

### `[queues]`
- `message_queue_size`: Max messages in queue (default: 1024)
  - Enforces bounded queues (L2 invariant)

### `[keys]`
- Ed25519 cryptographic keys (not yet implemented in parser)
- For production: generate with key generation tool

## Usage

```bash
# Start replica 0 (primary)
./tigerchat configs/replica0.conf

# Start replica 1 (backup)
./tigerchat configs/replica1.conf

# Start replica 2 (backup)
./tigerchat configs/replica2.conf
```

## Validation

Configuration is validated at startup:
- Replica ID must be 0-2
- Timeouts must be positive
- View change timeout > prepare timeout
- Port must be > 1024 (non-privileged)
- Queue size must be bounded (0 < size <= 1,000,000)

Invalid configurations will fail fast with descriptive errors.

## Tiger Style

- All values bounded (no infinite queues/timeouts)
- Fail-fast validation at startup
- Explicit over implicit
- Defaults provided but overridable
