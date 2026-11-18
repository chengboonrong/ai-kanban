import { readdir, readFile } from 'node:fs/promises';
import type pg from 'pg';
import { createPool } from './db.ts';

const dir = new URL('../../../infrastructure/migrations/', import.meta.url);

/** Applies infrastructure/migrations/*.sql in name order, each once, each in its own transaction. */
export async function migrate(pool: pg.Pool) {
  const c = await pool.connect();
  try {
    await c.query('SELECT pg_advisory_lock(7274001)');
    await c.query('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
    const done = new Set((await c.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name));
    for (const name of (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort()) {
      if (done.has(name)) continue;
      try {
        await c.query('BEGIN');
        await c.query(await readFile(new URL(name, dir), 'utf8'));
        await c.query('INSERT INTO schema_migrations (name) VALUES ($1)', [name]);
        await c.query('COMMIT');
      } catch (err) {
        await c.query('ROLLBACK');
        throw err;
      }
    }
  } finally {
    await c.query('SELECT pg_advisory_unlock(7274001)');
    c.release();
  }
}

if (import.meta.main) {
  const pool = createPool();
  await migrate(pool);
  await pool.end();
}
