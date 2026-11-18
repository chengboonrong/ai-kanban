// AI Kanban local worker: reads checkouts on this machine and turns task briefs into specs with OpenCode or Claude Code.
//
//   node src/cli.ts connect <code> [--api http://localhost:8080] [--name "My Mac"]   # the code from the app's Workers page
//   node src/cli.ts checkouts                                  # pick the repositories this worker may read from Orca's list
//   node src/cli.ts allow <owner/name> <path-to-checkout>      # or name one by hand
//   node src/cli.ts start                                      # or: service install | uninstall | status (macOS)
import { spawn } from 'node:child_process';
import { chmod, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import { parseArgs } from 'node:util';
import { refineWithClaude } from './adapters/claude.ts';
import { type Job, refine, type RunEvent, startOpencode } from './adapters/opencode.ts';
import { checkCheckout, escapingSymlinks, exportCommit, orcaCheckouts, scrub, snapshot, verifyEvidence } from './repository.ts';
import { protectedFolder, service } from './service.ts';

const CONFIG = process.env.AI_KANBAN_WORKER_CONFIG ?? path.join(os.homedir(), '.config', 'ai-kanban', 'worker.json');
const DEFAULT_MODELS = ['opencode/deepseek-v4.1-flash-free']; // tried in order; OpenCode withdrew glm-5.3-flash-free
const RUN_TIMEOUT_MS = 15 * 60_000;

type Config = {
  apiUrl: string;
  token: string;
  name: string;
  repositories: Record<string, string>;
  models: string[];
  refiner?: 'opencode' | 'claude';
  claudeModel?: string;
};

const load = async (): Promise<Config> => JSON.parse(await readFile(CONFIG, 'utf8'));
async function save(config: Config) {
  await mkdir(path.dirname(CONFIG), { recursive: true });
  await writeFile(CONFIG, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 }); // holds the worker token
  await chmod(CONFIG, 0o600);
}

async function call(config: Pick<Config, 'apiUrl' | 'token'>, method: string, url: string, body?: object, timeout = 30_000) {
  const res = await fetch(config.apiUrl + url, {
    method,
    headers: { authorization: `Bearer ${config.token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeout),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : undefined };
}

async function connect(args: string[]) {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, options: { api: { type: 'string' }, name: { type: 'string' } } });
  if (positionals.length !== 1) throw new Error('usage: connect <code> [--api URL] [--name NAME]');
  const previous = await load().catch(() => undefined);
  const apiUrl = values.api ?? previous?.apiUrl ?? 'http://localhost:8080';
  const res = await fetch(`${apiUrl}/workers/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ code: positionals[0], name: (values.name ?? os.hostname()).slice(0, 100) }),
    signal: AbortSignal.timeout(30_000),
  });
  const body = await res.json().catch(() => undefined);
  if (res.status !== 201) throw new Error(`pairing failed (${res.status}): ${body?.message ?? JSON.stringify(body)}`);
  // Checkouts carry over only to the same API: a phished `--api` must not inherit what this machine may read.
  const same = previous?.apiUrl === apiUrl;
  await save({
    ...previous,
    apiUrl,
    token: body.token,
    name: body.name,
    repositories: same ? previous.repositories : {},
    models: previous?.models ?? DEFAULT_MODELS,
    refiner: previous?.refiner ?? 'opencode',
  });
  console.log(`Connected worker "${body.name}" to ${apiUrl}. Config: ${CONFIG}`);
  if (!same || !Object.keys(previous.repositories).length) console.log('Next: checkouts (or allow <owner/name> <path>), then start');
}

const listAllowed = (config: Config) => {
  console.log('This worker may read:');
  for (const [repo, folder] of Object.entries(config.repositories)) console.log(`  ${repo}  ${folder}`);
};

async function allow([repository, dir]: string[]) {
  if (!/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(repository ?? '') || !dir) throw new Error('usage: allow <owner/name> <path-to-checkout>');
  const config = await load();
  config.repositories[repository] = await checkCheckout(path.resolve(dir), repository);
  await save(config);
  listAllowed(config);
}

