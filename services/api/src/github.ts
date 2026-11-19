import { createHmac, createPrivateKey, sign, timingSafeEqual, type KeyObject } from 'node:crypto';
import { readFileSync } from 'node:fs';

/** GitHub REST API version this code is written against. */
const API_VERSION = '2026-03-10';

export interface GitHubConfig {
  clientId: string;
  privateKey: KeyObject;
  webhookSecret: string;
  apiUrl: string;
  /** github.com itself (GITHUB_WEB_URL), for the sign-in Device Flow. */
  webUrl: string;
}

/** Reads the app's settings from the environment; `missing` names what's absent when sync can't run. */
export function githubConfigFromEnv(env = process.env): { config?: GitHubConfig; missing: string[] } {
  const missing = ['GITHUB_APP_CLIENT_ID', 'GITHUB_APP_PRIVATE_KEY_PATH', 'GITHUB_WEBHOOK_SECRET'].filter((k) => !env[k]);
  if (missing.length) return { missing };
  return {
    missing,
    config: {
      clientId: env.GITHUB_APP_CLIENT_ID!,
      privateKey: createPrivateKey(readFileSync(env.GITHUB_APP_PRIVATE_KEY_PATH!)),
      webhookSecret: env.GITHUB_WEBHOOK_SECRET!,
      apiUrl: (env.GITHUB_API_URL ?? 'https://api.github.com').replace(/\/$/, ''),
      webUrl: (env.GITHUB_WEB_URL ?? 'https://github.com').replace(/\/$/, ''),
    },
  };
}

const b64url = (v: object | Buffer) => (Buffer.isBuffer(v) ? v : Buffer.from(JSON.stringify(v))).toString('base64url');

/** The app's own credential: an RS256 JWT, valid 9 minutes (GitHub allows 10), backdated 60 s for clock drift. */
export function appJwt(clientId: string, key: KeyObject, now = Math.floor(Date.now() / 1000)) {
  const unsigned = `${b64url({ alg: 'RS256', typ: 'JWT' })}.${b64url({ iat: now - 60, exp: now + 540, iss: clientId })}`;
  return `${unsigned}.${b64url(sign('sha256', Buffer.from(unsigned), key))}`;
}

