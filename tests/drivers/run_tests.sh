#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

echo "=========================================================="
echo "⚡ HermesPG Multi-Language Driver Test Harness"
echo "=========================================================="

if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    echo "[ERROR] Docker Compose is required to run the containerized test suite."
    exit 1
fi

cleanup() {
    echo "[*] Cleaning up test containers..."
    $COMPOSE_CMD -f "$DIR/docker-compose.test.yml" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[*] 0/6 Building all test images..."
$COMPOSE_CMD -f "$DIR/docker-compose.test.yml" build

echo "[*] 1/6 Starting PostgreSQL and HermesPG services..."
$COMPOSE_CMD -f "$DIR/docker-compose.test.yml" up -d postgres hermespg

echo "[*] 2/6 Waiting for Postgres and HermesPG to be ready..."
sleep 4

echo "[*] 3/6 Running Node.js driver test (node-postgres)..."
$COMPOSE_CMD -f "$DIR/docker-compose.test.yml" run --rm test-node

echo "[*] 4/6 Running Go driver test (jackc/pgx/v5)..."
$COMPOSE_CMD -f "$DIR/docker-compose.test.yml" run --rm test-go

echo "[*] 5/6 Running Python driver test (psycopg3)..."
$COMPOSE_CMD -f "$DIR/docker-compose.test.yml" run --rm test-python

echo "[*] 6/6 Running C# .NET driver test (Npgsql 8.0)..."
$COMPOSE_CMD -f "$DIR/docker-compose.test.yml" run --rm test-csharp

echo "=========================================================="
echo "✅ ALL MULTI-LANGUAGE DRIVER TESTS PASSED SUCCESSFULLY!"
echo "=========================================================="