async function checkouts() {
  if (!process.stdin.isTTY) throw new Error('checkouts asks before allowing each repository; run it in a terminal');
  const config = await load();
  const found = await orcaCheckouts();
  if (!found.length) console.log('Orca lists no GitHub checkouts');
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    for (const { repository, path: dir } of found) {
      if (Object.keys(config.repositories).some((r) => r.toLowerCase() === repository.toLowerCase())) continue;
      if (!/^y(es)?$/i.test((await rl.question(`Allow ${repository} at ${dir}? [y/N] `)).trim())) continue;
      try {
        config.repositories[repository] = await checkCheckout(dir, repository);
        await save(config);
      } catch (e) {
        console.error(`  not allowed: ${(e as Error).message}`);
      }
    }
  } finally {
    rl.close();
  }
  listAllowed(config);
}

const STOPPED = new Error('worker stopped');
let opencode: ReturnType<typeof startOpencode> | undefined; // started on the first OpenCode job, then kept
const opencodeClient = async () => {
  opencode ??= startOpencode(path.join(path.dirname(CONFIG), 'opencode-config'));
  return (await opencode.catch((e) => ((opencode = undefined), Promise.reject(e)))).client;
};

// Never exits on its own: a missing config, no repositories or a rejected token are waited out (the file is re-read
// every turn), so `allow`, `checkouts` and `connect` take effect without a restart and launchd never crash-loops.
async function start() {
  let config: Config | undefined;
  let current: { id: string; ac: AbortController; done: Promise<void> } | undefined;
  const stop = async () => {
    if (current) {
      current.ac.abort(STOPPED);
      // Hand the run back so it's retried now, not when its lease runs out; no final event flush.
      await Promise.allSettled([
        call(config!, 'POST', `/worker/runs/${current.id}/release`, undefined, 5000),
        Promise.race([current.done, sleep(5000)]), // the agent stopping and the export being deleted
      ]);
    }
    await opencode?.then((o) => o.server.close(), () => {}); // its own process; don't leave it behind
    process.exit(0);
  };
  process.once('SIGINT', stop).once('SIGTERM', stop);

  let said = '';
  const say = (message: string) => message !== said && console.log((said = message));
  let checked = ''; // the token GET /worker/me accepted
  let rejected = '';
  for (;;) {
    config = await load().catch(() => undefined);
    const repositories = Object.keys(config?.repositories ?? {}).map((r) => r.toLowerCase()); // GitHub names are case-insensitive
    if (!config) say(`No config at ${CONFIG}; run: connect <code>`);
    else if (config.token === rejected) say('The API rejected this worker (removed?); run: connect <code>');
    else if (!repositories.length) say('No repositories allowed yet; run: checkouts, or allow <owner/name> <path>');
    if (!config || config.token === rejected || !repositories.length) {
      await sleep(10_000);
      continue;
    }
    if (config.token !== checked) {
      const me = await call(config, 'GET', '/worker/me').catch((e: Error) => ({ status: 0, body: e.message }));
      if (me.status === 401) rejected = config.token;
      else if (me.status === 200) checked = config.token;
      else {
        console.error(`could not reach the API (${me.status}): ${JSON.stringify(me.body)}`);
        await sleep(10_000);
      }
      continue;
    }
    const refiner = config.refiner === 'claude' ? `Claude Code${config.claudeModel ? ` (${config.claudeModel})` : ''}` : `OpenCode (${config.models.join(', ')})`;
    say(`Worker "${config.name}" polling ${config.apiUrl} for ${repositories.join(', ')} with ${refiner}`);

    const claim = await call(config, 'POST', '/worker/claim', { repositories }).catch((e: Error) => ({ status: 0, body: e.message }));
    if (claim.status === 200) {
      const ac = new AbortController();
      current = { id: claim.body.id, ac, done: runJob(config, claim.body, ac) };
      await current.done;
      current = undefined;
    } else {
      if (claim.status === 401) rejected = config.token;
      else if (claim.status === 204) await sleep(3000);
      else {
        console.error(`claim failed (${claim.status}): ${JSON.stringify(claim.body)}`);
        await sleep(10_000);
      }
    }
  }
}

