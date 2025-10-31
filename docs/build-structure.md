# TigerChat Build Structure

## Philosophy

> "Simplicity is prerequisite for reliability." — Edsger Dijkstra

TigerChat uses Zig's build system for:
- **Single source of truth**: One `build.zig` for all targets.
- **Reproducible builds**: Pinned dependencies, hermetic compilation.
- **Zero external deps**: No pkg-config, CMake, or system libraries.
- **Fast incremental**: Parallel compilation, aggressive caching.

**Target**: Static binary < 15 MB, zero runtime dependencies.

---

## Project Layout

```
tigerchat/
├── build.zig                 # Build system entry point
├── build.zig.zon             # Dependency declarations
├── src/
│   ├── main.zig              # Binary entry point
│   ├── replica.zig           # VSR replica implementation
│   ├── primary.zig           # Primary-specific logic
│   ├── view_change.zig       # View change protocol
│   ├── state_machine.zig     # Room state machine
│   ├── wal.zig               # Write-ahead log
│   ├── message.zig           # Message types and serialization
│   ├── transport.zig         # Network layer (mTLS + Ed25519)
│   ├── edge.zig              # WebSocket edge gateway
│   ├── fanout.zig            # Pub/sub bus for committed messages
│   ├── queue.zig             # Bounded queues
│   ├── crypto.zig            # Ed25519, SHA256, CRC32C
│   ├── io.zig                # Async I/O (epoll/kqueue)
│   ├── config.zig            # Configuration parsing
│   ├── metrics.zig           # Prometheus metrics
│   ├── audit.zig             # Audit log subsystem
│   ├── simulation.zig        # Discrete-event simulator
│   └── cli/
│       ├── tigerctl.zig      # Operator CLI
│       └── commands.zig      # CLI subcommands
├── test/
│   ├── unit/                 # Unit tests (co-located with src/)
│   ├── simulation/           # Simulation test scenarios
│   │   ├── basic.zig
│   │   ├── view_change.zig
│   │   ├── partition.zig
│   │   └── corruption.zig
│   ├── stress/               # Stress tests
│   │   ├── throughput.zig
│   │   ├── latency.zig
│   │   └── memory.zig
│   ├── integration/          # End-to-end tests
│   │   └── cluster.zig
│   └── fuzz/                 # Fuzz harnesses
│       ├── message_parse.zig
│       ├── wal_parse.zig
│       └── state_machine.zig
├── docs/                     # Documentation
│   ├── prd.md
│   ├── protocol.md
│   ├── message-formats.md
│   ├── invariants.md
│   ├── test-plan.md
│   └── build-structure.md    # This file
├── tools/                    # Development utilities
│   ├── codegen.zig           # Generate boilerplate
│   └── trace_viewer.zig      # Visualize simulation traces
└── .github/
    └── workflows/
        ├── ci.yml            # Fast CI
        └── nightly.yml       # Slow CI (sim + fuzz)
```

---

## Build Targets

### Primary Targets

```bash
# Production binary (static, optimized)
zig build -Doptimize=ReleaseFast

# Development binary (debug symbols, safety checks)
zig build

# Operator CLI
zig build tigerctl

# Run replica
zig build run -- --config replica.toml

# Run CLI
zig build tigerctl -- status --replica 127.0.0.1:9001
```

### Test Targets

```bash
# Unit tests
zig build test

# Simulation suite
zig build sim

# Random simulations (30k seeds)
zig build sim-random -Dcount=30000

# Stress tests
zig build stress

# Integration tests
zig build integration

# Benchmarks
zig build bench

# Fuzz targets (build only; run with AFL/libFuzzer)
zig build fuzz-targets
```

### Development Targets

```bash
# Format code (Tiger Style)
zig fmt --check src/

# Lint (Zig's built-in checks)
zig build lint

# Generate documentation
zig build docs

# Code coverage report
zig build coverage
```

---

