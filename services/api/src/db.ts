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
    return result;
  } catch (err) {
    await c.query('ROLLBACK');
    throw err;
  } finally {
    c.release();
  }
}

export function httpError(statusCode: number, message: string) {
  return Object.assign(new Error(message), { statusCode });
}