/** Checks X-Hub-Signature-256 against the raw request body, in constant time. */
export function validSignature(secret: string, body: Buffer, header: string | undefined) {
  if (!header) return false;
  const expected = Buffer.from(`sha256=${createHmac('sha256', secret).update(body).digest('hex')}`);
  const given = Buffer.from(header);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

export class GitHubError extends Error {
  readonly status: number;
  /** True when retrying later may succeed (rate limits, server errors). */
  readonly retryable: boolean;
  /** Milliseconds GitHub asked us to wait before trying again (rate limits). */
  readonly retryAfter?: number;
  constructor(status: number, message: string, retryable: boolean, retryAfter?: number) {
    super(message);
    this.status = status;
    this.retryable = retryable;
    this.retryAfter = retryAfter;
  }
}

/** Minimal GitHub App client: installation tokens per repository, cached until shortly before they expire. */
export function gitHubClient(config: GitHubConfig) {
  const installations = new Map<string, { token: string; expires: number; appId: number; appSlug: string }>();
  // ponytail: one pause for the whole app, not per installation; fine while it's installed on a handful of repositories.
  let pausedUntil = 0; // after a rate limit, no request at all until GitHub's reset (GitHub may ban clients that keep going)

  /** `shared: false` for a user's own token: its rate limit is theirs, so it neither waits for nor sets the app's pause. */
  async function call(method: string, path: string, auth: string, body?: object, { shared = true } = {}) {
    if (shared && Date.now() < pausedUntil) throw new GitHubError(429, 'GitHub rate limit: waiting for it to reset', true, pausedUntil - Date.now());
    let res: Response;
    try {
      res = await fetch(`${config.apiUrl}${path}`, {
        method,
        headers: {
          accept: 'application/vnd.github+json',
          authorization: `Bearer ${auth}`,
          'x-github-api-version': API_VERSION,
          'user-agent': 'ai-kanban',
          ...(body && { 'content-type': 'application/json' }),
        },
        body: body && JSON.stringify(body),
        signal: AbortSignal.timeout(20_000),
      });
    } catch (e) {
      throw new GitHubError(0, `GitHub unreachable: ${(e as Error).message}`, true);
    }
    if (res.ok) return res.status === 204 ? undefined : res.json();
    const text = (await res.text().catch(() => '')).slice(0, 500);
    const message = `GitHub ${method} ${path.split('?')[0]}: ${res.status} ${(safeJson(text) as { message?: string })?.message ?? text}`;
    // 403/429 with an exhausted or secondary rate limit is temporary; other 4xx won't fix themselves.
    const limited = res.status === 429 || (res.status === 403 && (res.headers.get('x-ratelimit-remaining') === '0' || /rate limit/i.test(text)));
    const wait = limited ? retryAfter(res.headers) : undefined;
    if (wait && shared) pausedUntil = Date.now() + wait;
    throw new GitHubError(res.status, message, limited || res.status >= 500, wait);
  }

  async function installation(repository: string) {
    const cached = installations.get(repository);
    if (cached && cached.expires - Date.now() > 5 * 60_000) return cached;
    const jwt = appJwt(config.clientId, config.privateKey);
    const installation = (await call('GET', `/repos/${repository}/installation`, jwt).catch((e: GitHubError) => {
      throw e.status === 404 ? new GitHubError(404, `the GitHub App isn't installed on ${repository}`, false) : e;
    })) as { id: number; app_id: number; app_slug: string };
    const repo = repository.split('/')[1];
    const { token, expires_at } = (await call('POST', `/app/installations/${installation.id}/access_tokens`, jwt, {
      repositories: [repo],
    })) as { token: string; expires_at: string };
    const entry = { token, expires: Date.parse(expires_at), appId: installation.app_id, appSlug: installation.app_slug };
    installations.set(repository, entry);
    return entry;
  }

  /** A Device Flow endpoint on github.com (no client secret). Its own errors come back as 200 with `error`. */
  async function web(path: string, params: Record<string, string>) {
    let res: Response;
    try {
      res = await fetch(`${config.webUrl}${path}?${new URLSearchParams({ client_id: config.clientId, ...params })}`, {
        method: 'POST',
        headers: { accept: 'application/json', 'user-agent': 'ai-kanban' },
        signal: AbortSignal.timeout(20_000),
      });
    } catch (e) {
      throw new GitHubError(0, `GitHub unreachable: ${(e as Error).message}`, true);
    }
    const text = (await res.text().catch(() => '')).slice(0, 2000);
    if (!res.ok) throw new GitHubError(res.status, `GitHub POST ${path}: ${res.status}`, res.status >= 500);
    return (safeJson(text) ?? {}) as Record<string, string | number | undefined>;
  }

  /** A 401 means the cached token was revoked or expired early: fetch a new one and try once more. */
  async function asInstallation(repository: string, method: string, path: string, body?: object) {
    try {
      return await call(method, path, (await installation(repository)).token, body);
    } catch (e) {
      if (!(e instanceof GitHubError && e.status === 401)) throw e;
      installations.delete(repository);
      return call(method, path, (await installation(repository)).token, body);
    }
  }

  return {
    /** Calls the REST API as the app's installation on `repository` ("owner/name"). */
    async request<T = unknown>(repository: string, method: string, path: string, body?: object): Promise<T> {
      return (await asInstallation(repository, method, path, body)) as T;
    },
    /** Runs a GraphQL query as the app's installation on `repository`. */
    async graphql<T = unknown>(repository: string, query: string, variables: object): Promise<T> {
      const res = (await asInstallation(repository, 'POST', '/graphql', { query, variables })) as {
        data?: T;
        errors?: { type?: string; message: string }[];
      };
      if (res.errors?.length) {
        const limited = res.errors.some((e) => e.type === 'RATE_LIMITED');
        if (limited) pausedUntil = Date.now() + 60_000;
        throw new GitHubError(200, `GitHub GraphQL: ${res.errors.map((e) => e.message).join('; ')}`, limited, limited ? 60_000 : undefined);
      }
      return res.data as T;
    },
    /** Starts a Device Flow sign-in: GitHub's device_code, user_code, verification_uri, interval, expires_in (or error). */
    deviceCode: () => web('/login/device/code', {}),
    /** Polls for the user's token: access_token, or error (authorization_pending, slow_down with interval, ...). */
    deviceToken: (deviceCode: string) =>
      web('/login/oauth/access_token', { device_code: deviceCode, grant_type: 'urn:ietf:params:oauth:grant-type:device_code' }),
    /** The user a (one-shot) user token belongs to. */
    user: (token: string) => call('GET', '/user', token, undefined, { shared: false }) as Promise<{ id: number; login: string; name: string | null }>,
    /** The app's id and slug: issues it creates carry performed_via_github_app.id and the author `<slug>[bot]`. */
    async app(repository: string) {
      const { appId, appSlug } = await installation(repository);
      return { id: appId, slug: appSlug };
    },
  };
}

/**
 * How long a rate limit asks us to wait: retry-after (seconds); else, when the primary limit is used up, until
 * x-ratelimit-reset (epoch seconds); else (a secondary limit) at least a minute, as GitHub advises.
 */
function retryAfter(headers: Headers): number {
  const after = Number(headers.get('retry-after'));
  if (after > 0) return after * 1000;
  const reset = Number(headers.get('x-ratelimit-reset'));
  if (headers.get('x-ratelimit-remaining') === '0' && reset > 0) return Math.max(60_000, reset * 1000 - Date.now());
  return 60_000;
}

export type GitHubClient = ReturnType<typeof gitHubClient>;

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
