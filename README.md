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

## ⚙️ Configuration & CLI Usage

HermesPG supports comprehensive configuration through both command-line arguments and standard environment variables (12-Factor App pattern). Command-line arguments always take precedence over environment variables.

### Options Reference:

| Flag | Long Option | Environment Variable | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `-b` | `--bind <host>` | `HERMES_BIND` | `0.0.0.0` | IP/Interface to bind the proxy listener |
| `-p` | `--port <port>` | `HERMES_PORT`, `PORT` | `6432` | Listening port for frontend clients |
| `-H` | `--pg-host <host>` | `PGHOST` | `127.0.0.1` | PostgreSQL backend host |
| `-P` | `--pg-port <port>` | `PGPORT` | `5432` | PostgreSQL backend port |
| `-U` | `--user <user>` | `PGUSER` | `postgres` | PostgreSQL connection user |
| `-W` | `--password <pwd>` | `PGPASSWORD` | `""` | PostgreSQL connection password |
| `-d` | `--db, --database` | `PGDATABASE` | `postgres` | Database name |
| `-c` | `--max-conns <n>` | `HERMES_MAX_CONNS` | `10` | Max physical backend connections |
| `-q` | `--max-queue <n>` | `HERMES_MAX_QUEUE` | `2000` | Max clients in waiting queue before Fail-Fast |
| `-t` | `--timeout <ms>` | `HERMES_TIMEOUT_MS` | `15000` | Max queue acquisition wait time (ms) |
| `-i` | `--idle-tx-timeout` | `HERMES_IDLE_TX_TIMEOUT_MS`| `8000` | Max idle transaction time before auto-ROLLBACK (ms) |
| `-r` | `--reset-query <sql>`| `HERMES_RESET_QUERY` | `DISCARD ALL;` | Session cleanup query |
| | `--no-reset` | | `false` | Disable session cleanup query |
| `-V` | `--verbose` | `HERMES_VERBOSE` | `false` | Enable verbose debug logging |
| `-h` | `--help` | | | Show help message and exit |
| `-v` | `--version` | | | Show version and exit |

### Examples:

```bash
# Connect to remote PostgreSQL server with 25 pooled connections
./hermespg -H db.internal.net -P 5432 -U app_user -W secret123 -d production -c 25

# Configure via standard 12-factor environment variables
PGHOST=db.internal.net PGPASSWORD=secret123 HERMES_PORT=6432 ./hermespg
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