## `build.zig` Implementation

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // ========================================================================
    // Main replica binary
    // ========================================================================
    
    const replica_exe = b.addExecutable(.{
        .name = "tigerchat",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    
    // Static linking (no libc dependency)
    replica_exe.linkage = .static;
    
    // Release optimizations
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        replica_exe.strip = true;  // Remove debug symbols
        replica_exe.link_function_sections = true;
        replica_exe.link_gc_sections = true;
    }
    
    // Safety checks in ReleaseSafe
    if (optimize == .ReleaseSafe) {
        replica_exe.want_lto = true;
    }
    
    b.installArtifact(replica_exe);
    
    // Run step
    const run_cmd = b.addRunArtifact(replica_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run TigerChat replica");
    run_step.dependOn(&run_cmd.step);
    
    // ========================================================================
    // Operator CLI (tigerctl)
    // ========================================================================
    
    const cli_exe = b.addExecutable(.{
        .name = "tigerctl",
        .root_source_file = .{ .path = "src/cli/tigerctl.zig" },
        .target = target,
        .optimize = optimize,
    });
    cli_exe.linkage = .static;
    b.installArtifact(cli_exe);
    
    const cli_run = b.addRunArtifact(cli_exe);
    if (b.args) |args| {
        cli_run.addArgs(args);
    }
    const cli_step = b.step("tigerctl", "Run operator CLI");
    cli_step.dependOn(&cli_run.step);
    
    // ========================================================================
    // Unit tests
    // ========================================================================
    
    const test_step = b.step("test", "Run unit tests");
    
    const test_filter = b.option([]const u8, "filter", "Test filter pattern");
    
    // Test each module independently for faster incremental builds
    const modules = [_][]const u8{
        "message",
        "transport",
        "wal",
        "state_machine",
        "view_change",
        "queue",
        "crypto",
    };
    
    for (modules) |module| {
        const module_test = b.addTest(.{
            .root_source_file = .{ .path = b.fmt("src/{s}.zig", .{module}) },
            .target = target,
            .optimize = optimize,
            .filter = test_filter,
        });
        const run_test = b.addRunArtifact(module_test);
        test_step.dependOn(&run_test.step);
    }
    
    // ========================================================================
    // Simulation tests
    // ========================================================================
    
    const sim_exe = b.addExecutable(.{
        .name = "simulator",
        .root_source_file = .{ .path = "src/simulation.zig" },
        .target = target,
        .optimize = .Debug,  // Fast compile for iteration
    });
    
    const sim_run = b.addRunArtifact(sim_exe);
    const sim_seed = b.option(u64, "seed", "Simulation seed") orelse 1234;
    sim_run.addArg(b.fmt("--seed={}", .{sim_seed}));
    
    const sim_step = b.step("sim", "Run deterministic simulations");
    sim_step.dependOn(&sim_run.step);
    
    // Random simulation suite
    const sim_random_count = b.option(u32, "count", "Number of random sims") orelse 100;
    const sim_random_exe = b.addExecutable(.{
        .name = "sim-random",
        .root_source_file = .{ .path = "test/simulation/random_suite.zig" },
        .target = target,
        .optimize = .ReleaseFast,  // Fast execution
    });
    const sim_random_run = b.addRunArtifact(sim_random_exe);
    sim_random_run.addArg(b.fmt("--count={}", .{sim_random_count}));
    
    const sim_random_step = b.step("sim-random", "Run random simulation suite");
    sim_random_step.dependOn(&sim_random_run.step);
    
    // ========================================================================
    // Stress tests
    // ========================================================================
    
    const stress_exe = b.addExecutable(.{
        .name = "stress",
        .root_source_file = .{ .path = "test/stress/main.zig" },
        .target = target,
        .optimize = .ReleaseFast,
    });
    
    const stress_run = b.addRunArtifact(stress_exe);
    const stress_duration = b.option(u32, "duration", "Duration in seconds") orelse 60;
    stress_run.addArg(b.fmt("--duration={}", .{stress_duration}));
    
    const stress_step = b.step("stress", "Run stress tests");
    stress_step.dependOn(&stress_run.step);
    
    // ========================================================================
    // Integration tests
    // ========================================================================
    
    const integration_test = b.addTest(.{
        .root_source_file = .{ .path = "test/integration/cluster.zig" },
        .target = target,
        .optimize = .Debug,
    });
    integration_test.linkSystemLibrary("c");  // For socket APIs
    
    const integration_run = b.addRunArtifact(integration_test);
    const integration_step = b.step("integration", "Run integration tests");
    integration_step.dependOn(&integration_run.step);
    
    // ========================================================================
    // Benchmarks
    // ========================================================================
    
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = "test/bench/main.zig" },
        .target = target,
        .optimize = .ReleaseFast,
    });
    
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_run.step);
    
    // ========================================================================
    // Fuzz targets
    // ========================================================================
    
    const fuzz_targets = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{ .name = "fuzz_message", .src = "test/fuzz/message_parse.zig" },
        .{ .name = "fuzz_wal", .src = "test/fuzz/wal_parse.zig" },
        .{ .name = "fuzz_state_machine", .src = "test/fuzz/state_machine.zig" },
    };
    
    const fuzz_step = b.step("fuzz-targets", "Build fuzz harnesses");
    
    for (fuzz_targets) |fuzz| {
        const fuzz_exe = b.addExecutable(.{
            .name = fuzz.name,
            .root_source_file = .{ .path = fuzz.src },
            .target = target,
            .optimize = .ReleaseFast,
        });
        
        // libFuzzer support
        fuzz_exe.addCSourceFile(.{
            .file = .{ .path = "test/fuzz/libfuzzer_main.c" },
            .flags = &[_][]const u8{ "-fsanitize=fuzzer,address" },
        });
        fuzz_exe.linkLibC();
        
        b.installArtifact(fuzz_exe);
        fuzz_step.dependOn(&fuzz_exe.step);
    }
    
    // ========================================================================
    // Lint and format
    // ========================================================================
    
    const fmt_step = b.step("fmt", "Format source files");
    const fmt_cmd = b.addSystemCommand(&[_][]const u8{ "zig", "fmt", "--check", "src/" });
    fmt_step.dependOn(&fmt_cmd.step);
    
    const lint_step = b.step("lint", "Run static analysis");
    // Zig's built-in checks run automatically during compilation
    lint_step.dependOn(test_step);
    
    // ========================================================================
    // Documentation
    // ========================================================================
    
    const docs_step = b.step("docs", "Generate documentation");
    const docs_cmd = b.addSystemCommand(&[_][]const u8{
        "zig",
        "build-lib",
        "src/main.zig",
        "-femit-docs",
        "-fno-emit-bin",
    });
    docs_step.dependOn(&docs_cmd.step);
    
    // ========================================================================
    // CI targets
    // ========================================================================
    
    const ci_fast = b.step("ci-fast", "Fast CI checks (< 5 min)");
    ci_fast.dependOn(test_step);
    ci_fast.dependOn(fmt_step);
    ci_fast.dependOn(lint_step);
    
    // Quick sim (first 100 seeds)
    const ci_sim = b.addRunArtifact(sim_random_exe);
    ci_sim.addArg("--count=100");
    ci_fast.dependOn(&ci_sim.step);
    
    const ci_nightly = b.step("ci-nightly", "Nightly CI (4 hours)");
    ci_nightly.dependOn(sim_random_step);  // 30k seeds
    ci_nightly.dependOn(stress_step);
    ci_nightly.dependOn(integration_step);
    // Note: Fuzz runs externally with AFL/libFuzzer
}
```

---

## `build.zig.zon` (Dependencies)

TigerChat has **zero external dependencies** for the core runtime. Development tools may use:

```zig
.{
    .name = "tigerchat",
    .version = "0.1.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "test",
    },
    .dependencies = .{
        // No runtime dependencies
        
        // Development only (not linked into binary)
        // .tracy = .{
        //     .url = "https://github.com/wolfpld/tracy/archive/v0.9.tar.gz",
        //     .hash = "...",
        // },
    },
}
```

**Rationale**: Zero deps = zero supply chain risk, zero version conflicts, zero build complexity.

---

## Compilation Modes

### Development (`zig build`)

- **Optimize**: `Debug`
- **Safety checks**: All enabled (bounds, null, overflow)
- **Assertions**: Enabled
- **Debug symbols**: Full
- **Binary size**: ~50 MB
- **Compile time**: < 10 seconds incremental

### Production (`zig build -Doptimize=ReleaseSafe`)

- **Optimize**: `ReleaseSafe`
- **Safety checks**: Enabled
- **Assertions**: Enabled
- **Debug symbols**: Stripped
- **Binary size**: ~15 MB
- **Compile time**: ~60 seconds clean build

**Note**: Never use `ReleaseFast` in production—safety checks must remain.

### Benchmark (`zig build bench -Doptimize=ReleaseFast`)

- **Optimize**: `ReleaseFast`
- **Safety checks**: **Disabled** (for perf measurement only)
- **Assertions**: Disabled
- **Use case**: Performance benchmarking only, not production

---

## Cross-Compilation

TigerChat supports Linux x86_64 and ARM64:

```bash
# Linux x86_64 (default)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# Linux ARM64
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe

