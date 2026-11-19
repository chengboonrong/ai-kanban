import Fastify from 'fastify';
import cors from '@fastify/cors';
import { randomBytes } from 'node:crypto';
import type pg from 'pg';
import { httpError, sha256, tx } from './db.ts';
import { type GitHubClient, GitHubError } from './github.ts';
import { registerRefinementRoutes } from './refinement.ts';
import { registerRoutes } from './routes.ts';
import { gitHubFailed, registerGitHubRoutes, requireWriteAccess } from './sync.ts';

declare module 'fastify' {
  interface FastifyInstance {
    /** Throws 403 unless the user may act on `repository` through the GitHub App (AUTH_MODE=github only). */
    requireWrite(userId: string, repository: string): Promise<void>;
  }
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
  /**
   * 'dev' enables POST /auth/dev-login (passwordless, local only); 'github' signs in with GitHub's Device Flow and gates
   * repository actions on write access. Anything else: no sign-in route.
   */
  authMode: string;
  logger?: boolean;
  /** The GitHub App's client, shared with the sync loop (one rate-limit pause, one token cache); routes that call GitHub answer 503 without it. */
  github?: GitHubClient;
}

const bearer = (header = '') => /^Bearer (\S+)$/.exec(header)?.[1];

/** A new 30-day session for the user, as its bearer token. */
async function newSession(pool: pg.Pool | pg.PoolClient, userId: string) {
  const token = randomBytes(32).toString('base64url');
  await pool.query(`INSERT INTO sessions (token_hash, user_id, expires_at) VALUES ($1, $2, now() + interval '30 days')`, [sha256(token), userId]);
  return token;
}

/** Device Flow answers that mean the code is spent: the user starts again. */
const START_AGAIN: Record<string, string> = {
  expired_token: 'The code expired; start again',
  token_expired: 'The code expired; start again',
  access_denied: 'Sign-in was cancelled on GitHub; start again',
  incorrect_device_code: 'GitHub does not know this code; start again',
};

const tooMany = (wait: number) =>
  Object.assign(httpError(429, `Too many requests; try again in ${wait} s`), { headers: { 'retry-after': String(wait) } });

/**
 * A fixed-window limit: at most `max` calls a minute per key, else 429 with retry-after. Expired keys are dropped at most
 * once a minute; past 100,000 live keys new ones are refused (fails closed rather than growing without bound).
 * ponytail: in memory, per process; move it to a shared store if the API ever runs as more than one instance.
 */
function rateLimit(max: number) {
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
      windows.set(key, (w = { count: 0, resetAt: now + 60_000 }));
    }
    if (++w.count > max) throw tooMany(Math.ceil((w.resetAt - now) / 1000));
  };
}

/**
 * TRUST_PROXY: the proxies' addresses/CIDRs, comma-separated (`127.0.0.1` for cloudflared on this host); unset, req.ip
 * is the socket's. Never `true` or a hop count: a client could then name its own IP (or add the trusted hop itself).
 */
function trustProxy(v = process.env.TRUST_PROXY): string | false {
  if (!v) return false;
  if (/^\d+$/.test(v) || v === 'true') throw new Error('TRUST_PROXY takes the proxy addresses (e.g. 127.0.0.1), not a hop count or true');
  return v;
}

