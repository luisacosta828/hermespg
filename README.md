<p align="center">
  <img src="assets/logo.jpg" alt="HermesPG Logo" width="220" style="border-radius: 16px;" />
</p>

<h1 align="center">⚡ HermesPG</h1>

<p align="center">
  <strong>Ultra-fast, featherweight PostgreSQL connection pooler and proxy in Nim.</strong><br>
  <em>Sub-0.2ms Handshake • 140,000+ TPS • ~280 KB Binary • Transaction Mode Multiplexing</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Language-Nim%202.0-orange.svg" alt="Nim 2.0" />
  <img src="https://img.shields.io/badge/Throughput-140%2C000%2B%20TPS-brightgreen.svg" alt="Throughput: 140,000+ TPS" />
  <img src="https://img.shields.io/badge/Binary%20Size-280%20KB-blue.svg" alt="Binary Size" />
  <img src="https://img.shields.io/badge/Memory%20Footprint-~3%20MB%20RSS-blueviolet.svg" alt="Memory Footprint" />
  <img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" />
</p>

---

## 📖 Overview

**HermesPG** is a high-performance PostgreSQL connection pooler and proxy engineered from the ground up for extreme efficiency, deterministic memory management, and zero runtime bloat. 

In PostgreSQL, each client connection is a heavyweight operating system process consuming 10 MB to 20 MB of RAM. Scaling to thousands of connections directly against PostgreSQL quickly exhausts memory, triggers lock contention, and leads to connection starvation.

HermesPG solves this by multiplexing **thousands of concurrent client connections** over a small, bounded pool of **10 to 30 physical backend connections** in **Transaction Pooling Mode**.

### 🌟 The "Edge Pool" Architecture

Because HermesPG compiles to a standalone **287 KB static binary** and uses only **~3 MB of RAM**, it can be deployed not only as a central pooler, but also as a distributed **Micro-Pooler / Sidecar**:

* **Kubernetes Pod Sidecar / DaemonSet**: Run a local HermesPG instance alongside your application pods with virtually zero resource cost.
* **Serverless & Edge Runtimes**: Cold-start in **< 2 milliseconds** for AWS Lambda, Fly.io, or edge functions.
* **100x Multiplier**: 10 distributed HermesPG instances holding 5 connections each consume only **50 total connections** on PostgreSQL (a fraction of a 300–500 connection limit), while serving **10,000+ active clients**.

```
       [ Microservice A ]       [ Microservice B ]       [ Edge / Serverless ]
       (1,000 connections)      (1,000 connections)      (5,000 connections)
               │                        │                        │
               ▼                        ▼                        ▼
        ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
        │  HermesPG   │          │  HermesPG   │          │  HermesPG   │
        │ (Sidecar 1) │          │ (Sidecar 2) │          │ (Sidecar N) │
        └──────┬──────┘          └──────┬──────┘          └──────┬──────┘
               │ (5-10 conns)           │ (5-10 conns)           │ (5-10 conns)
               └─────────────────┬──────┴────────────────────────┘
                                 ▼
                   ┌───────────────────────────┐
                   │    PostgreSQL Database    │
                   │ (Max Capacity: 300-500)   │
                   │  Total Used Backends: ~50 │
                   └───────────────────────────┘
```

---

## ⚡ Key Features