# macOS x86_64 (dev only)
zig build -Dtarget=x86_64-macos -Doptimize=Debug

# macOS ARM64 (dev only)
zig build -Dtarget=aarch64-macos -Doptimize=Debug
```

**Production target**: Linux with musl libc (static binary).

---

## Directory Structure Details

### `src/` Organization

**Principle**: One file per logical component; avoid "kitchen sink" files.

```
src/
├── main.zig              # Entry point: parse args, start replica
├── replica.zig           # Replica struct, message loop, state transitions
├── primary.zig           # Primary-specific: prepare broadcast, commit decision
├── view_change.zig       # View change protocol implementation
├── state_machine.zig     # Deterministic room state machine
├── wal.zig               # Write-ahead log (append, read, fsync, snapshot)
├── message.zig           # Message types (extern struct), serialization
├── transport.zig         # Network: Ed25519 sign/verify, mTLS, send/recv
├── edge.zig              # WebSocket gateway: auth, rate limit, fan-out
├── fanout.zig            # In-memory pub/sub bus for committed messages
├── queue.zig             # Bounded FIFO queue (ring buffer)
├── crypto.zig            # Crypto primitives: Ed25519, SHA256, CRC32C
├── io.zig                # Async I/O: epoll (Linux), kqueue (macOS)
├── config.zig            # Config file parsing (TOML)
├── metrics.zig           # Prometheus metrics endpoint
└── audit.zig             # Audit log: Ed25519 chain, operator actions
```

**Size target**: No file > 1000 lines. Split if necessary.

### `test/` Organization

```
test/
├── simulation/
│   ├── basic.zig         # Normal case, single message
│   ├── view_change.zig   # Primary crash scenarios
│   ├── partition.zig     # Network partition tests
│   ├── corruption.zig    # WAL corruption detection
│   └── random_suite.zig  # 30k random simulations
├── stress/
│   ├── main.zig          # Stress test runner
│   ├── throughput.zig    # 100k msgs/sec
│   ├── latency.zig       # P99 latency under load
│   └── memory.zig        # No-allocation verification
├── integration/
│   └── cluster.zig       # End-to-end with real I/O
└── fuzz/
    ├── message_parse.zig # Fuzz TransportHeader parsing
    ├── wal_parse.zig     # Fuzz WAL deserialization
    └── state_machine.zig # Fuzz state machine ops
