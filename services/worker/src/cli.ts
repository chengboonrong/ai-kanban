// AI Kanban local worker: reads checkouts on this machine and turns task briefs into specs with OpenCode, or with
// Claude Code in a terminal of the local Orca app.
//
//   node src/cli.ts register --login <name> [--name "My Mac"] [--api http://localhost:8080]
//   node src/cli.ts allow <owner/name> <path-to-checkout>     # the repositories this worker may read
//   node src/cli.ts start [--harness opencode|orca] [--model <claude model, for orca>]
import { chmod, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { parseArgs } from 'node:util';
import type { OpencodeClient } from '@opencode-ai/sdk/v2';
import { type Job, refine, type RunEvent, startOpencode } from './adapters/opencode.ts';
import { checkOrca, refineWithOrca } from './adapters/orca.ts';
import { checkCheckout, escapingSymlinks, exportCommit, scrub, snapshot, verifyEvidence } from './repository.ts';

const CONFIG = process.env.AI_KANBAN_WORKER_CONFIG ?? path.join(os.homedir(), '.config', 'ai-kanban', 'worker.json');
const DEFAULT_MODELS = ['opencode/deepseek-v4.1-flash-free']; // tried in order; OpenCode withdrew glm-5.3-flash-free
const RUN_TIMEOUT_MS = 15 * 60_000;

type Config = { apiUrl: string; token: string; name: string; repositories: Record<string, string>; models: string[] };
type Harness = { kind: 'opencode'; client: OpencodeClient } | { kind: 'orca'; model?: string };

const load = async (): Promise<Config> => JSON.parse(await readFile(CONFIG, 'utf8'));
async function save(config: Config) {
  await mkdir(path.dirname(CONFIG), { recursive: true });
  await writeFile(CONFIG, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 }); // holds the worker token
  await chmod(CONFIG, 0o600);
}

async function call(config: Pick<Config, 'apiUrl' | 'token'>, method: string, url: string, body?: object) {
  const res = await fetch(config.apiUrl + url, {
    method,
    headers: { authorization: `Bearer ${config.token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : undefined };
}

async function register(args: string[]) {
  const { values } = parseArgs({ args, options: { login: { type: 'string' }, name: { type: 'string' }, api: { type: 'string' } } });
  if (!values.login) throw new Error('--login is required (dev sign-in until GitHub sign-in exists)');
  const apiUrl = values.api ?? 'http://localhost:8080';
  const login = await fetch(`${apiUrl}/auth/dev-login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ login: values.login }),
  });
  if (!login.ok) throw new Error(`dev sign-in failed (${login.status}); is the API running with AUTH_MODE=dev?`);
  const session = { apiUrl, token: (await login.json()).token as string };
  const name = values.name ?? os.hostname();
  const res = await call(session, 'POST', '/workers', { name });
  await call(session, 'POST', '/auth/logout'); // the worker keeps only its own token
  if (res.status !== 201) throw new Error(`registration failed: ${JSON.stringify(res.body)}`);
  const previous = await load().catch(() => undefined);
  await save({ apiUrl, token: res.body.token, name, repositories: previous?.repositories ?? {}, models: previous?.models ?? DEFAULT_MODELS });
  console.log(`Registered worker "${name}" for ${values.login}. Config: ${CONFIG}`);
}

async function allow([repository, dir]: string[]) {
  if (!/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(repository ?? '') || !dir) throw new Error('usage: allow <owner/name> <path-to-checkout>');
  const config = await load();
  config.repositories[repository] = await checkCheckout(path.resolve(dir), repository);
  await save(config);
  console.log('This worker may read:');
  for (const [repo, folder] of Object.entries(config.repositories)) console.log(`  ${repo}  ${folder}`);
}

async function start(args: string[]) {
  const { values } = parseArgs({ args, options: { harness: { type: 'string', default: 'opencode' }, model: { type: 'string' } } });
  if (values.harness !== 'opencode' && values.harness !== 'orca') throw new Error('--harness must be opencode or orca');
  if (values.model && values.harness !== 'orca') throw new Error('--model is for --harness orca; OpenCode models come from the config file');
  const config = await load();
  const repositories = Object.keys(config.repositories).map((r) => r.toLowerCase()); // GitHub names are case-insensitive
  if (!repositories.length) throw new Error('no repositories allowed yet; run: allow <owner/name> <path>');
  let harness: Harness;
  let server: { close(): void } | undefined;
  if (values.harness === 'orca') {
    await checkOrca();
    harness = { kind: 'orca', model: values.model };
  } else {
    const opencode = await startOpencode(path.join(path.dirname(CONFIG), 'opencode-config'));
    harness = { kind: 'opencode', client: opencode.client };
    server = opencode.server;
  }
  const using = harness.kind === 'orca' ? `Claude Code via Orca, model: ${harness.model ?? 'default'}` : `models: ${config.models.join(', ')}`;
  console.log(`Worker "${config.name}" polling ${config.apiUrl} for ${repositories.join(', ')} (${using})`);

  let stopping = false;
  let current: AbortController | undefined;
  const stop = () => {
    stopping = true;
    current?.abort(new Error('worker stopped'));
  };
  process.once('SIGINT', stop).once('SIGTERM', stop);

  // ponytail: polls every 3s with no lease; a worker that dies mid-run leaves it "running" until someone cancels it.
  // Leases and heartbeats come with Milestone 5.
  while (!stopping) {
    const claim = await call(config, 'POST', '/worker/claim', { repositories }).catch((e: Error) => ({ status: 0, body: e.message }));
    if (claim.status === 200) {
      current = new AbortController();
      if (stopping) current.abort(new Error('worker stopped')); // Ctrl+C arrived while claiming: hand the run back as failed
      await runJob(config, harness, claim.body, current);
      current = undefined;
    } else {
      if (claim.status !== 204) console.error(`claim failed (${claim.status}): ${JSON.stringify(claim.body)}`);
      if (claim.status === 401) break;
      await sleep(claim.status === 204 ? 3000 : 10_000);
    }
  }
  server?.close();
}