export async function buildApp({ pool, authMode, logger = false, github }: AppOptions) {
  if (authMode === 'dev' && process.env.NODE_ENV === 'production') {
    throw new Error('AUTH_MODE=dev is refused when NODE_ENV=production');
  }
  if (authMode === 'github' && !github) throw new Error('AUTH_MODE=github needs the GitHub App configured (docs/setup/github-app.md)');
  // Behind a reverse proxy, TRUST_PROXY makes req.ip (the rate limits' key) the client, not the proxy.
  const app = Fastify({ logger, trustProxy: trustProxy() });

  // Clients authenticate with bearer tokens, not cookies; the Flutter web dev server runs on a random localhost port.
  // CORS_ORIGINS (comma-separated exact origins) adds a web build served from elsewhere.
  const origins = (process.env.CORS_ORIGINS ?? '').split(',').map((o) => o.trim()).filter(Boolean);
  await app.register(cors, {
    origin: [/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/, ...origins],
    methods: ['GET', 'POST', 'PATCH', 'DELETE'],
  });

  // Don't leak internals (SQL errors, stack messages) in 5xx responses; client errors pass through.
  app.setErrorHandler((err: { statusCode?: number }, req, reply) => {
    if (err instanceof GitHubError) return gitHubFailed(reply, err); // its message names a repository or a status, never a credential
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
    // AUTH_MODE=github: sessions and workers of accounts that never signed in with GitHub (dev-era ones) are refused.
    const github = authMode === 'github';
    if (req.routeOptions.config.worker) {
      const { rows } = await pool.query(
        `UPDATE workers w SET last_seen_at = CASE WHEN $2 AND u.github_id IS NULL THEN w.last_seen_at ELSE now() END
         FROM users u WHERE w.token_hash = $1 AND u.id = w.owner_id RETURNING w.id, w.owner_id, u.github_id`,
        [sha256(token), github],
      );
      if (!rows[0]) throw httpError(401, 'Invalid worker token');
      if (github && !rows[0].github_id) throw httpError(401, 'Sign in with GitHub');
      req.workerId = rows[0].id;
      req.userId = rows[0].owner_id;
      return;
    }
    const { rows } = await pool.query(
      'SELECT s.user_id, u.github_id FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = $1 AND s.expires_at > now()',
      [sha256(token)],
    );
    if (!rows[0]) throw httpError(401, 'Invalid or expired session');
    if (github && !rows[0].github_id) throw httpError(401, 'Sign in with GitHub');
    req.userId = rows[0].user_id;
  });

  const writeLimit = rateLimit(30); // each check is a GitHub call or two, on the installation's rate limit
  app.decorate('requireWrite', async (userId: string, repository: string) => {
    if (authMode !== 'github') return;
    writeLimit(userId);
    await requireWriteAccess(pool, github!, userId, repository);
  });

  // The client picks its sign-in screen from `auth`.
  app.get('/health', { config: { public: true } }, async () => ({ ok: true, auth: authMode === 'dev' || authMode === 'github' ? authMode : 'none' }));

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
           ON CONFLICT (login) DO UPDATE SET login = EXCLUDED.login WHERE users.github_id IS NULL
           RETURNING id, login, display_name AS "displayName"`,
          [login],
        );
        // A GitHub-linked account never gets a dev session: github mode would accept it, with that user's access.
        if (!user) throw httpError(409, 'This login belongs to a GitHub account; sign in with GitHub');
        return { token: await newSession(pool, user.id), user };
      },
    );
  }

  if (authMode === 'github') {
    const gh = github!;
    const deviceLimit = rateLimit(10);
    const tokenLimit = rateLimit(30); // a client polls every 5 s or slower
    app.post('/auth/github/device', { config: { public: true } }, async (req) => {
      deviceLimit(req.ip);
      const d = await gh.deviceCode();
      if (!d.device_code) throw new GitHubError(502, `GitHub refused the sign-in: ${d.error ?? 'no device code'}`, false);
      return { deviceCode: d.device_code, userCode: d.user_code, verificationUri: d.verification_uri, interval: d.interval, expiresIn: d.expires_in };
    });

    app.post(
      '/auth/github/token',
      {
        config: { public: true },
        schema: { body: { type: 'object', required: ['deviceCode'], properties: { deviceCode: { type: 'string', minLength: 1, maxLength: 200 } } } },
      },
      async (req, reply) => {
        tokenLimit(req.ip);
        const t = await gh.deviceToken((req.body as { deviceCode: string }).deviceCode);
        if (t.error === 'authorization_pending' || t.error === 'slow_down') {
          // GitHub names the (raised) interval on slow_down only; 5 s is its minimum.
          return reply.code(202).send({ pending: true, interval: Number(t.interval) || 5 });
        }
        if (typeof t.error === 'string' && START_AGAIN[t.error]) throw httpError(400, START_AGAIN[t.error]);
        if (typeof t.access_token !== 'string') throw new GitHubError(502, `GitHub refused the sign-in: ${t.error ?? 'no token'}`, false);
        // The token is used once, to learn who this is, and dropped: access checks use the app's own token.
        const me = await gh.user(t.access_token);
        const login = me.login.toLowerCase();
        return tx(pool, async (c) => {
          // Whoever else holds this login moves aside: an account renamed on GitHub, or a dev account. A dev account is
          // never adopted: anyone could have dev-logged in under that name.
          await c.query(`UPDATE users SET login = '~' || id WHERE login = $1 AND github_id IS DISTINCT FROM $2`, [login, me.id]);
          const { rows: [user] } = await c.query(
            `INSERT INTO users (login, display_name, github_id) VALUES ($1, $2, $3)
             ON CONFLICT (github_id) DO UPDATE SET login = EXCLUDED.login, display_name = EXCLUDED.display_name
             RETURNING id, login, display_name AS "displayName"`,
            [login, me.name || me.login, me.id],
          );
          return { token: await newSession(c, user.id), user };
        });
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
  registerGitHubRoutes(app, pool, github);
  return app;
}
