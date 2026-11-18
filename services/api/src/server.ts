import { buildApp } from './app.ts';
import { createPool } from './db.ts';
import { migrate } from './migrate.ts';

const pool = createPool();
await migrate(pool);
const app = await buildApp({ pool, authMode: process.env.AUTH_MODE ?? 'none', logger: true });
await app.listen({ host: process.env.HOST ?? '127.0.0.1', port: Number(process.env.PORT ?? 8080) });