async function runJob(config: Config, job: Job, ac: AbortController) {
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
  // Idle sleep would stop the agent and lose the run's lease; caffeinate exits by itself if the worker dies.
  const awake = process.platform === 'darwin' ? spawn('caffeinate', ['-i', '-w', String(process.pid)], { stdio: 'ignore' }) : undefined;
  awake?.on('error', () => {});
  const harness = config.refiner === 'claude' ? 'claude-code' : 'opencode';
  let commitSha: string | undefined;
  try {
    if (!job.task) throw new Error('the task was deleted');
    console.log(`Refining "${job.task.title}" (${job.repository})`);
    if (!dir) throw new Error(`${job.repository} is not allowed on this worker`);
    const snap = await snapshot(dir).catch((e: Error) => {
      const folder = protectedFolder(dir);
      if (!folder || !/Operation not permitted|EPERM/.test(e.message)) throw e;
      throw new Error(
        `macOS won't let ${process.execPath} read ${path.join('~', path.relative(os.homedir(), dir))} (in ~/${folder}). Give it Full Disk ` +
          `Access in System Settings > Privacy & Security (again after each node upgrade), or move the checkout out of ~/${folder}`,
        { cause: e },
      );
    });
    commitSha = snap.commitSha;
    work = await exportCommit(dir, commitSha);
    const links = await escapingSymlinks(work);
    if (links.length) throw new Error(`refusing to read a commit whose symlinks point outside it: ${links.slice(0, 5).join(', ')}`);
    pending.push({ kind: 'inspecting', data: snap });
    const onEvent = (e: RunEvent) => pending.push(e);
    const result =
      harness === 'claude-code'
        ? await refineWithClaude({ dir: work, job, commitSha, model: config.claudeModel, signal: ac.signal, onEvent })
        : await refine({ client: await opencodeClient(), dir: work, job, commitSha, models: config.models, signal: ac.signal, onEvent });
    result.spec.evidence = await verifyEvidence(work, result.spec.evidence);
    const spec = JSON.parse(await clean(JSON.stringify(result.spec))); // models copy absolute paths into prose
    clearInterval(ticker);
    await flush().catch(() => {}); // progress lines are nice to have; the spec isn't
    const res = await call(config, 'POST', `/worker/runs/${job.id}/complete`, { ...result, spec, commitSha, harness });
    if (res.status === 200) return console.log(`Spec v${res.body.version} ready for "${job.task.title}"`);
    if (res.status === 409) return console.log('Run was cancelled; result discarded');
    throw new Error(`the API rejected the spec (${res.status}): ${JSON.stringify(res.body).slice(0, 1000)}`);
  } catch (e) {
    if (ac.signal.reason === STOPPED) return; // the worker is stopping: it releases the run instead
    const error = await clean(ac.signal.aborted ? (ac.signal.reason as Error).message : (e as Error).message);
    clearInterval(ticker);
    await flush().catch(() => {});
    const res = await call(config, 'POST', `/worker/runs/${job.id}/fail`, { error: error.slice(0, 2000), ...(commitSha ? { commitSha } : {}) }).catch(() => undefined);
    console.error(`Refinement failed: ${error}${res?.status === 409 ? ' (run already cancelled)' : ''}`);
  } finally {
    clearInterval(ticker);
    clearTimeout(deadline);
    awake?.kill();
    if (work) await rm(work, { recursive: true, force: true });
  }
}

const [command, ...rest] = process.argv.slice(2);
const commands: Record<string, (args: string[]) => Promise<void>> = {
  connect,
  checkouts,
  allow,
  start,
  service: (args) => service(args, CONFIG),
};
if (!commands[command]) {
  console.error('usage: cli.ts connect <code> [--api URL] [--name NAME] | checkouts | allow <owner/name> <path> | start | service install|uninstall|status');
  process.exit(2);
}
await commands[command](rest).catch((e: Error) => {
  console.error(e.message);
  process.exit(1);
});
