# Changelog

All notable changes to **HermesPG** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.1] - 2026-10-15

### Added
* **Automated `pg_shadow` SCRAM-SHA-256 Verifier Export (`--gen-auth-file <path>`)**:
  * Connects to PostgreSQL and extracts precomputed `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>` verifiers directly from `pg_shadow` via `fetchPgShadowUsers` and `queryRows`.
  * Writes the multi-tenant credential catalog (`userlist.txt`) to disk and enforces strict POSIX `0600` (`rw-------`, owner-only) file permissions via `writeSecureAuthFile`.

### Security
* **Anti-User-Enumeration SCRAM Defense (`dummyVerifier`)**:
  * In `--gateway` and `--sidecar` modes, unknown usernames no longer abort prior to the SASL challenge. Instead, HermesPG executes the full 4-step SCRAM-SHA-256 challenge-response handshake against a precomputed `dummyVerifier` before returning SQLSTATE `28P01`, preventing username enumeration via network timing or protocol step counts.
* **Cryptographic Memory Scrubbing (`secureZeroString`)**:
  * Overwrites temporary file buffers and password/secret strings in RAM with `zeroMem` immediately after populating `UserCatalog`.
* **Zero Secret Leakage in Catalog Parse Exceptions**:
  * `parseAuthLine` reports only the line number (`at line #N`) on syntax errors, never echoing raw lines or secrets into logs or error output.
* **POSIX File Permissions & Plaintext Auditing (`checkFilePermissions`)**:
  * Audits `userlist.txt` permissions via `posix.stat` on load and emits `[SECURITY WARNING]` alerts if group/world permissions (`0o077`) are enabled or if plaintext passwords are present.

## [0.5.0] - 2026-10-12

### Added
* **ProxyMode Strategy Pattern (`--sidecar` vs `--gateway`)**:
  * Architectural dual-mode proxy engine controlled via `--mode <sidecar|gateway>`, `--sidecar`, `--gateway`, or `HERMES_MODE`.
  * **Sidecar Mode (`--sidecar`)**: High-throughput, zero-allocation micro-pooler optimized for co-located container sidecars and single-tenant applications with sub-0.2ms latency.
  * **Gateway Mode (`--gateway`)**: Enterprise multi-tenant database gateway supporting diverse connecting users and dynamic role switching.
* **Multi-Tenant Authentication Catalog (`src/hermespg/auth/catalog.nim`)**:
  * PgBouncer-compatible `userlist.txt` authentication catalog supporting both SCRAM-SHA-256 verifiers and plaintext passwords.
  * Robust line parser handling quoted identifiers, SQL identifier validation (1-63 chars, alphanumeric/underscore), and SQL escaping (`quoteIdentifier`).
  * Dynamic user lookup with `Table[string, ScramVerifier]` integration during SCRAM frontend handshake.
* **Dynamic Role Dispatching & PostgreSQL Security Enforcement**:
  * Seamless PostgreSQL role switching via `SET ROLE <user>;` upon tenant lease.
  * Rejection with standard SQLSTATE `42501` (`permission denied to set role`) if PostgreSQL role assignment fails.
* **Strict Session Boundary Isolation (`lastClientId`)**:
  * Monotonically increasing `clientId` assigned per client TCP connection.
  * `lastClientId` tracking on backend connections ensures consecutive queries from different client sessions (or different terminal windows) trigger precompiled `DISCARD ALL;` execution before query dispatch.
  * Preserves temporary tables, session parameters, and prepared statements within the same client session while preventing cross-session leakage.
* **Automatic Disconnect Hygiene**:
  * Tracks `lastUsedConn` during client session lifecycle.
  * Upon client disconnection (`\q` or socket close), idle backend connections are flagged `isDirty = true` and `lastClientId = 0` to purge all residual temporary objects and session state before leasing to future clients.
* **Precompiled Wire Discard Packets (`protocol/messages.nim`)**:
  * Compile-time `buildStaticQueryPacket` generating zero-allocation binary wire packets (`WireDiscardAll` and `WireResetRole`).