* **SCRAM-SHA-256 Mutual Authentication (RFC 5802 / RFC 7677)**: Native cryptographic SASL state machine powered by `checksums/sha2` with OS random nonce generation, seamlessly supporting Cleartext, MD5, and SCRAM-SHA-256 backend handshakes.
* **Zero-Allocation Monotonic Wait Queue**: Queue timeout management driven by high-resolution monotonic deadlines (`MonoTime`) and a single lightweight $O(1)$ watchdog, eliminating event-loop timer proliferation and keeping memory flat under multi-million transaction saturation.
* **Native Multi-Core Worker Scaling (`SO_REUSEPORT`)**: Spawns multiple asynchronous worker threads bound to the same listener port using Linux kernel `SO_REUSEPORT`, scaling horizontally across all CPU cores with zero lock contention.
* **Speculative Direct Streaming Ingress**: Single-syscall packet reads directly from kernel socket receive buffers, eliminating `MSG_PEEK` overhead and parsing pipelined extended query batches in 0 syscalls.
* **Zero-Allocation Pool Fast-Path**: Synchronous stack-allocated acquisition and release (`tryAcquireFast` / `releaseFast`) for clean, idle connections, completely bypassing Future heap allocations and event loop scheduling.
* **Transaction-Level Pooling**: Physical connections are leased only for the duration of a transaction or single query. As soon as PostgreSQL returns `'I'` (Idle), the backend is returned to the pool in $O(1)$.
* **Full Extended Query Protocol Support**: Seamlessly pipelines binary `Parse`, `Bind`, `Describe`, `Execute`, and `Sync` packets with dynamic parameter tracking and transaction pinning.
* **Sub-0.2ms Pre-Assembled Handshake**: Connection parameters and authentication responses are cached into a pre-compiled contiguous binary buffer and dispatched in a single `send` syscall.
* **Fail-Fast $O(1)$ Load Shedding**: Implements a bounded double-ended queue (`Deque`). When peak capacity is reached, excess incoming requests are rejected immediately (< 0.2ms) with SQLSTATE `53300`, preventing database collapse from cascading bufferbloat.
* **Transaction Watchdog (`idleTxTimeoutMs`)**: Detects rogue or abandoned transactions holding locks (`BEGIN` without `COMMIT`), issuing an automatic forced `ROLLBACK` to recover physical connections.
* **Automatic Session Sanitization**: Tracks runtime parameter mutations (`SET timezone ...`) and automatically issues `DISCARD ALL;` before re-leasing dirty connections.
* **Featherweight Native Footprint**: Standalone ~280 KB native binary running with deterministic ARC/ORC memory management (~3 MB baseline RSS) and zero external runtime dependencies.

---

## 🧪 Validated Enterprise Drivers

HermesPG includes an automated multi-language containerized test suite ([`tests/drivers/run_tests.sh`](tests/drivers/run_tests.sh)) verifying 100% protocol fidelity across the industry's top drivers:

| Language | Driver / Library | Simple Query | Extended Query ($1 + $2) | Transaction Block (`BEGIN`..`COMMIT`) |
| :--- | :--- | :---: | :---: | :---: |
| **JavaScript / Node.js** | [`node-postgres (pg)`](tests/drivers/node/test.js) | ✅ Passed | ✅ Passed | ✅ Passed |
| **Go** | [`jackc/pgx/v5`](tests/drivers/go/main.go) | ✅ Passed | ✅ Passed | ✅ Passed |
| **Python** | [`psycopg3`](tests/drivers/python/test.py) | ✅ Passed | ✅ Passed | ✅ Passed |
| **C# / .NET 8** | [`Npgsql 8.0`](tests/drivers/csharp/Program.cs) | ✅ Passed | ✅ Passed | ✅ Passed |

Run the driver test suite:
```bash
./tests/drivers/run_tests.sh
```

---

## 📊 Stress & Concurrency Benchmarks

HermesPG was benchmarked under real-world saturation using `pgbench` (100 concurrent clients, 8 threads, 3,000,000 transactions):

```bash
pgbench -h 127.0.0.1 -p 6432 -U postgres -f bench_query.sql -c 100 -j 8 -t 30000 -n postgres
```

### Empirical Test Results:
* **High-Concurrency Saturation (100 clients $\to$ 48 pooled backends across 16 workers)**:
  * Processed: **3,000,000 / 3,000,000 transactions** with 0 errors (100% completion).
  * Throughput: **140,904+ TPS** sustained (+42.8% throughput surge).
  * Average Latency: **0.71 ms** under full saturation.
  * Memory RSS: **~20 MB flat** across 16 worker threads (zero memory leak across 3 million queries).
* **Load Shedding Under Extreme Overload**:
  * Configured with 1 backend connection and max queue of 5 (Total capacity = 6).
  * Flooded with 20 parallel slow queries.
  * Result: **14 requests shedded instantly (< 0.2ms)** with SQLSTATE `53300`, protecting PostgreSQL CPU and memory from collapse.

---

## 🚀 Getting Started

### Option 1: Docker Compose (Recommended)

Start PostgreSQL 16 and HermesPG in an isolated network:

```bash
docker compose up -d
```

Connect your application to HermesPG on port `6432`:
```bash
psql -h 127.0.0.1 -p 6432 -U postgres -d appdb
```

### Option 2: Pre-compiled Docker Scratch Image

Build the ultra-lightweight 326 KB image:
```bash
docker build -t hermespg:latest .
```

Run directly:
```bash
docker run -d --name hermespg -p 6432:6432 \
  -e PGHOST=host.docker.internal \
  -e PGPASSWORD=secretpassword \
  hermespg:latest
```

### Option 3: Compile from Source (Native)