```

---

## Build Performance

### Incremental Compilation

Zig's caching system tracks:
- Source file hashes
- Compiler flags
- Target triple

**Typical incremental**: < 1 second for single-file change.

### Parallel Compilation

Zig uses all available cores by default. On 16-core machine:
- Clean build: ~60 seconds
- Incremental: < 5 seconds

### Build Cache Location

```
~/.cache/zig/           # Global cache
./zig-cache/            # Project-local cache (gitignored)
./zig-out/              # Build artifacts (gitignored)
```

---

## Static Analysis

### Zig Built-in Checks

- **Type safety**: No implicit conversions.
- **Null safety**: Optionals must be unwrapped.
- **Bounds checking**: Array access verified (in safe modes).
- **Integer overflow**: Detected in safe modes.
- **Unused variables**: Compilation warning.
- **Unreachable code**: Compilation error.

### Additional Tooling

```bash
# Format check
zig fmt --check src/

# Test with sanitizers (Linux)
zig build test -Doptimize=Debug \
  -Dcpu=baseline \
  -Dtarget=native-linux-gnu \
  -Dasan=true -Dubsan=true

# Valgrind (memory leaks)
valgrind --leak-check=full ./zig-out/bin/tigerchat --config test.toml
```

---

## Release Process

### Version Tagging

```bash
# Tag release
git tag -a v0.1.0 -m "TigerChat v0.1.0 - MVP release"
git push origin v0.1.0
```

### Build Release Artifacts

```bash
# Linux x86_64
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
mv zig-out/bin/tigerchat tigerchat-v0.1.0-linux-x86_64

