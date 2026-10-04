package main

import (
	"context"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
)

func main() {
	host := getEnv("PGHOST", "127.0.0.1")
	port := getEnv("PGPORT", "6432")
	user := getEnv("PGUSER", "postgres")
	password := getEnv("PGPASSWORD", "")
	database := getEnv("PGDATABASE", "postgres")

	connStr := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable&default_query_exec_mode=exec", user, password, host, port, database)
	fmt.Printf("[GO] Connecting to HermesPG at %s:%s...\n", host, port)

	connConfig, err := pgx.ParseConfig(connStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[GO] ❌ Unable to parse config: %v\n", err)
		os.Exit(1)
	}
	connConfig.DefaultQueryExecMode = pgx.QueryExecModeExec

	ctx := context.Background()
	conn, err := pgx.ConnectConfig(ctx, connConfig)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[GO] ❌ Unable to connect: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close(ctx)

	// 1. Simple query
	fmt.Println("[GO] 1. Testing Simple Query (SELECT 1)...")
	var num int
	err = conn.QueryRow(ctx, "SELECT 1").Scan(&num)
	if err != nil || num != 1 {
		fmt.Fprintf(os.Stderr, "[GO] ❌ Failed simple query: %v (num: %d)\n", err, num)
		os.Exit(1)
	}

	// 2. Extended query with parameters (Parse, Bind, Execute)
	fmt.Println("[GO] 2. Testing Extended Query Protocol (SELECT $1 + $2)...")
	var total int
	err = conn.QueryRow(ctx, "SELECT $1::int + $2::int", 20, 22).Scan(&total)
	if err != nil || total != 42 {
		fmt.Fprintf(os.Stderr, "[GO] ❌ Failed extended query: %v (total: %d)\n", err, total)
		os.Exit(1)
	}

	// 3. Multi-statement transaction
	fmt.Println("[GO] 3. Testing Transaction Block (BEGIN -> SELECT -> COMMIT)...")
	tx, err := conn.Begin(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[GO] ❌ Failed Begin tx: %v\n", err)
		os.Exit(1)
	}
	var txVal int
	err = tx.QueryRow(ctx, "SELECT 100").Scan(&txVal)
	if err != nil || txVal != 100 {
		tx.Rollback(ctx)
		fmt.Fprintf(os.Stderr, "[GO] ❌ Failed query inside tx: %v\n", err)
		os.Exit(1)
	}
	err = tx.Commit(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[GO] ❌ Failed Commit tx: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("[GO] ✅ SUCCESS: All jackc/pgx/v5 tests passed with HermesPG!")
}

func getEnv(key, defVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defVal
}
