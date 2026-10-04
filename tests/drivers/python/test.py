import os
import sys
import psycopg

def main():
    host = os.environ.get("PGHOST", "127.0.0.1")
    port = int(os.environ.get("PGPORT", "6432"))
    user = os.environ.get("PGUSER", "postgres")
    password = os.environ.get("PGPASSWORD", "")
    database = os.environ.get("PGDATABASE", "postgres")

    print(f"[PYTHON] Connecting to HermesPG at {host}:{port} via psycopg3...")
    with psycopg.connect(host=host, port=port, user=user, password=password, dbname=database, autocommit=True) as conn:
        with conn.cursor() as cur:
            # 1. Simple query
            print("[PYTHON] 1. Testing Simple Query (SELECT 1)...")
            cur.execute("SELECT 1 AS num;")
            row = cur.fetchone()
            assert row[0] == 1, f"Expected 1, got {row[0]}"

            # 2. Extended query with parameters
            print("[PYTHON] 2. Testing Extended Query Protocol (SELECT %s + %s)...")
            cur.execute("SELECT %s::int + %s::int AS total;", (20, 22))
            row = cur.fetchone()
            assert row[0] == 42, f"Expected 42, got {row[0]}"

        # 3. Transaction block
        print("[PYTHON] 3. Testing Transaction Block (BEGIN -> SELECT -> COMMIT)...")
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute("SELECT 100 AS val;")
                row = cur.fetchone()
                assert row[0] == 100, f"Expected 100, got {row[0]}"

    print("[PYTHON] ✅ SUCCESS: All psycopg3 tests passed with HermesPG!")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[PYTHON] ❌ FAILED: {e}", file=sys.stderr)
        sys.exit(1)
