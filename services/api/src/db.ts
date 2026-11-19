import { createHash } from 'node:crypto';
import pg from 'pg';

export type Db = pg.Pool | pg.PoolClient;

export function createPool(url = process.env.DATABASE_URL ?? 'postgres://kanban:kanban@localhost:55432/kanban') {
  return new pg.Pool({ connectionString: url });
}

export async function tx<T>(pool: pg.Pool, fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const result = await fn(c);
    await c.query('COMMIT');
    c.release();
    return result;
  } catch (err) {
    // A failed ROLLBACK means a broken connection: destroy it instead of returning it to the pool.
    await c.query('ROLLBACK').then(() => c.release(), (rollbackErr) => c.release(rollbackErr));
    throw err;
  }
}

export function httpError(statusCode: number, message: string) {
  return Object.assign(new Error(message), { statusCode });
}

export const sha256 = (s: string) => createHash('sha256').update(s).digest();

const tooMany = (wait: number) =>
  Object.assign(httpError(429, `Too many requests; try again in ${wait} s`), { headers: { 'retry-after': String(wait) } });

/**
 * A fixed-window limit: at most `max` calls per key in each `windowMs` (a minute by default), else 429 with retry-after.
 * Expired keys are dropped at most once a minute; past 100,000 live keys new ones are refused (fails closed rather than
 * growing without bound).
 * ponytail: in memory, per process; move it to a shared store if the API ever runs as more than one instance.
 */
export function rateLimit(max: number, windowMs = 60_000) {
  const windows = new Map<string, { count: number; resetAt: number }>();
  let cleaned = 0;
  return (key: string) => {
    const now = Date.now();
    if (windows.size > 10_000 && now - cleaned >= 60_000) {
      cleaned = now;
      for (const [k, w] of windows) if (w.resetAt <= now) windows.delete(k);
    }
    let w = windows.get(key);
    if (!w || w.resetAt <= now) {
      if (!w && windows.size >= 100_000) throw tooMany(60);
      windows.set(key, (w = { count: 0, resetAt: now + windowMs }));
    }
    if (++w.count > max) throw tooMany(Math.ceil((w.resetAt - now) / 1000));
  };
}