# Linux ARM64
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
mv zig-out/bin/tigerchat tigerchat-v0.1.0-linux-aarch64

# Generate checksums
sha256sum tigerchat-* > SHA256SUMS

# Sign release
gpg --armor --detach-sign SHA256SUMS
```

### Release Checklist

- [ ] All CI checks pass (fast + nightly)
- [ ] Version bumped in `build.zig.zon`
- [ ] CHANGELOG.md updated
- [ ] Release notes drafted
- [ ] Binaries built and signed
- [ ] GitHub release created with artifacts
- [ ] Documentation deployed

---

## Development Workflow

### Daily Development

```bash
# Edit code
vim src/replica.zig

# Run tests
zig build test -Dfilter=replica

# Run simulation
zig build sim -Dseed=1234

# Format
zig fmt src/

# Commit
git commit -m "Fix view change timeout calculation"
```

### Before Merge

```bash
# Full test suite
zig build test
zig build sim
zig build sim-random -Dcount=1000  # Quick random check

# Format check
zig fmt --check src/

# Build optimized
zig build -Doptimize=ReleaseSafe

# Verify binary size
ls -lh zig-out/bin/tigerchat
# Should be < 15 MB
```

---

## Troubleshooting

### Compilation Errors

**"Linker error: undefined reference"**
- Check that all source files are in `src/`.
- Verify no missing `pub` keywords for exported functions.

**"Out of memory during compilation"**
- Reduce debug info: `-Doptimize=ReleaseFast`
- Increase system limits: `ulimit -s unlimited`

### Test Failures

**Simulation non-determinism**
- Ensure PRNG seed is fixed: `Simulator.init(seed)`
- Check for accidental use of wall clock: use virtual time only.

**Integration test timeout**
- Increase timeout: `--timeout=60`
- Check if ports are already in use: `lsof -i :9001`

---

## Summary

| Aspect | Value |
|--------|-------|
| **Primary binary** | `tigerchat` (< 15 MB) |
| **Operator CLI** | `tigerctl` |
| **Build time** | < 60s clean, < 5s incremental |
| **Test time (fast)** | < 5 min |
| **Test time (nightly)** | ~4 hours |
| **Dependencies** | Zero runtime, optional dev tools |
| **Supported platforms** | Linux x86_64, ARM64 |
| **Compilation modes** | Debug, ReleaseSafe |
| **Static analysis** | Zig built-in + optional sanitizers |

**Philosophy**: Simple, fast, reliable builds with zero surprises.