* **Preservation of Dirty Connections in `tryAcquireFast`**:
  * Connection pool's synchronous fast-path `tryAcquireFast` inspects top idle connections and delegates dirty connections to `acquire()` for asynchronous `executeDiscardAll()` reset without destroying backend connections.

### Fixed
* **CI/CD Release Workflow for macOS**:
  * Removed deprecated `macos-13` (Intel x86_64) runner from `.github/workflows/release.yml`. GitHub has retired Intel-based macOS runners, which was causing the macOS matrix build to fail and preventing the automated publication of the GitHub Release.
  * Native macOS builds are now streamlined on `macos-latest` (Apple Silicon arm64).
  * Added explicit `make_latest: true` and `workflow_dispatch` trigger to the release workflow.
  * Updated `install.sh` with a clear deprecation notice guiding macOS Intel users to build from source or use Docker.

## [0.4.0] - 2026-10-11

### Added
* **Multi-Architecture OCI Container Images (`linux/amd64`, `linux/arm64`)**:
  * Automated multi-arch builds using GitHub Actions Buildx and QEMU, published to GitHub Container Registry (`ghcr.io/luisacosta828/hermespg`).
  * Sub-megabyte scratch image footprint (**~637 KB**) containing only the stripped static Musl ELF binary (`-flto -static -s -Wl,--gc-sections`).
  * Production container hardening: unprivileged non-root user execution (`USER 10001:10001`), root CA certificates bundle, and dual port exposure (`6432` proxy and `9127` Prometheus metrics).
* **Official One-Line Installer (`install.sh`)**:
  * Production-grade shell installer (`curl -fsSL https://raw.githubusercontent.com/luisacosta828/hermespg/main/install.sh | bash`) supporting Linux and macOS (`darwin`), with automatic CPU architecture detection (`amd64` / `arm64`).
  * Cryptographic integrity verification via `SHA256SUMS.txt`.
  * Non-root fallback to `~/.local/bin` when write access to `/usr/local/bin` is unavailable.
* **Automated CI/CD Workflows (`.github/workflows`)**:
  * `.github/workflows/docker.yml`: Automated multi-arch build and push to GHCR on tags and `main` branch.
  * `.github/workflows/release.yml`: Automated matrix builds for Linux (`amd64`, `arm64`) and macOS (`darwin-amd64`, `darwin-arm64`), generating `SHA256SUMS.txt` and publishing GitHub Releases.
* **Thread-Local Packet Buffer Pooling**:
  * Implemented `acquirePacketBuffer` and `releasePacketBuffer` with thread-local pooling (`gPacketBufferPool`) in `protocol/codec.nim`, cutting heap churn and GC pressure under high-volume packet routing.
* **Zero-Copy Startup Parameter Parser**:
  * Implemented `findStartupUser` to extract client usernames directly from startup packet buffers, eliminating `Table[string, string]` allocations during connection handshakes.

### Fixed
* **Memory Leak Resolution (`--mm:orc`)**:
  * Resolved multi-gigabyte closure reference leaks occurring under `--mm:arc` with `asyncdispatch` `Future` cycles.
  * Preserved ORC cycle collection in `config.nims`. Empirically verified via Linux `/proc/<pid>/status`: `VmRSS` remains strictly flat at **21.1 – 24.5 MB** across >15 million transactions.

---

## [0.3.0] - 2026-10-10

