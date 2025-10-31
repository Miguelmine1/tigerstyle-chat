# Contributing to TigerChat

## Development Workflow

TigerChat uses a **Tiger Style** development process focused on correctness, simplicity, and fail-fast principles.

### Pre-commit Checks

A pre-commit hook runs automatically before each commit to enforce quality standards:

**Checks performed:**

1. **Zig formatting** (`zig fmt --check src/`)
2. **Markdown linting** (if `markdownlint` is installed)
3. **Large file detection** (warns for files > 1 MB)
4. **TODO/FIXME markers** (warning only)
5. **Build verification** (`zig build`)

The hook is installed at `.git/hooks/pre-commit`.

### Making Changes

```bash
# 1. Create a feature branch
git checkout -b feature/implement-vsr-replica

# 2. Make changes
vim src/replica.zig

# 3. Format code
zig fmt src/

# 4. Run tests
zig build test

# 5. Commit (pre-commit hook runs automatically)
git commit -m "Implement VSR replica state machine

- Add Replica struct with Normal/ViewChange/Recovering states
- Implement prepare/prepare_ok/commit handlers
- Add monotonicity assertions (S1)
- Add quorum verification (S2)

Refs #12"
```

### Commit Message Format

Follow conventional commit style with Tiger Style principles:

```
<type>: <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `test`: Test additions or changes
- `refactor`: Code refactoring
- `perf`: Performance improvements

**Example:**

```
feat: implement view change protocol

Add deterministic view change with timeout-based detection:
- Start view change after 50ms prepare timeout
- Collect do_view_change from quorum
- New primary merges logs deterministically
- Install new view with start_view broadcast

Invariants enforced:
- S4: View monotonicity
- L1: View change completes < 300ms

Refs #15
```

### Code Review Guidelines

**Before creating PR:**

- [ ] All pre-commit checks pass
- [ ] Unit tests added for new code
- [ ] Simulation tests added for new protocol paths
- [ ] Invariants documented and asserted
- [ ] No heap allocations in hot path (if applicable)
- [ ] All loops have explicit bounds
- [ ] Preconditions and postconditions asserted

**Review focus:**

1. **Correctness**: Does code violate any invariants?
2. **Simplicity**: Is this the simplest solution?
3. **Testing**: Are failure modes covered in simulation?
4. **Style**: Does it follow Tiger Style principles?

### Issue-Driven Development

All work is tracked via GitHub Issues, organized by:

**Labels:**
- `safety`: Safety-critical invariants and correctness
- `performance`: Performance and latency work
- `testing`: Simulation, fuzzing, and test infrastructure
- `docs`: Documentation updates
- `operator-ux`: Operator tools and observability

**Milestones:**
- `P1: Core VSR`: Basic replica and consensus
- `P2: Edge & Fan-out`: WebSocket gateway and pub/sub
- `P3: Testing`: Simulation harness
- `P4: Operations`: Metrics and operator CLI
- `P5: MVP`: Complete system

### Testing Requirements

**Every PR must include:**

1. **Unit tests**: Test individual functions in isolation
2. **Simulation tests**: Test protocol interactions with fault injection
3. **Invariant verification**: Ensure assertions in place

**For protocol changes:**

- Add deterministic simulation scenario
- Add random simulation coverage (new seed range)
- Document which invariants are affected
- Update test plan documentation

### No CI/CD (Yet)

TigerChat relies on **local pre-commit hooks** for quality enforcement. Once the codebase matures, CI/CD will be added for:

- Nightly 30k simulation runs
- 4-hour fuzzing campaigns
- Performance regression detection

Until then, developers are responsible for running the full test suite locally before pushing.

### Zero Technical Debt Policy

**We do it right the first time.**

If a showstopper is found (memory safety issue, unbounded resource, missing invariant), we fix it immediately. No "TODO: fix later" comments in production code paths.

Acceptable TODOs:
- Future features explicitly out of scope for current milestone
- Optimization opportunities (after correctness is proven)
- Developer experience improvements

### Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open an issue with reproduction steps
- **Security**: Email security@tigerchat.dev (if project is public)

---

## Code Style

### Zig Conventions

- Use `snake_case` for functions and variables
- Use `PascalCase` for types
- Explicit types everywhere (`u32`, not `usize` unless necessary)
- Assert preconditions at function entry
- Assert postconditions before return
- No recursion
- All loops have explicit bounds

### File Organization

- One major struct per file
- Co-locate tests with implementation
- Keep files under 1000 lines (split if larger)

### Comments

**Write comments for why, not what:**

```zig
// Good: Explains reasoning
// Use CRC32C instead of SHA256 for performance (integrity checked by Ed25519 signature)
const checksum = crc32c(data);

// Bad: States the obvious
// Calculate checksum
const checksum = crc32c(data);
```

**Document invariants:**

```zig
// Invariant S1: Op numbers are strictly monotonic
assert(new_op == self.last_op + 1);
```

### Error Handling

- Use Zig error unions (`!Type`)
- Panic on invariant violations (via `assert`)
- Return errors for expected failures (network timeout, auth failure)

```zig
// Expected failure - return error
pub fn send(self: *Client, msg: Message) !void {
    if (self.connection.closed) return error.ConnectionClosed;
    ...
}

// Invariant violation - panic
pub fn appendOp(self: *Replica, op: u64) void {
    assert(op == self.last_op + 1);  // S1: monotonicity
    ...
}
```

---

## Design Process

1. **Write invariants first** (add to `docs/invariants.md`)
2. **Design protocol** (update `docs/protocol.md`)
3. **Write simulation test** (define expected behavior)
4. **Implement** (make simulation pass)
5. **Add property tests** (fuzz for edge cases)
6. **Document** (update relevant docs)

This ensures correctness by construction, not by testing.

---

**Welcome to TigerChat development. Ship correct code. 🐅**
