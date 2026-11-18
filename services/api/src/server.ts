import { buildApp } from './app.ts';
import { createPool } from './db.ts';
import { githubConfigFromEnv } from './github.ts';
import { migrate } from './migrate.ts';
import { buildWebhookApp, startGitHubSync } from './sync.ts';

const pool = createPool();
await migrate(pool);
const host = process.env.HOST ?? '127.0.0.1';
const app = await buildApp({ pool, authMode: process.env.AUTH_MODE ?? 'none', logger: true });
await app.listen({ host, port: Number(process.env.PORT ?? 8080) });

// Webhooks get their own port so a tunnel to it exposes nothing else (docs/setup/github-app.md).
const { config: github, missing } = githubConfigFromEnv();
const webhooks = await buildWebhookApp({ pool, github, logger: true });
await webhooks.listen({ host, port: Number(process.env.GITHUB_WEBHOOK_PORT ?? 8081) });
if (github) {
  startGitHubSync({ pool, github, log: app.log });
  app.log.info('GitHub sync on');
} else {
  app.log.warn(`GitHub sync off: missing ${missing.join(', ')} (see docs/setup/github-app.md)`);
}