### Added
* **SCRAM-SHA-256 Frontend Authentication (SASL Server Mode)**:
  * Implemented server-side SASL state machine in `crypto/scram.nim` (`ScramVerifier`, `ScramServerSession`, `generateVerifier`, `newScramServerSession`, `processClientFirstAndBuildChallenge`, `verifyClientFinal`).
  * Precomputes SCRAM Verifiers (`salt`, `StoredKey`, `ServerKey`) once at boot, completely eliminating runtime PBKDF2 calculation overhead on client connections.
  * HermesPG now acts as an active gatekeeper on the proxy frontend: validates connecting clients against configured credentials using mutual SCRAM-SHA-256.
  * Added `buildAuthErrorPacket` in `protocol/messages.nim` producing standard PostgreSQL error packets with SQLSTATE `28P01` (`FATAL: password authentication failed`).
  * Immediate brute-force mitigation: unauthorized clients and invalid passwords are rejected in `< 2.1 µs` (mitigation capacity: ~493,000 blocks/sec per CPU core).
* **Built-in Prometheus & OpenMetrics Exporter (`/metrics`)**:
  * Implemented lock-free, zero-allocation metrics engine in `metrics.nim` utilizing hardware atomics (`std/atomics.Atomic[int]`) with zero GC overhead in the query dispatch path.
  * Exposes 21+ granular metrics adhering to OpenMetrics specification covering active/idle pooled backends, fast-path vs slow-path acquisition rates, queue depth, fail-fast load shedding rejections (SQLSTATE `53300`), client connections, throughput (TPS/QPS), SCRAM security failure breakdowns, and watchdog auto-rollbacks.
  * Dedicated lightweight asynchronous HTTP metrics server listening on port `9127` by default (`-m, --metrics-port`, `--metrics-bind`, `--no-metrics`).
  * Added unit and integration tests in `tests/test_metrics.nim` verifying atomic operations, OpenMetrics format compliance, and non-blocking asynchronous HTTP scrapes.
* **Turnkey Prometheus & Grafana Monitoring Stack**:
  * Orchestrated multi-container observability stack in `deploy/monitoring/docker-compose.yml` with Prometheus 2.51 and Grafana 10.4.
  * Automated Prometheus datasource provisioning and pre-configured live dashboard (`hermespg_overview.json`) featuring real-time stat cards, throughput time-series, pool saturation gauges, queue depth graphs, and authentication security tracking.
  * Enabled anonymous viewer access in Grafana for instant zero-credential browser monitoring at `http://localhost:3000`.
* **Cryptographic Efficiency Test Suite**:
  * Added `tests/bench_scram_efficiency.nim` benchmarking verification latency (3.72 µs/op, ~268,800 ops/sec per core) and rejection latency (2.03 µs/op).
  * Added `tests/test_scram_live.nim` for live end-to-end backend handshake integration tests against PostgreSQL.

### Security
* **Zero-Plaintext Gatekeeper Architecture**:
  * The proxy does not store or process passwords in plaintext during active client sessions; verification occurs strictly via precomputed cryptographic Verifiers (`StoredKey` and `ServerKey`).
  * Full protection against replay attacks, eavesdropping, and man-in-the-middle attacks via cryptographically random 24-byte nonces generated on both client and proxy sides.
* **Granular Security Telemetry**:
  * Added real-time tracking of authentication failures labeled by failure cause (`hermespg_auth_failures_total{reason="invalid_password"}` and `{reason="invalid_user"}`) to instantly expose brute-force or credential stuffing attacks.

---

## [0.2.0] - 2026-10-10

### Added
* **SCRAM-SHA-256 Authentication (RFC 5802 / RFC 7677)**:
  * Implemented pure cryptographic primitives in `crypto/scram.nim` using `checksums/sha2` (SHA-256, HMAC-SHA-256, PBKDF2-HMAC-SHA-256) and OS secure random nonce generation (`std/sysrand`).
  * Added full SASL state machine handling (`AuthSASL`, `AuthSASLContinue`, `AuthSASLFinal`) for secure modern PostgreSQL backend connections.
  * Added `tests/test_scram.nim` covering RFC 4231, RFC 6070, and RFC 7677 standard test vectors.
* **Enum-Based Authentication Handshake**:
  * Replaced numerical magic constants (`0..12`) with explicit `AuthRequestKind` enum and converter in `protocol/messages.nim`.

