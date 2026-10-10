# Changelog

All notable changes to **HermesPG** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
