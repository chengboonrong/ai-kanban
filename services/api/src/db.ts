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

let cleaned = 0;

/**
 * A fixed-window limit shared by every API process: at most `max` calls per `name` + key in each `windowMs` (a minute by
 * default), else 429 with retry-after. One atomic upsert per check, on the database's clock. A denial is remembered in
 * the process until its window ends, so a flood of rejected calls costs no database write each (it only ever rejects
 * sooner; the limit stays shared). Expired rows and remembered denials are dropped by whichever call comes next, at most
 * once a minute per process; past 100,000 remembered denials, further ones aren't remembered (memory stays bounded).
 */
export function rateLimit(pool: pg.Pool, name: string, max: number, windowMs = 60_000) {
  const denied = new Map<string, number>(); // key -> when its denial ends, on this process's clock
  let pruned = 0;
  return async (key: string) => {
    const now = Date.now();
    if (now - cleaned >= 60_000) {
      cleaned = now;
      pool.query('DELETE FROM rate_limits WHERE reset_at <= now()').catch(() => {}); // housekeeping; the next sweep retries
    }
    if (now - pruned >= 60_000) {
      pruned = now;
      for (const [k, until] of denied) if (until <= now) denied.delete(k);
    }
    const until = denied.get(key);
    if (until && until > now) throw tooMany(Math.ceil((until - now) / 1000));
    const { rows: [w] } = await pool.query(
      `INSERT INTO rate_limits (limiter, key, count, reset_at) VALUES ($1, $2, 1, now() + $3 * interval '1 millisecond')
       ON CONFLICT (limiter, key) DO UPDATE SET
         count = CASE WHEN rate_limits.reset_at <= now() THEN 1 ELSE rate_limits.count + 1 END,
         reset_at = CASE WHEN rate_limits.reset_at <= now() THEN now() + $3 * interval '1 millisecond' ELSE rate_limits.reset_at END
       RETURNING count, ceil(extract(epoch FROM reset_at - now()))::int AS wait`,
      [name, key, windowMs],
    );
    if (w.count > max) {
      const wait = Math.max(w.wait, 1);
      if (denied.size < 100_000) denied.set(key, Date.now() + wait * 1000);
      throw tooMany(wait);
    }
  };
}