#### Prerequisites:
* [Nim](https://nim-lang.org/) >= 2.0.0
* GCC or Clang

#### Build optimized static binary:
```bash
nim c -d:danger --opt:speed \
  --passC:"-flto -fomit-frame-pointer -ffunction-sections -fdata-sections" \
  --passL:"-flto -static -s -Wl,--gc-sections" \
  -o:hermespg src/hermespg.nim
```

#### Run HermesPG:
```bash
./hermespg -H 127.0.0.1 -P 5432 -U postgres -W secretpassword -d postgres -c 20
```

---

## ⚙️ Configuration & CLI Options

HermesPG supports full 12-factor configuration via CLI flags and environment variables. CLI flags take precedence over environment variables:

| Flag | Long Option | Environment Variable | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `-b` | `--bind <host>` | `HERMES_BIND` | `0.0.0.0` | Listen IP address for incoming client connections |
| `-p` | `--port <port>` | `HERMES_PORT` / `PORT` | `6432` | Listen port for frontend clients |
| `-H` | `--pg-host <host>` | `PGHOST` | `127.0.0.1` | PostgreSQL server hostname or IP |
| `-P` | `--pg-port <port>` | `PGPORT` | `5432` | PostgreSQL server port |
| `-U` | `--user <user>` | `PGUSER` | `postgres` | Database username |
| `-W` | `--password <pwd>` | `PGPASSWORD` | `""` | Database password |
| `-d` | `--db, --database` | `PGDATABASE` | `postgres` | Database name |
| `-c` | `--max-conns <num>` | `HERMES_MAX_CONNS` | `10` | Maximum physical connections to PostgreSQL |
| `-q` | `--max-queue <num>` | `HERMES_MAX_QUEUE` | `2000` | Maximum waiting clients queue size before Load Shedding |
| `-t` | `--timeout <ms>` | `HERMES_TIMEOUT_MS` | `15000` | Maximum queue acquisition wait time in milliseconds |
| `-i` | `--idle-tx-timeout` | `HERMES_IDLE_TX_TIMEOUT_MS`| `8000` | Max idle transaction time before auto-ROLLBACK (ms) |
| `-r` | `--reset-query <sql>`| `HERMES_RESET_QUERY` | `DISCARD ALL;` | Session cleanup query executed before leasing dirty connections |
| | `--no-reset` | | `false` | Disable automatic session cleanup query |
| `-V` | `--verbose` | `HERMES_VERBOSE` | `false` | Enable detailed debug logging |
| `-h` | `--help` | | | Show CLI help message and exit |
| `-v` | `--version` | | | Show version and exit |

---

## 🗺️ Project Roadmap

HermesPG follows an iterative, production-grade development roadmap:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        HermesPG Development Roadmap                     │
└────────────────────────────────────────────────────────────────────────┘
  [x] Phase 1: Core Engine & Transaction Pooling (Current Release)
       ├── Sub-0.2ms pre-assembled binary handshake
       ├── Full Extended Query protocol pipelining (Parse/Bind/Execute/Sync)
       ├── Transaction state pinning & dirty session tracking
       ├── Bounded O(1) wait queue & Fail-Fast Load Shedding
       ├── Rogue transaction watchdog (auto-ROLLBACK)
       ├── 301 KB Docker Scratch container & 5,500+ sustained TPS
       └── Multi-language driver verification (Node, Go, Python, C#)

  [ ] Phase 2: Modern Authentication & Observability (In Progress)
       ├── Native SCRAM-SHA-256 client & backend authentication
       ├── TLS / SSL encryption (frontend client termination & backend SSL)
       ├── Prometheus metrics exporter endpoint (/metrics)
       │    └── Active connections, queue depth, TPS, shedded requests
       └── Structured JSON logging with configurable log levels

  [ ] Phase 3: Session Pooling & Operational Controls (Planned)
       ├── Session-Level Pooling mode (for stateful legacy applications)
       ├── Query cancellation support (CancelRequest message handling)
       ├── Dynamic runtime reload (SIGHUP configuration reload)
       └── Administrative management console (PAUSE, RESUME, RELOAD, KILL)

  [ ] Phase 4: Multi-Tenancy & Edge Routing (Planned)
       ├── Dynamic multi-database / multi-user routing
       ├── Automatic read/write query splitting for read replicas
       └── Health check and circuit breaker failover for replicas
```

---

## 🧪 Running Native Test Suites

Run the complete native test suite:
```bash
nim c -r tests/test_protocol.nim
nim c -r tests/test_config.nim
nim c -r tests/test_pool.nim
nim c -r tests/test_extended_query.nim
```

---

## 📜 License

HermesPG is open-source software licensed under the [MIT License](LICENSE).
Developed with ⚡ by luisacosta828.