### Fixed
* **Event Loop Timer Leak & 100% CPU/Memory Thrashing**:
  * Replaced `withTimeout` in `backend/pool.nim` with a zero-allocation monotonic deadline queue (`MonoTime`).
  * Replaced millions of concurrent 15-second `sleepAsync` futures in the event loop with a single lightweight background watchdog checking queue heads in $O(1)$.
  * Eliminated multi-gigabyte memory accumulation and CPU thrashing during sustained multi-million transaction workloads. Memory remains flat at ~20 MB across 16 worker threads.
* **Codec Full-Buffer Boundary Protection**:
  * Added defensive reallocation in `protocol/codec.nim` (`readMessageInto` and `readStartupOrSslInto`) to guarantee `availSpace > 0`, preventing tight spin-loops when buffers are full.

### Performance
* **Throughput Surged to 140,904 TPS**:
  * Sustained throughput increased by +42.8% (from 98.6K to 140.9K+ TPS) and latency plunged to 0.71 ms during 3,000,000 transaction continuous `pgbench` saturation.

---

## [0.1.3] - 2026-10-08

### Added
* **Native Multi-Core `SO_REUSEPORT` Worker Scaling**:
  * Added `-w, --workers <num>` CLI flag and `HERMES_WORKERS` environment variable to spawn multi-threaded native event loops bound to the same port using Linux `SO_REUSEPORT`.
  * Each worker manages an autonomous connection pool instance, distributing client traffic seamlessly across all CPU cores with zero lock contention.
* **Speculative Direct Streaming Ingress**:
  * Redesigned packet ingestion in `codec.nim` with a high-performance streaming buffer (`PacketBuffer`) that tracks read/write cursors and performs fast L1 cache compaction (`copyMem`).
  * Eliminated redundant 5-byte header peeking (`MSG_PEEK`). Queries are now ingested in **1 single direct kernel syscall** without epoll roundtrips.
  * Pipelined extended queries (`Parse`, `Bind`, `Describe`, `Execute`, `Sync`) are parsed from the internal stream buffer in **0 syscalls**.
* **Zero-Allocation Synchronous Pool Fast-Path**:
  * Implemented `tryAcquireFast` and `releaseFast` in `pool.nim`. On cache hits (clean, idle backend available), acquisition and release execute synchronously on the stack, completely bypassing `Future` heap allocations and `asyncdispatch` ticks.
* **Unified Network Fallback & High-Density Backlog**:
  * Unified the asynchronous fallback loop to ingest full-buffer chunks directly rather than fragmenting socket reads across arbitrary header/payload boundaries.
  * Increased listener socket backlog to `4096` to smoothly absorb high-concurrency connection bursts.

### Changed
* **Throughput & Latency Surge**:
  * Throughput surged to **98,642+ TPS** with an average latency of **1.01 ms** under high-concurrency `pgbench` benchmarks (100 concurrent clients, 3,000,000 transactions), closing the performance gap with raw unmanaged POSIX threads down to 2.3% while maintaining full memory safety and ARC ergonomics.

---

## [0.1.2] - 2026-10-05

