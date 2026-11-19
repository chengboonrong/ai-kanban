import { allowedGithubIdsFromEnv, assertAllowlistMode, buildApp } from './app.ts';
import { createPool } from './db.ts';
import { githubConfigFromEnv, gitHubClient } from './github.ts';
import { mailerFromEnv } from './mail.ts';
import { migrate } from './migrate.ts';
import { startRunSweeper } from './refinement.ts';
import { buildWebhookApp, startGitHubSync } from './sync.ts';

const pool = createPool();
await migrate(pool);
const host = process.env.HOST ?? '127.0.0.1';
const { config: github, missing } = githubConfigFromEnv();
const gh = github && gitHubClient(github, pool);
const authMode = process.env.AUTH_MODE ?? 'none';
// Only github mode checks the list; resolving it needs the App, and a bad entry stops the boot rather than opening sign-in.
assertAllowlistMode(authMode);
const allowedGithubIds = authMode === 'github' && gh ? await allowedGithubIdsFromEnv(gh) : [];
const app = await buildApp({ pool, authMode, logger: true, github: gh, mailer: mailerFromEnv(), allowedGithubIds });
await app.listen({ host, port: Number(process.env.PORT ?? 8080) });

// Webhooks get their own port so a tunnel to it exposes nothing else (docs/setup/github-app.md).
const webhooks = await buildWebhookApp({ pool, github, logger: true });
await webhooks.listen({ host, port: Number(process.env.GITHUB_WEBHOOK_PORT ?? 8081) });
startRunSweeper({ pool, log: app.log });
if (gh) {
  startGitHubSync({ pool, gh, log: app.log });
  app.log.info('GitHub sync on');
} else {
  app.log.warn(`GitHub sync off: missing ${missing.join(', ')} (see docs/setup/github-app.md)`);
}
