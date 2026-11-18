import Fastify from 'fastify';
import cors from '@fastify/cors';
import { randomBytes } from 'node:crypto';
import type pg from 'pg';
import { httpError, sha256 } from './db.ts';
import { registerRefinementRoutes } from './refinement.ts';
import { registerRoutes } from './routes.ts';
import { registerGitHubRoutes } from './sync.ts';

declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
    /** Set on worker routes; userId is then the worker's owner. */
    workerId: string;
  }
  interface FastifyContextConfig {
    public?: boolean;
    /** Authenticated with a worker token instead of a user session. */
    worker?: boolean;
  }
}

export interface AppOptions {
  pool: pg.Pool;
  /** 'dev' enables POST /auth/dev-login (passwordless, local only). Anything else: no login route yet. */
  authMode: string;
  logger?: boolean;
}

const bearer = (header = '') => /^Bearer (\S+)$/.exec(header)?.[1];

export async function buildApp({ pool, authMode, logger = false }: AppOptions) {
  if (authMode === 'dev' && process.env.NODE_ENV === 'production') {
    throw new Error('AUTH_MODE=dev is refused when NODE_ENV=production');
  }
  const app = Fastify({ logger });

  // Clients authenticate with bearer tokens, not cookies; the Flutter web dev server runs on a random localhost port.
  await app.register(cors, {
    origin: /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/,
    methods: ['GET', 'POST', 'PATCH', 'DELETE'],
  });

  // Don't leak internals (SQL errors, stack messages) in 5xx responses; client errors pass through.
  app.setErrorHandler((err: { statusCode?: number }, req, reply) => {
    if ((err.statusCode ?? 500) < 500) return reply.send(err);
    req.log.error(err);
    return reply.code(500).send({ statusCode: 500, error: 'Internal Server Error', message: 'Internal server error' });
  });

  app.decorateRequest('userId', '');
  app.decorateRequest('workerId', '');
  app.addHook('onRequest', async (req) => {
    if (req.routeOptions.config.public) return;
    const token = bearer(req.headers.authorization);
    if (!token) throw httpError(401, 'Missing bearer token');
    if (req.routeOptions.config.worker) {
      const { rows } = await pool.query('UPDATE workers SET last_seen_at = now() WHERE token_hash = $1 RETURNING id, owner_id', [sha256(token)]);
      if (!rows[0]) throw httpError(401, 'Invalid worker token');
      req.workerId = rows[0].id;
      req.userId = rows[0].owner_id;
      return;
    }
    const { rows } = await pool.query('SELECT user_id FROM sessions WHERE token_hash = $1 AND expires_at > now()', [sha256(token)]);
    if (!rows[0]) throw httpError(401, 'Invalid or expired session');
    req.userId = rows[0].user_id;
  });

  app.get('/health', { config: { public: true } }, async () => ({ ok: true }));

  if (authMode === 'dev') {
    app.log.warn('DEV AUTH ENABLED: anyone who can reach this API can sign in as any login');
    app.post(
      '/auth/dev-login',
      {
        config: { public: true },
        schema: {
          body: {
            type: 'object',
            required: ['login'],
            properties: { login: { type: 'string', pattern: '^[a-z0-9][a-z0-9-]{0,38}$' } },
          },
        },
      },
      async (req) => {
        const { login } = req.body as { login: string };
        const {
          rows: [user],
        } = await pool.query(
          `INSERT INTO users (login, display_name) VALUES ($1, $1)
           ON CONFLICT (login) DO UPDATE SET login = EXCLUDED.login
           RETURNING id, login, display_name AS "displayName"`,
          [login],
        );
        const token = randomBytes(32).toString('base64url');
        await pool.query(`INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, now() + interval '30 days')`, [
          sha256(token),
          user.id,
        ]);
        return { token, user };
      },
    );
  }

  app.post('/auth/logout', async (req, reply) => {
    await pool.query('DELETE FROM sessions WHERE token_hash = $1', [sha256(bearer(req.headers.authorization)!)]);
    return reply.code(204).send();
  });

  app.get('/me', async (req) => {
    const { rows } = await pool.query('SELECT id, login, display_name AS "displayName" FROM users WHERE id = $1', [req.userId]);
    return rows[0];
  });

  registerRoutes(app, pool);
  registerRefinementRoutes(app, pool);
  registerGitHubRoutes(app, pool);
  return app;
}
