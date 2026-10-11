#!/usr/bin/env bash
set -e

CLIENTS="${1:-20}"
DURATION="${2:-60}"
THREADS="${3:-4}"
HOST="${PGHOST:-127.0.0.1}"
PORT="${PGPORT:-6432}"
USER="${PGUSER:-scram_user}"
PASSWORD="${PGPASSWORD:-HermesSecr3t!2026}"
DB="${PGDATABASE:-postgres}"

echo "================================================================"
echo "⚡ HermesPG Live Benchmark & Observability Load Generator"
echo "================================================================"
echo "Target Proxy:        ${HOST}:${PORT}"
echo "Database:            ${DB} (User: ${USER})"
echo "Concurrency:         ${CLIENTS} clients across ${THREADS} client threads"
echo "Duration:            ${DURATION} seconds"
echo "Grafana Dashboard:   http://localhost:3000 (Anonymous Viewer mode)"
echo "Prometheus Metrics:  http://localhost:9090 (or :9127/metrics)"
echo "================================================================"
echo ""

SQL_FILE=$(mktemp /tmp/hermespg_bench_XXXXXX.sql)
echo "SELECT 1;" > "$SQL_FILE"

# Background injector: injects security telemetry and dirty session resets periodically
(
  CYCLE_INTERVAL=10
  MAX_CYCLES=$(( DURATION / CYCLE_INTERVAL ))
  for ((i=1; i<=MAX_CYCLES; i++)); do
    sleep "$CYCLE_INTERVAL"
    # Invalidate password attempt (triggers hermespg_auth_failures_total{reason="invalid_password"})
    PGPASSWORD="WrongPassword" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c "SELECT 1;" >/dev/null 2>&1 || true
    # Invalidate user attempt (triggers hermespg_auth_failures_total{reason="invalid_user"})
    PGPASSWORD="NoUser" psql -h "$HOST" -p "$PORT" -U "unknown_attacker" -d "$DB" -c "SELECT 1;" >/dev/null 2>&1 || true
    # Sanitize test (DISCARD ALL)
    PGPASSWORD="$PASSWORD" psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c "SET timezone = 'UTC'; SELECT 1;" >/dev/null 2>&1 || true
  done
) &
INJECTOR_PID=$!

echo "Starting sustained load..."
export PGPASSWORD="$PASSWORD"
pgbench -h "$HOST" -p "$PORT" -U "$USER" -c "$CLIENTS" -j "$THREADS" -T "$DURATION" -P 5 -f "$SQL_FILE" -n "$DB"

wait "$INJECTOR_PID" 2>/dev/null || true
rm -f "$SQL_FILE"

echo ""
echo "=== Benchmark Run Completed Successfully ==="