### Added
* **Socket Layer Low-Latency Hardening**:
  * Enabled `TCP_NODELAY` (disabling Nagle's algorithm) and `SO_KEEPALIVE` on both client and backend asynchronous sockets, eliminating 40ms delayed-ACK packet stalls.
  * Added `optimizeSocket` helper with inline pragma for microsecond connection initialization.

### Changed
* **L1 Cache Line Alignment & Memory Layout**:
  * Reordered `BackendConn` struct layout to keep hot fields (`socket`, `id`, `isAlive`, `isDirty`, `inTransaction`, `lastStatus`, `backendPid`, `secretKey`) packed contiguously within the primary 64-byte L1 CPU cache line, moving cold `parameters` tables outside the hot lease loop.
* **Non-Atomic ORC & Binary Stripping**:
  * Disabled multithreading (`switch("threads", "off")`) in `config.nims`, eliminating atomic bus lock instructions (`LOCK XADD`) in reference counting loops for the single-threaded asynchronous epoll architecture.
  * Enabled `--panics:on` and dead-code section stripping (`-ffunction-sections -fdata-sections -Wl,--gc-sections`), producing a 301 KB static Musl container image.
* **Prepared Statement Dirtying Optimization**:
  * Extended `MsgParse` handling to only flag connections dirty when named prepared statements are registered (`payload[0] != '\0'`). Unnamed ephemeral statements used by 95% of standard queries bypass redundant `DISCARD ALL;` session resets.
* **Throughput & Latency Surge**:
  * Sustained multiplexing throughput jumped from 1,197 TPS to **5,500+ TPS** under high concurrency benchmark (nearly 5x improvement), with latency plunging from 41.7 ms to **~9.0 ms**.

---

## [0.1.1] - 2026-10-04

### Fixed
* **Security Hardening for `-d:danger` Mode**:
  * Enforced explicit runtime buffer boundary checks in protocol codec (`readInt32BE`, `readInt16BE`) replacing compiler `assert` statements. Guarantees buffer underflows are intercepted with controlled `ValueError` exceptions even when all compiler checks are stripped.
  * Hardened `ParameterStatus` packet parser with safe forward search for null terminators, eliminating negative slicing indices on malformed network frames.

### Changed
* **Official Branding**:
  * Updated official logo emblem to a clean, square 1:1 format without burned-in typography or confusing subtitles.

---

## [0.1.0] - 2026-10-04

### Added
* **Transaction-Level Pooling Engine**:
  * Multiplex thousands of client connections over a small, bounded pool of physical PostgreSQL connections.
  * Physical connections are leased during active queries/transactions and returned to the pool the instant the session returns to `'I'` (Idle).
* **Extended Query Protocol Support**:
  * Full duplex pipelining support for PostgreSQL wire protocol v3.0 messages: `Parse` ('P'), `Bind` ('B'), `Describe` ('D'), `Execute` ('E'), and `Sync` ('S').
  * Multi-statement transaction blocks (`BEGIN` ... `COMMIT` / `ROLLBACK`) pinned to leased physical backends.
* **Sub-0.2ms Pre-Assembled Handshake**:
  * Startup authentication and server parameter status packets pre-compiled into a contiguous binary memory buffer at boot and dispatched via a single network syscall.
* **Fail-Fast $O(1)$ Load Shedding**:
  * Bounded FIFO wait queue implemented with high-efficiency double-ended queues (`Deque`).
  * Immediate rejection (< 0.2ms) with standard PostgreSQL SQLSTATE `53300` when queue capacity is reached.
* **Session Sanitization & Watchdog**:
  * Automatic `ROLLBACK;` cleanup on client unexpected disconnects.
  * Runtime parameter tracking (`ParameterStatus`) and automatic `DISCARD ALL;` sanitization before re-leasing dirty connections.
  * Idle transaction watchdog (`idleTxTimeoutMs`) terminating abandoned transactions holding locks.
* **Extreme Binary & Container Optimization**:
  * Standalone **287 KB** static Musl ELF binary built with Link-Time Optimization (`-flto`), frame pointer omission, and symbol stripping.
  * Zero-dependency **326 KB** Docker container running directly `FROM scratch` as PID 1.
* **Multi-Language Driver Test Suite**:
  * Containerized automated test harness validating Node.js (`node-postgres`), Go (`jackc/pgx/v5`), Python (`psycopg3`), and C# (`Npgsql 8.0`).
* **Stress & Benchmark Harness**:
  * Integrated `pgbench` automation measuring high-concurrency multiplexing and load-shedding accuracy.
* **12-Factor Dynamic Configuration**:
  * Unified CLI flags and environment variables (`HERMES_PORT`, `PGHOST`, `PGPORT`, `HERMES_MAX_CONNS`, `HERMES_MAX_QUEUE`, etc.).
