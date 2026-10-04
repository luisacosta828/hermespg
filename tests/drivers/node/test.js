const { Client } = require('pg');

async function run() {
  const host = process.env.PGHOST || '127.0.0.1';
  const port = parseInt(process.env.PGPORT || '6432', 10);
  const user = process.env.PGUSER || 'postgres';
  const password = process.env.PGPASSWORD || '';
  const database = process.env.PGDATABASE || 'postgres';

  console.log(`[NODE] Connecting to HermesPG at ${host}:${port}...`);
  const client = new Client({ host, port, user, password, database });
  await client.connect();

  console.log('[NODE] 1. Testing Simple Query (SELECT 1)...');
  const res1 = await client.query('SELECT 1 AS num;');
  if (res1.rows[0].num !== 1) throw new Error(`Expected 1, got ${res1.rows[0].num}`);

  console.log('[NODE] 2. Testing Extended Query Protocol (Parameterized SELECT $1 + $2)...');
  const res2 = await client.query('SELECT $1::int + $2::int AS total;', [20, 22]);
  if (res2.rows[0].total !== 42) throw new Error(`Expected 42, got ${res2.rows[0].total}`);

  console.log('[NODE] 3. Testing Transaction Block (BEGIN -> SELECT -> COMMIT)...');
  await client.query('BEGIN;');
  const res3 = await client.query('SELECT 100 AS val;');
  if (res3.rows[0].val !== 100) throw new Error(`Expected 100, got ${res3.rows[0].val}`);
  await client.query('COMMIT;');

  await client.end();
  console.log('[NODE] ✅ SUCCESS: All node-postgres tests passed with HermesPG!');
}

run().catch((err) => {
  console.error('[NODE] ❌ FAILED:', err);
  process.exit(1);
});
