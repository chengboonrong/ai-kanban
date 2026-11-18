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