async function runJob(config: Config, harness: Harness, job: Job, ac: AbortController) {
  const dir = Object.entries(config.repositories).find(([repo]) => repo.toLowerCase() === job.repository)?.[1] ?? '';
  let work: string | undefined; // the export the agent reads
  // Nothing that leaves the worker (events, errors, the spec) carries this machine's paths.
  const clean = async (text: string) => scrub(dir || '/nonexistent', work ? await scrub(work, text) : text);
  const pending: RunEvent[] = [];
  // One upload at a time, so events reach the API in order. An empty batch is a heartbeat that still learns about
  // a cancel (409) or a revoked worker (401) while the model is thinking. A failed batch is retried with the next one.
  let uploads = Promise.resolve();
  let uploading = false;
  const flush = () =>
    (uploads = uploads
      .catch(() => {})
      .then(async () => {
        uploading = true;
        try {
          do {
            const batch = pending.splice(0, 100);
            const events = JSON.parse(await clean(JSON.stringify(batch)));
            const res = await call(config, 'POST', `/worker/runs/${job.id}/events`, { events }).catch((e) => {
              pending.unshift(...batch);
              throw e;
            });
            if (res.status >= 500) {
              pending.unshift(...batch);
              throw new Error(`the API answered ${res.status}`);
            }
            if (res.status === 409) ac.abort(new Error('cancelled'));
            if (res.status === 401) ac.abort(new Error('this worker was removed'));
            if (res.status !== 204) return;
          } while (pending.length);
        } finally {
          uploading = false;
        }
      }));
  let ticks = 0;
  const ticker = setInterval(() => {
    if (!uploading && (pending.length || ++ticks % 5 === 0)) flush().catch((e) => console.error('event upload failed:', e.message));
  }, 1000);
  const deadline = setTimeout(() => ac.abort(new Error(`timed out after ${RUN_TIMEOUT_MS / 60_000} minutes`)), RUN_TIMEOUT_MS);
  let commitSha: string | undefined;
  try {
    if (!job.task) throw new Error('the task was deleted');
    console.log(`Refining "${job.task.title}" (${job.repository})`);
    if (!dir) throw new Error(`${job.repository} is not allowed on this worker`);
    const snap = await snapshot(dir);
    commitSha = snap.commitSha;
    work = await exportCommit(dir, commitSha);
    const links = await escapingSymlinks(work);
    if (links.length) throw new Error(`refusing to read a commit whose symlinks point outside it: ${links.slice(0, 5).join(', ')}`);
    pending.push({ kind: 'inspecting', data: snap });
    const onEvent = (e: RunEvent) => pending.push(e);
    const result =
      harness.kind === 'orca'
        ? await refineWithOrca({ checkout: dir, dir: work, job, commitSha, model: harness.model, signal: ac.signal, onEvent })
        : await refine({ client: harness.client, dir: work, job, commitSha, models: config.models, signal: ac.signal, onEvent });
    result.spec.evidence = await verifyEvidence(work, result.spec.evidence);
    const spec = JSON.parse(await clean(JSON.stringify(result.spec))); // models copy absolute paths into prose
    clearInterval(ticker);
    await flush().catch(() => {}); // progress lines are nice to have; the spec isn't
    const res = await call(config, 'POST', `/worker/runs/${job.id}/complete`, { ...result, spec, commitSha, harness: harness.kind });
    if (res.status === 200) return console.log(`Spec v${res.body.version} ready for "${job.task.title}"`);
    if (res.status === 409) return console.log('Run was cancelled; result discarded');
    throw new Error(`the API rejected the spec (${res.status}): ${JSON.stringify(res.body).slice(0, 1000)}`);
  } catch (e) {
    const error = await clean(ac.signal.aborted ? (ac.signal.reason as Error).message : (e as Error).message);
    clearInterval(ticker);
    await flush().catch(() => {});
    const res = await call(config, 'POST', `/worker/runs/${job.id}/fail`, { error: error.slice(0, 2000), harness: harness.kind, ...(commitSha ? { commitSha } : {}) }).catch(() => undefined);
    console.error(`Refinement failed: ${error}${res?.status === 409 ? ' (run already cancelled)' : ''}`);
  } finally {
    clearInterval(ticker);
    clearTimeout(deadline);
    if (work) await rm(work, { recursive: true, force: true });
  }
}

const [command, ...rest] = process.argv.slice(2);
const commands: Record<string, (args: string[]) => Promise<void>> = { register, allow, start };
if (!commands[command]) {
  console.error('usage: cli.ts register --login <name> | allow <owner/name> <path> | start [--harness opencode|orca] [--model <id>]');
  process.exit(2);
}
await commands[command](rest).catch((e: Error) => {
  console.error(e.message);
  process.exit(1);
});
