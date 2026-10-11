# 📊 HermesPG Monitoring Stack (Prometheus + Grafana)

This directory contains the complete observability stack for HermesPG, pre-configured to scrape native metrics in **OpenMetrics** standard format every 2 seconds and visualize them in a Grafana dashboard with zero manual configuration.

---

## 🚀 Quickstart

### 1. Start HermesPG with Metrics Exporter Active
HermesPG exposes the `/metrics` endpoint on port `9127` by default:

```bash
./hermespg -U scram_user -W 'HermesSecr3t!2026' -p 6432 -c 10
```

You can verify the metrics payload directly:
```bash
curl -s http://localhost:9127/metrics
```

### 2. Launch the Monitoring Stack
From this directory (`deploy/monitoring`):

```bash
docker compose up -d
# or alternatively with podman:
# podman-compose up -d
```

### 3. Access Web Interfaces
- **Grafana Dashboard**: [http://localhost:3000](http://localhost:3000)
  - *Direct Access*: Anonymous Viewer mode enabled (no login credentials required).
  - *Admin Login*: User `admin`, Password `admin`.
  - *Preloaded Dashboard*: **HermesPG - Production Monitoring & Observability** (in the `HermesPG` folder).
- **Prometheus UI**: [http://localhost:9090](http://localhost:9090)
  - Targets: [http://localhost:9090/targets](http://localhost:9090/targets) (verify HermesPG UP status).

---

## 📈 Dashboard Panels

The pre-loaded dashboard (`hermespg_overview.json`) includes real-time visualizations for:

1. **⚡ Overview & Health**:
   - TPS (Transactions per second in real time: `rate(hermespg_transactions_total[15s])`).
   - QPS (Queries per second: `rate(hermespg_queries_total[15s])`).
   - Leased Physical Backends vs Maximum Pool Capacity.
   - Connected Clients active in frontend.
   - Wait Queue Depth (`Queue Depth`).
   - Proxy Server Uptime.

2. **📈 Traffic & Throughput**:
   - Query and transaction rate per second.
   - Fast-Path acquisition ratio (LIFO cache hit in RAM) vs Slow-Path (asynchronous queue wait).

3. **🏊 Connection Pool Saturation & Queuing**:
   - Leased (active) vs idle available connection distribution.
   - Queued clients and rate of requests rejected due to queue saturation (**Load Shedding** with SQLSTATE `53300`).

4. **🛡️ SCRAM-SHA-256 Authentication & Security**:
   - Successful vs rejected authentication attempt rates.
   - Security failure breakdown by invalid password (`invalid_password`) or unauthorized user (`invalid_user`) with SQLSTATE `28P01`.

5. **🧹 Watchdog & Session Hygiene**:
   - Abandoned transactions automatically rolled back by the watchdog (`ROLLBACK`).
   - Mutated connections sanitized with `DISCARD ALL` prior to reuse.

---

## 🛑 Stopping the Stack
To stop the monitoring containers:
```bash
docker compose down
```
