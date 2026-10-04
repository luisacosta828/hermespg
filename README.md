# ⚡ HermesPG

> **A lightweight, ultra-fast PostgreSQL connection pooler and proxy written in Nim.**

HermesPG enables thousands of concurrent frontend connections to share a small, bounded pool of physical PostgreSQL connections using transaction-level multiplexing, zero-latency pre-assembled handshakes, and bounded $O(1)$ load-shedding queues.

---

## 🚀 Key Features

* **Transaction-Level Pooling**: Clients stay connected indefinitely without consuming Postgres backend processes. Physical connections are leased only during query/transaction execution and returned to the pool the moment the session returns to `Idle` (`'I'`).
* **Sub-0.2ms Pre-Assembled Handshake**: Initial client authentication and runtime parameter status packets are pre-assembled into a single contiguous binary buffer at startup and dispatched in a single network syscall (`send`), drastically reducing connection setup latency.
* **Fail-Fast Load Shedding**: Implements a bounded double-ended queue (`Deque`) in $O(1)$. When queue capacity is reached, excess requests are rejected immediately without memory allocation or socket thrashing.
* **Compile-Time Error Wire Packets**: Native PostgreSQL binary error responses (`WireTimeoutError`, `WireQueueFullError`, `WireIdleTxTimeoutError`, `WirePoolShuttingDownError`) are pre-generated at compile time with standard SQLSTATE codes (`53300`, `25P03`, `57P01`).
* **Session Sanitization & Auto-Rollback**:
  * Unfinished transactions abandoned by disconnected clients are intercepted and safely cleaned with an automatic `ROLLBACK;`.
  * Reused connections are sanitized with `DISCARD ALL;` before being handed to new clients when state modification occurs.
* **In-Transaction Watchdog**: Automatically terminates rogue or abandoned clients holding idle transactions (`idleTxTimeoutMs`), preventing connection starvation.
* **POSIX Socket Tuning**: Automatically checks and raises `RLIMIT_NOFILE` up to 65,536 descriptors at runtime.
* **Zero Stop-the-World Pauses**: Built with Nim's deterministic ARC/ORC memory management (`--mm:orc`).

---

## 📐 Architecture

```
Clients (1,000+ Apps)
       │ (TCP :6432)
       ▼
 ┌──────────────┐
 │   HermesPG   │ ── Fast-Handshake Buffer (<0.2ms)
 │  Proxy Core  │ ── Transaction Watchdog (idleTxTimeoutMs)
 └──────┬───────┘
        │
 ┌──────▼───────┐
 │  Connection  │ ── Idle Stack (LIFO)
 │     Pool     │ ── Wait Queue O(1) + Load Shedding
 └──────┬───────┘
        │ (TCP :5432)
        ▼
   PostgreSQL (e.g. 10 physical connections)
```

---

## 🛠️ Requirements & Building

* **Nim >= 2.0.0**
* **PostgreSQL** running locally or accessible via network.

### Build release binary:
```bash
nim c -d:release src/hermespg.nim
```

### Run tests:
```bash
nim c -r tests/test_protocol.nim
nim c -r tests/test_pool.nim
```

---

## ⚡ Running the Proxy

1. Start the proxy:
```bash
./hermespg
```

By default, HermesPG listens on port `6432` and connects to PostgreSQL on `127.0.0.1:5432`.

2. Connect any PostgreSQL client (e.g., `psql`):
```bash
psql -h 127.0.0.1 -p 6432 -U postgres -d postgres
```

---

## 📊 Benchmarking

HermesPG includes a high-concurrency asynchronous benchmark tool simulating 1,000+ concurrent clients:

```bash
nim c -d:release tests/bench_load.nim
./tests/bench_load 1000
```

---

## 📜 License

MIT License. Developed by luisacosta828.
