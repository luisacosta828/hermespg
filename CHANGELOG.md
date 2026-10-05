# Changelog

All notable changes to **HermesPG** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
