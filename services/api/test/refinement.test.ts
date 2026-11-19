import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.ts';
import { createPool, sha256 } from '../src/db.ts';
import { migrate } from '../src/migrate.ts';
import { sweepRuns } from '../src/refinement.ts';
import { pairWorker } from './helpers.ts';

const pool = createPool(process.env.TEST_DATABASE_URL ?? 'postgres://kanban:kanban@localhost:55432/kanban_test');
let app: FastifyInstance;

before(async () => {
  await migrate(pool);
  app = await buildApp({ pool, authMode: 'dev' });
});
after(async () => {
  await app.close();
  await pool.end();
});

type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';
const as = (token: string) => (method: Method, url: string, payload?: object) =>
  app.inject({ method, url, payload, headers: { authorization: `Bearer ${token}` } });

async function user() {
  const res = await app.inject({ method: 'POST', url: '/auth/dev-login', payload: { login: `u-${randomUUID().slice(0, 8)}` } });
  return as(res.json().token);
}

// A unique repository per test, so workers in parallel tests never claim each other's runs.
async function fixture() {
  const api = await user();
  const repository = `acme/repo-${randomUUID().slice(0, 8)}`;
  const ws = (await api('POST', '/workspaces', { name: 'Acme' })).json();
  const board = (await api('POST', `/workspaces/${ws.id}/boards`, { name: 'Roadmap' })).json();
  assert.equal((await api('PATCH', `/boards/${board.id}`, { repository })).json().repository, repository);
  const worker = await registerWorker(api);
  return { api, board, repository, worker };
}

const registerWorker = async (api: ReturnType<typeof as>) => as((await pairWorker(api)).token);

const spec = (title = 'Add GitHub login to settings') => ({
  title,
  summary: 'Let people connect GitHub from the settings page.',
  requirements: ['A Connect GitHub button on settings'],
  acceptanceCriteria: ['Clicking it starts the device flow'],
  evidence: [{ path: 'lib/settings.dart', startLine: 1, endLine: 20, note: 'Settings page lives here', verified: true }],
  ambiguities: ['Should signing out also disconnect GitHub?'],
  approach: ['Add a button that calls the auth service'],
  readiness: 70,
});
const done = (s = spec()) => ({ model: 'opencode/deepseek-v4.1-flash-free', sessionId: 'ses_1', commitSha: 'a'.repeat(40), spec: s });

const refinementOf = async (api: ReturnType<typeof as>, boardId: string, taskId: string) =>
  (await api('GET', `/boards/${boardId}`)).json().columns.flatMap((c: { tasks: object[] }) => c.tasks).find((t: { id: string }) => t.id === taskId)
    .refinement;

test('worker tokens and user sessions are not interchangeable, and deleting a worker revokes it', async () => {
  const api = await user();
  const { id, token } = await pairWorker(api);
  assert.match(token, /^wkr_/);
  assert.equal((await api('POST', '/worker/claim', { repositories: [] })).statusCode, 401);
  assert.equal((await as(token)('GET', '/workspaces')).statusCode, 401);
  assert.equal((await as(token)('POST', '/worker/claim', { repositories: [] })).statusCode, 204);
  assert.equal((await api('GET', '/workers')).json()[0].token, undefined);
  assert.equal((await (await user())('DELETE', `/workers/${id}`)).statusCode, 404);
  assert.equal((await api('DELETE', `/workers/${id}`)).statusCode, 204);
  assert.equal((await as(token)('POST', '/worker/claim', { repositories: [] })).statusCode, 401);
});

test('a new card on a board with a repository queues exactly one refinement', async () => {
  const { api, board } = await fixture();
  assert.equal((await api('PATCH', `/boards/${board.id}`, { repository: 'not a repo' })).statusCode, 400);
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login to settings' })).json();
  assert.equal(await refinementOf(api, board.id, task.id), 'queued');
  const again = await api('POST', `/tasks/${task.id}/runs`);
  assert.equal(again.statusCode, 200, 'an active run is returned, not duplicated');
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM agent_runs WHERE task_id = $1', [task.id])).rows[0].n, 1);

  // No repository: no auto-start, and asking for one explains why.
  assert.equal((await api('PATCH', `/boards/${board.id}`, { repository: null })).json().repository, null);
  const plain = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Untracked' })).json();
  assert.equal(await refinementOf(api, board.id, plain.id), null);
  assert.equal((await api('POST', `/tasks/${plain.id}/runs`)).statusCode, 409);
});

test('workers only claim runs for repositories they have and boards their owner can see', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();

  assert.equal((await worker('POST', '/worker/claim', { repositories: ['acme/other'] })).statusCode, 204);
  const strangersWorker = await registerWorker(await user());
  assert.equal((await strangersWorker('POST', '/worker/claim', { repositories: [repository] })).statusCode, 204);

  const second = await registerWorker(api);
  const claims = await Promise.all([worker, second].map((w) => w('POST', '/worker/claim', { repositories: [repository] })));
  assert.deepEqual(claims.map((r) => r.statusCode).sort(), [200, 204], 'two workers never get the same run');
  const claimed = claims.find((r) => r.statusCode === 200)!.json();
  assert.equal(claimed.repository, repository);
  assert.equal(claimed.task.title, 'Add GitHub login');
  assert.equal((await api('GET', `/tasks/${task.id}/refinement`)).json().run.state, 'running');
});

test('a run streams events, stores a validated spec version, and the latest version can be approved', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();

  const events = [{ kind: 'tool', data: { tool: 'read', title: 'lib/settings.dart' } }, { kind: 'tool', data: { tool: 'grep', title: 'login' } }];
  assert.equal((await worker('POST', `/worker/runs/${run.id}/events`, { events })).statusCode, 204);
  const polled = (await api('GET', `/runs/${run.id}/events?after=0`)).json();
  assert.equal(polled.state, 'running');
  assert.deepEqual(polled.events.map((e: { data: object }) => e.data), events.map((e) => e.data));

  // The API re-checks the model's output against the contract.
  const bad = await worker('POST', `/worker/runs/${run.id}/complete`, done({ ...spec(), readiness: 'high' } as never));
  assert.equal(bad.statusCode, 400);

  const v1 = (await worker('POST', `/worker/runs/${run.id}/complete`, done())).json();
  assert.equal(v1.version, 1);
  const again = await worker('POST', `/worker/runs/${run.id}/complete`, done());
  assert.deepEqual([again.statusCode, again.json().id, again.json().version], [200, v1.id, 1], 'a repeated completion adds nothing');
  assert.equal(await refinementOf(api, board.id, task.id), 'ready');
  const lastId = polled.events.at(-1).id;
  const final = (await api('GET', `/runs/${run.id}/events?after=${lastId}`)).json();
  assert.deepEqual(final, { state: 'succeeded', events: [] }, 'a finished run answers at once instead of waiting');

  // Refine again: a second version supersedes the first.
  assert.equal((await api('POST', `/tasks/${task.id}/runs`)).statusCode, 201);
  const run2 = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  const v2 = (await worker('POST', `/worker/runs/${run2.id}/complete`, done(spec('Add GitHub sign-in')))).json();
  assert.equal(v2.version, 2);
  assert.equal((await api('POST', `/specs/${v1.id}/approve`)).statusCode, 409);
  const approved = await api('POST', `/specs/${v2.id}/approve`);
  assert.equal(approved.statusCode, 200);
  assert.ok(approved.json().approvedAt);
  assert.equal(await refinementOf(api, board.id, task.id), 'approved');

  const refinement = (await api('GET', `/tasks/${task.id}/refinement`)).json();
  assert.equal(refinement.spec.content.title, 'Add GitHub sign-in');
  assert.equal(refinement.run.commitSha, 'a'.repeat(40));
  const kinds = (await api('GET', `/tasks/${task.id}`)).json().activity.map((a: { kind: string }) => a.kind);
  assert.deepEqual(kinds, ['created', 'refinement_requested', 'spec_ready', 'refinement_requested', 'spec_ready', 'spec_approved']);
});

test('cancelling stops the worker and failures are recorded', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  assert.equal((await api('POST', `/runs/${run.id}/cancel`)).json().state, 'cancelled');
  assert.equal((await worker('POST', `/worker/runs/${run.id}/events`, { events: [{ kind: 'tool' }] })).statusCode, 409);
  assert.equal((await worker('POST', `/worker/runs/${run.id}/complete`, done())).statusCode, 409);
  assert.equal((await api('POST', `/runs/${run.id}/cancel`)).statusCode, 409);
  assert.equal(await refinementOf(api, board.id, task.id), null);

  await api('POST', `/tasks/${task.id}/runs`);
  const run2 = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  assert.equal((await worker('POST', `/worker/runs/${run2.id}/fail`, { error: 'model withdrawn' })).statusCode, 204);
  assert.equal(await refinementOf(api, board.id, task.id), 'failed');
  assert.equal((await api('GET', `/tasks/${task.id}/refinement`)).json().run.error, 'model withdrawn');
});

test('people outside the workspace see none of it', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  const v1 = (await worker('POST', `/worker/runs/${run.id}/complete`, done())).json();
  const stranger = await user();
  assert.equal((await stranger('GET', `/tasks/${task.id}/refinement`)).statusCode, 404);
  assert.equal((await stranger('GET', `/runs/${run.id}/events`)).statusCode, 404);
  assert.equal((await stranger('POST', `/runs/${run.id}/cancel`)).statusCode, 404);
  assert.equal((await stranger('POST', `/specs/${v1.id}/approve`)).statusCode, 404);
  assert.equal((await stranger('POST', `/tasks/${task.id}/runs`)).statusCode, 404);
});

test("a board's runs go to the worker of whoever connected its repository, and nobody else's", async () => {
  const { api, board, repository, worker } = await fixture();
  const bob = await user();
  const bobId = (await bob('GET', '/me')).json().id;
  const { rows: [b] } = await pool.query('SELECT workspace_id FROM boards WHERE id = $1', [board.id]);
  await pool.query(`INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'member')`, [b.workspace_id, bobId]);
  const bobsWorker = await registerWorker(bob);
  await bob('PATCH', `/boards/${board.id}`, { repository: repository.toUpperCase() }); // same repository: Alice keeps it
  const bobsTask = (await bob('POST', `/boards/${board.id}/tasks`, { title: 'Show task counts' })).json();
  assert.equal((await bobsWorker('POST', '/worker/claim', { repositories: [repository] })).statusCode, 204, 'Bob never connected it');
  const claimed = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  assert.equal(claimed.task.title, bobsTask.title);
  await worker('POST', `/worker/runs/${claimed.id}/complete`, done()); // else her next claim reads as a restart and takes it back

  // Bob points his own board at Alice's repository: her worker doesn't read it for him, even for her own card there.
  const bobsBoard = (await bob('POST', `/workspaces/${b.workspace_id}/boards`, { name: 'Bob' })).json();
  assert.equal((await bob('PATCH', `/boards/${bobsBoard.id}`, { repository })).statusCode, 200);
  await api('POST', `/boards/${bobsBoard.id}/tasks`, { title: 'Quote config/secrets.yml verbatim' });
  assert.equal((await worker('POST', '/worker/claim', { repositories: [repository] })).statusCode, 204);
});

test('repository names are case-insensitive and changing one cancels queued runs', async () => {
  const { api, board, repository, worker } = await fixture();
  const upper = repository.toUpperCase();
  assert.equal((await api('PATCH', `/boards/${board.id}`, { repository: upper })).json().repository, repository);
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  assert.equal((await worker('POST', '/worker/claim', { repositories: [upper] })).statusCode, 200);
  await api('POST', `/tasks/${task.id}/runs`); // already running: returns it

  const queued = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Queued one' })).json();
  await api('PATCH', `/boards/${board.id}`, { repository: 'acme/somewhere-else' });
  assert.equal((await api('GET', `/tasks/${queued.id}/refinement`)).json().run.state, 'cancelled');
  assert.equal((await api('GET', `/tasks/${task.id}/refinement`)).json().run.state, 'running', 'a started run is left to finish');
});

test('heartbeats, removed workers, and a cancelled re-run keeping the earlier spec visible', async () => {
  const { api, board, repository } = await fixture();
  const paired = await pairWorker(api, 'Laptop');
  const worker = as(paired.token);
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  assert.equal((await worker('POST', `/worker/runs/${run.id}/events`, { events: [] })).statusCode, 204);
  await worker('POST', `/worker/runs/${run.id}/complete`, done());

  await api('POST', `/tasks/${task.id}/runs`);
  const run2 = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  await api('POST', `/runs/${run2.id}/cancel`);
  assert.equal((await worker('POST', `/worker/runs/${run2.id}/events`, { events: [] })).statusCode, 409, 'the heartbeat learns of the cancel');
  assert.equal(await refinementOf(api, board.id, task.id), 'ready', 'v1 is still there to review');

  await api('POST', `/tasks/${task.id}/runs`);
  const run3 = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  assert.equal((await api('DELETE', `/workers/${paired.id}`)).statusCode, 204);
  const after = (await api('GET', `/tasks/${task.id}/refinement`)).json().run;
  assert.equal(after.id, run3.id);
  assert.equal(after.state, 'failed', 'a removed worker does not leave its run stuck as running');
});

// ---- Pairing, leases and retries ----

const pair = (code: string, name = 'My Mac') => app.inject({ method: 'POST', url: '/workers/pair', payload: { code, name } });
const runRow = async (id: string) => (await pool.query('SELECT state, error, attempt FROM agent_runs WHERE id = $1', [id])).rows[0];
const latestRun = async (api: ReturnType<typeof as>, taskId: string) => (await api('GET', `/tasks/${taskId}/refinement`)).json().run;
const lapse = (runId: string) => pool.query(`UPDATE agent_runs SET lease_until = now() - interval '1 second' WHERE id = $1`, [runId]);
// The test database keeps runs other test runs left running, and one pass looks at 20, so sweep until nothing is due.
const sweepAll = async () => {
  while (await sweepRuns(pool, app.log));
};
const claim = (worker: ReturnType<typeof as>, repository: string) => worker('POST', '/worker/claim', { repositories: [repository] });

/** Starts `requests` in order while another connection holds `lock`, each once the one before queued, then lets go, so they really overlap. */
async function underLock<T>(lock: string, params: unknown[], requests: (() => Promise<T>)[]) {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query(lock, params);
    const { rows: [{ pid }] } = await c.query('SELECT pg_backend_pid() AS pid');
    const started: Promise<T>[] = [];
    let queued: number[] = [];
    for (const request of requests) {
      started.push(request());
      started.at(-1)!.catch(() => {}); // awaited below; don't report it as unhandled meanwhile
      for (const deadline = Date.now() + 5_000; queued.length < started.length; await sleep(10)) {
        assert.ok(Date.now() < deadline, `only ${queued.length} of ${started.length} requests queued behind the lock`);
        // A later waiter may queue behind an earlier one, not the holder, so follow the chain.
        queued = (await pool.query('SELECT pid FROM pg_stat_activity WHERE pg_blocking_pids(pid) && $1::int[]', [[pid, ...queued]])).rows.map((r) => r.pid);
      }
    }
    await c.query('ROLLBACK');
    return await Promise.all(started);
  } finally {
    await c.query('ROLLBACK').catch(() => {});
    c.release();
  }
}

test('pairing: a code pairs one worker, once, within 10 minutes, typed loosely', async () => {
  const api = await user();
  const res = await api('POST', '/workers/pairing');
  assert.equal(res.statusCode, 201);
  const { code, expiresAt } = res.json();
  assert.match(code, /^[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}$/);
  const ttl = new Date(expiresAt).getTime() - Date.now();
  assert.ok(ttl > 9 * 60_000 && ttl <= 10 * 60_000, `ttl ${ttl}`);

  const paired = await pair(` ${code.toLowerCase().replace('-', ' ')} `);
  assert.equal(paired.statusCode, 201);
  const { id, name, token, ownerId } = paired.json();
  assert.equal(name, 'My Mac');
  assert.match(token, /^wkr_/);
  assert.equal(ownerId, (await api('GET', '/me')).json().id); // `connect` keeps checkouts only for the same account
  assert.deepEqual((await as(token)('GET', '/worker/me')).json(), { id, name: 'My Mac', ownerId });
  assert.deepEqual((await api('GET', '/workers')).json().map((w: { id: string }) => w.id), [id]);

  const reused = await pair(code);
  assert.equal(reused.statusCode, 400);
  assert.equal(reused.json().message, 'invalid or expired code');
  assert.equal((await pair('ZZZZZ-ZZZZZ')).statusCode, 400, 'wrong code');

  const late = (await api('POST', '/workers/pairing')).json().code;
  await pool.query(`UPDATE worker_pairings SET expires_at = now() - interval '1 second' WHERE code_hash = $1`, [sha256(late.replace('-', ''))]);
  assert.equal((await pair(late)).statusCode, 400, 'expired code');

  // People type O for 0 and I or L for 1.
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const exact = `01${Array.from(randomBytes(8), (b) => alphabet[b & 31]).join('')}`;
  const me = (await api('GET', '/me')).json();
  await pool.query(`INSERT INTO worker_pairings (code_hash, owner_id, expires_at) VALUES ($1, $2, now() + interval '1 minute')`, [sha256(exact), me.id]);
  assert.equal((await pair(`oL${exact.slice(2, 5)}-${exact.slice(5)}`.toLowerCase())).statusCode, 201);
  assert.equal((await api('GET', '/workers')).json().length, 2);
});

test('pairing keeps at most 5 open codes per person, dropping the oldest', async () => {
  const api = await user();
  const me = (await api('GET', '/me')).json();
  const codes = [];
  for (let i = 0; i < 6; i++) codes.push((await api('POST', '/workers/pairing')).json().code);
  const open = await pool.query('SELECT 1 FROM worker_pairings WHERE owner_id = $1 AND used_at IS NULL AND expires_at > now()', [me.id]);
  assert.equal(open.rowCount, 5);
  assert.equal((await pair(codes[0])).statusCode, 400);
  assert.equal((await pair(codes[5])).statusCode, 201);
});

test('a lapsed lease fails the run and queues attempt 2; the stale worker is turned away and one spec results', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await claim(worker, repository)).json();
  await sweepAll();
  assert.equal((await runRow(run.id)).state, 'running', 'a fresh lease is not swept');

  await lapse(run.id);
  await sweepAll();
  assert.deepEqual(await runRow(run.id), { state: 'failed', error: 'the worker stopped responding', attempt: 1 });
  const next = await latestRun(api, task.id);
  assert.deepEqual([next.state, next.attempt, next.retryReason], ['queued', 2, 'the worker stopped responding']);
  const retried = (await api('GET', `/tasks/${task.id}`)).json().activity.filter((a: { kind: string }) => a.kind === 'refinement_retried');
  assert.deepEqual(retried.map((a: { data: object }) => a.data), [{ reason: 'the worker stopped responding', attempt: 2 }]);

  assert.equal((await worker('POST', `/worker/runs/${run.id}/events`, { events: [] })).statusCode, 409);
  assert.equal((await worker('POST', `/worker/runs/${run.id}/complete`, done())).statusCode, 409);
  const again = (await claim(worker, repository)).json();
  assert.equal(again.id, next.id);
  assert.equal((await worker('POST', `/worker/runs/${again.id}/complete`, done())).statusCode, 200);
  assert.equal((await pool.query('SELECT 1 FROM specs WHERE task_id = $1', [task.id])).rowCount, 1);
});

test('a heartbeat renews the lease, up to 20 minutes from the start, after which the run times out unretried', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await claim(worker, repository)).json();
  const lease = async () =>
    (await pool.query(`SELECT extract(epoch FROM lease_until - now())::int AS left FROM agent_runs WHERE id = $1`, [run.id])).rows[0].left;
  assert.ok((await lease()) > 80, 'a claim leases 90 s');
  await lapse(run.id);
  assert.equal((await worker('POST', `/worker/runs/${run.id}/events`, { events: [] })).statusCode, 204);
  assert.ok((await lease()) > 80);
  await sweepAll();
  assert.equal((await runRow(run.id)).state, 'running');

  await pool.query(`UPDATE agent_runs SET started_at = now() - interval '21 minutes' WHERE id = $1`, [run.id]);
  assert.equal((await worker('POST', `/worker/runs/${run.id}/events`, { events: [] })).statusCode, 204);
  assert.ok((await lease()) < 0, 'no renewal past the 20-minute cap');
  await sweepAll();
  assert.deepEqual(await runRow(run.id), { state: 'failed', error: 'timed out after 20 minutes', attempt: 1 });
  assert.equal((await latestRun(api, task.id)).id, run.id, 'not retried');
});

test('a run is tried 3 times in all', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  for (let attempt = 1; attempt <= 3; attempt++) {
    const run = (await claim(worker, repository)).json();
    assert.equal((await latestRun(api, task.id)).attempt, attempt);
    await lapse(run.id);
    await sweepAll();
  }
  const last = await latestRun(api, task.id);
  assert.deepEqual([last.state, last.attempt, last.error], ['failed', 3, 'gave up after 3 attempts: the worker stopped responding']);
  assert.equal((await pool.query('SELECT 1 FROM agent_runs WHERE task_id = $1', [task.id])).rowCount, 3);
  const activity = (await api('GET', `/tasks/${task.id}`)).json().activity as { kind: string; data: { error?: string } }[];
  assert.deepEqual(activity.filter((a) => a.kind.startsWith('refinement_')).map((a) => a.kind), [
    'refinement_requested', 'refinement_retried', 'refinement_retried', 'refinement_failed',
  ]);
  assert.equal(activity.at(-1)?.data.error, 'gave up after 3 attempts: the worker stopped responding');
});

test('a released run is retried; only the worker running it can release it', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await claim(worker, repository)).json();
  assert.equal((await worker('POST', `/worker/runs/${run.id}/release`)).statusCode, 204);
  assert.deepEqual(await runRow(run.id), { state: 'failed', error: 'the worker was stopped', attempt: 1 });
  assert.equal((await worker('POST', `/worker/runs/${run.id}/release`)).statusCode, 409);

  const second = await registerWorker(api);
  const next = (await claim(second, repository)).json();
  assert.equal((await latestRun(api, task.id)).retryReason, 'the worker was stopped');
  assert.equal((await worker('POST', `/worker/runs/${next.id}/release`)).statusCode, 409, "another worker's run");
  assert.equal((await runRow(next.id)).state, 'running');
});

test('a release racing a task delete neither deadlocks nor fails', async () => {
  const { api, board, repository, worker } = await fixture();
  // A wrong lock order deadlocks only when the delete gets the board first, so try both orders.
  for (let i = 0; i < 2; i++) {
    const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
    const run = (await claim(worker, repository)).json();
    const requests = [() => worker('POST', `/worker/runs/${run.id}/release`), () => api('DELETE', `/tasks/${task.id}`)];
    const results = await underLock('SELECT 1 FROM boards WHERE id = $1 FOR UPDATE', [board.id], i ? requests : requests.toReversed());
    const [release, remove] = i ? results : results.toReversed();
    assert.ok([204, 409].includes(release.statusCode), `release ${release.statusCode}`); // 409 when the delete went first
    assert.equal(remove.statusCode, 204);
    assert.equal((await pool.query('SELECT 1 FROM agent_runs WHERE task_id = $1', [task.id])).rowCount, 0);
  }
});

for (const target of ['board', 'workspace']) {
  test(`a release racing a ${target} delete neither deadlocks nor fails`, async () => {
    const { api, board, repository, worker } = await fixture();
    const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
    const run = (await claim(worker, repository)).json();
    // The delete queues on the task first, then the release takes the board and queues on the task too. Had the
    // delete not locked the board before its tasks, it would now wait for the release's board lock: a deadlock.
    const [remove, release] = await underLock('SELECT 1 FROM tasks WHERE id = $1 FOR UPDATE', [task.id], [
      () => api('DELETE', target === 'board' ? `/boards/${board.id}` : `/workspaces/${board.workspaceId}`),
      () => worker('POST', `/worker/runs/${run.id}/release`),
    ]);
    assert.equal(remove.statusCode, 204);
    assert.equal(release.statusCode, 409); // the run went with the board
  });
}

test('two sweeps of the same lapsed run queue one retry', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await claim(worker, repository)).json();
  await sweepAll();
  await lapse(run.id);
  await underLock('SELECT 1 FROM tasks WHERE id = $1 FOR UPDATE', [task.id], [() => sweepRuns(pool, app.log), () => sweepRuns(pool, app.log)]);
  assert.equal((await pool.query(`SELECT 1 FROM agent_runs WHERE task_id = $1 AND state = 'queued' AND attempt = 2`, [task.id])).rowCount, 1);
  const kinds = (await api('GET', `/tasks/${task.id}`)).json().activity.map((a: { kind: string }) => a.kind);
  assert.equal(kinds.filter((k: string) => k === 'refinement_retried').length, 1);
});

test('failures, cancels and a changed board repository are not retried', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const failed = (await claim(worker, repository)).json();
  await worker('POST', `/worker/runs/${failed.id}/fail`, { error: 'model withdrawn' });
  assert.equal((await latestRun(api, task.id)).id, failed.id);

  await api('POST', `/tasks/${task.id}/runs`);
  const cancelled = (await claim(worker, repository)).json();
  await api('POST', `/runs/${cancelled.id}/cancel`);
  assert.equal((await claim(worker, repository)).statusCode, 204);
  assert.equal((await latestRun(api, task.id)).id, cancelled.id);

  // The board moves to another repository mid-run: the lapsed run must not be retried against either.
  await api('POST', `/tasks/${task.id}/runs`);
  const moved = (await claim(worker, repository)).json();
  await api('PATCH', `/boards/${board.id}`, { repository: `acme/elsewhere-${randomUUID().slice(0, 8)}` });
  await lapse(moved.id);
  await sweepAll();
  assert.equal((await runRow(moved.id)).state, 'failed');
  assert.equal((await latestRun(api, task.id)).id, moved.id);
});

test('a worker claiming again after a crash gets its own run back as attempt 2', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const lost = (await claim(worker, repository)).json();
  const back = await claim(worker, repository);
  assert.equal(back.statusCode, 200);
  assert.notEqual(back.json().id, lost.id);
  assert.deepEqual(await runRow(lost.id), { state: 'failed', error: 'the worker restarted', attempt: 1 });
  const run = await latestRun(api, task.id);
  assert.deepEqual([run.id, run.state, run.attempt, run.retryReason], [back.json().id, 'running', 2, 'the worker restarted']);
});

test('workers show as offline, online or busy with a task', async () => {
  const { api, board, repository, worker } = await fixture();
  const state = async () => (await api('GET', '/workers')).json().map((w: { state: string; currentTask: object }) => [w.state, w.currentTask]);
  assert.deepEqual(await state(), [['offline', null]], 'paired, never started');
  await worker('GET', '/worker/me');
  assert.deepEqual(await state(), [['online', null]]);
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await claim(worker, repository)).json();
  assert.deepEqual(await state(), [['busy', { id: task.id, title: 'Add GitHub login' }]]);
  await worker('POST', `/worker/runs/${run.id}/complete`, done());
  assert.deepEqual(await state(), [['online', null]]);
  await pool.query(`UPDATE workers SET last_seen_at = now() - interval '31 seconds' WHERE id = (SELECT worker_id FROM agent_runs WHERE id = $1)`, [run.id]);
  assert.deepEqual(await state(), [['offline', null]]);
});

test('a queued run says why it waits', async () => {
  const { api, board, repository, worker } = await fixture();
  const connector = (await api('GET', '/me')).json().login;
  const waiting = async (taskId: string) => (await api('GET', `/tasks/${taskId}/refinement`)).json().waiting;
  const first = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  assert.deepEqual(await waiting(first.id), { reason: 'no_worker_online', connector });
  await claim(worker, 'acme/other');
  assert.deepEqual(await waiting(first.id), { reason: 'repository_not_listed', connector });
  const run = (await claim(worker, repository)).json();
  assert.equal(await waiting(first.id), null, 'running, not waiting');
  const second = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Show task counts' })).json();
  assert.deepEqual(await waiting(second.id), { reason: 'busy', connector });
  await worker('POST', `/worker/runs/${run.id}/complete`, done());
  assert.equal(await waiting(second.id), null, 'a free worker lists it: it is about to be claimed');
});

test('the board says why its queued runs wait, with one lookup however many cards wait', async () => {
  const { api, board, repository, worker } = await fixture();
  const connector = (await api('GET', '/me')).json().login;
  const boardWaiting = async () => (await api('GET', `/boards/${board.id}`)).json().waiting;
  assert.equal(await boardWaiting(), null, 'nothing queued');
  await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' });
  assert.deepEqual(await boardWaiting(), { reason: 'no_worker_online', connector });
  await claim(worker, 'acme/other');
  assert.deepEqual(await boardWaiting(), { reason: 'repository_not_listed', connector });

  const queriesFor = async (url: string) => {
    const query = pool.query;
    let n = 0;
    pool.query = ((...args: Parameters<typeof query>) => (n++, query.apply(pool, args))) as typeof query;
    try {
      assert.equal((await api('GET', url)).statusCode, 200);
    } finally {
      pool.query = query;
    }
    return n;
  };
  const one = await queriesFor(`/boards/${board.id}`);
  assert.ok(one > 0);
  await api('POST', `/boards/${board.id}/tasks`, { title: 'Show task counts' });
  await api('POST', `/boards/${board.id}/tasks`, { title: 'Dark mode' });
  assert.equal(await queriesFor(`/boards/${board.id}`), one, 'no query per queued card');

  await claim(worker, repository);
  assert.deepEqual(await boardWaiting(), { reason: 'busy', connector }, 'the other cards still wait');
});

test('a board whose connector is gone says so: no worker can take its runs', async () => {
  const { api, board } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  await pool.query('UPDATE boards SET repository_connected_by = NULL WHERE id = $1', [board.id]); // ON DELETE SET NULL
  const expected = { reason: 'no_connector', connector: null };
  assert.deepEqual((await api('GET', `/tasks/${task.id}/refinement`)).json().waiting, expected);
  assert.deepEqual((await api('GET', `/boards/${board.id}`)).json().waiting, expected);
});

test('handing a spec in again after a lost answer returns it; nobody else can', async () => {
  const { api, board, repository, worker } = await fixture();
  const other = await registerWorker(api);
  await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' });
  const run = (await claim(worker, repository)).json();
  const first = (await worker('POST', `/worker/runs/${run.id}/complete`, done())).json();
  const retried = await worker('POST', `/worker/runs/${run.id}/complete`, done(spec('Something else')));
  assert.equal(retried.statusCode, 200);
  assert.deepEqual(retried.json(), first, 'the spec already stored, not a second version');
  assert.equal((await other('POST', `/worker/runs/${run.id}/complete`, done())).statusCode, 409, "another worker's run");
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM specs WHERE run_id = $1', [run.id]);
  assert.equal(rows[0].n, 1);
});

test('the harness is stored, and only the owner sees which worker ran it', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  assert.equal((await worker('POST', '/worker/claim', { repositories: [repository], harness: 'orca' })).statusCode, 400);
  const run = (await worker('POST', '/worker/claim', { repositories: [repository], harness: 'claude-code' })).json();
  const mine = await latestRun(api, task.id);
  assert.deepEqual([mine.state, mine.harness, mine.workerName], ['running', 'claude-code', 'My Mac'], 'known while it runs');
  assert.equal((await worker('POST', `/worker/runs/${run.id}/complete`, done())).statusCode, 200);
  assert.equal((await latestRun(api, task.id)).harness, 'claude-code');

  const bob = await user();
  const { rows: [b] } = await pool.query('SELECT workspace_id FROM boards WHERE id = $1', [board.id]);
  await pool.query(`INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'member')`, [b.workspace_id, (await bob('GET', '/me')).json().id]);
  assert.equal((await latestRun(bob, task.id)).workerName, null);
});

test("a worker reads the newest approved spec of its owner's boards, and nothing else", async () => {
  const { api, board, repository, worker } = await fixture();
  const readable = async (title: string) => {
    const task = (await api('POST', `/boards/${board.id}/tasks`, { title })).json();
    const run = (await claim(worker, repository)).json();
    const v = (await worker('POST', `/worker/runs/${run.id}/complete`, done(spec(title)))).json();
    return { task, v };
  };
  const { task: shipped, v: v1 } = await readable('Shipped');
  const { task: draft } = await readable('Still a draft');
  assert.equal((await api('POST', `/specs/${v1.id}/approve`)).statusCode, 200);

  const listed = (await worker('GET', '/worker/specs')).json();
  assert.deepEqual(listed.map((s: { taskId: string }) => s.taskId), [shipped.id], 'a draft is not listed');
  assert.deepEqual(Object.keys(listed[0]).sort(), ['approvedAt', 'board', 'issue', 'repository', 'taskId', 'title', 'version']);
  assert.deepEqual([listed[0].board, listed[0].repository, listed[0].version], ['Roadmap', repository, 1]);
  assert.equal((await worker('GET', `/worker/specs/${draft.id}`)).statusCode, 404, 'unapproved');

  // A newer version that is not approved yet leaves the approved one as the readable spec.
  assert.equal((await api('POST', `/tasks/${shipped.id}/runs`)).statusCode, 201);
  const run2 = (await claim(worker, repository)).json();
  await worker('POST', `/worker/runs/${run2.id}/complete`, done(spec('Shipped, revised')));
  const one = (await worker('GET', `/worker/specs/${shipped.id}`)).json();
  assert.deepEqual([one.version, one.content.title, one.commitSha], [1, 'Shipped', 'a'.repeat(40)]);

  // Approving the newer one replaces it, newest approval first.
  const latest = (await api('GET', `/tasks/${shipped.id}/refinement`)).json().spec;
  assert.equal((await api('POST', `/specs/${latest.id}/approve`)).statusCode, 200);
  assert.equal((await worker('GET', `/worker/specs/${shipped.id}`)).json().content.title, 'Shipped, revised');
  const second = await readable('Second');
  assert.equal((await api('POST', `/specs/${second.v.id}/approve`)).statusCode, 200);
  assert.deepEqual((await worker('GET', '/worker/specs')).json().map((s: { title: string }) => s.title), ['Second', 'Shipped']);
});

test('the specs a worker reads can be narrowed by repository, and a stranger never sees them', async () => {
  const { api, board, repository, worker } = await fixture();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await claim(worker, repository)).json();
  const v1 = (await worker('POST', `/worker/runs/${run.id}/complete`, done())).json();
  await api('POST', `/specs/${v1.id}/approve`);

  const ids = async (query: string) => (await worker('GET', `/worker/specs${query}`)).json().map((s: { taskId: string }) => s.taskId);
  assert.equal((await ids(`?repository=${repository.toUpperCase()}`)).length, 1, 'GitHub names are case-insensitive');
  assert.equal((await ids(`?repository=acme/other&repository=${repository}`)).length, 1);
  assert.deepEqual(await ids('?repository=acme/other'), []);
  assert.equal((await worker('GET', '/worker/specs?repository=not%20a%20repo')).statusCode, 400);
  assert.equal((await api('GET', '/worker/specs')).statusCode, 401, 'a signed-in session is not a worker');

  // Another account's worker, and a board with no repository, show nothing.
  const strangers = await registerWorker(await user());
  assert.deepEqual((await strangers('GET', '/worker/specs')).json(), []);
  assert.equal((await strangers('GET', `/worker/specs/${task.id}`)).statusCode, 404);
  assert.equal((await worker('GET', '/worker/specs/not-a-uuid')).statusCode, 400);
  await api('PATCH', `/boards/${board.id}`, { repository: null });
  assert.deepEqual((await worker('GET', '/worker/specs')).json(), []);
  assert.equal((await worker('GET', `/worker/specs/${task.id}`)).statusCode, 404);
});

// ---- Comments on a spec, sent back to the Refiner ----

const feedback = (specVersion: number) => ({
  specVersion,
  general: 'Keep it to the settings page.',
  items: [
    { section: 'acceptanceCriteria', index: 0, comment: 'Also when GitHub is down' },
    { section: 'ambiguities', index: 0, comment: 'Yes, sign out disconnects it' },
  ],
});

/** A task with spec version 1 written and nothing running. */
async function specced() {
  const f = await fixture();
  const task = (await f.api('POST', `/boards/${f.board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await claim(f.worker, f.repository)).json();
  assert.equal(run.feedback, null, 'a plain run has no comments');
  assert.equal('previousSpec' in run, false);
  await f.worker('POST', `/worker/runs/${run.id}/complete`, done());
  return { ...f, task };
}

test('comments are stored on the run and handed to the worker with the version they are about', async () => {
  const { api, task, repository, worker } = await specced();
  assert.equal((await api('POST', `/tasks/${task.id}/runs`, { feedback: feedback(1) })).statusCode, 201);
  const requested = (await api('GET', `/tasks/${task.id}`)).json().activity.filter((a: { kind: string }) => a.kind === 'refinement_requested');
  assert.deepEqual(requested.map((a: { data: object }) => a.data), [{}, { comments: 3 }], 'the general note counts as one');

  const run = (await claim(worker, repository)).json();
  assert.deepEqual(run.feedback, feedback(1));
  assert.deepEqual(run.previousSpec, spec());
  assert.equal((await worker('POST', `/worker/runs/${run.id}/complete`, done(spec('Add GitHub sign-in')))).json().version, 2);
});

test('comments on a version that is no longer the latest are refused', async () => {
  const { api, task, repository, worker } = await specced();
  await api('POST', `/tasks/${task.id}/runs`);
  await worker('POST', `/worker/runs/${(await claim(worker, repository)).json().id}/complete`, done());
  const stale = await api('POST', `/tasks/${task.id}/runs`, { feedback: feedback(1) });
  assert.equal(stale.statusCode, 409);
  assert.equal(stale.json().message, 'the comments are not on the latest version of this spec');
  assert.equal((await api('POST', `/tasks/${task.id}/runs`, { feedback: feedback(2) })).statusCode, 201);
});

test('comments are refused, not dropped, while a refinement is queued or running', async () => {
  const { api, task, repository, worker } = await specced();
  await api('POST', `/tasks/${task.id}/runs`);
  for (const state of ['queued', 'running']) {
    if (state === 'running') await claim(worker, repository);
    const res = await api('POST', `/tasks/${task.id}/runs`, { feedback: feedback(1) });
    assert.equal(res.statusCode, 409, state);
    assert.equal(res.json().message, 'a refinement is already running; cancel it first');
  }
  const { rows } = await pool.query('SELECT feedback FROM agent_runs WHERE task_id = $1', [task.id]);
  assert.ok(rows.every((r) => r.feedback === null));
});

test('comments are validated', async () => {
  const { api, task } = await specced();
  const one = (section: string, index: number, comment = 'c') => ({ section, index, comment });
  const items = (...list: object[]) => ({ specVersion: 1, items: list });
  for (const [body, why] of [
    [{ specVersion: 1 }, 'neither a general note nor an item'],
    [items(), 'an empty list'],
    [{ specVersion: 1, general: '' }, 'an empty note'],
    [{ specVersion: 1, general: 'x'.repeat(4001) }, 'a long note'],
    [{ general: 'x' }, 'no version'],
    [items(one('title', 0)), 'a section that takes no comments'],
    [items(one('requirements', -1)), 'a negative index'],
    [items(one('requirements', 0, '')), 'an empty comment'],
    [items(one('requirements', 0, 'x'.repeat(2001))), 'a long comment'],
    [items(...Array.from({ length: 51 }, () => one('requirements', 0))), '51 items'],
    [items(one('requirements', 1)), 'an item the spec does not have'],
    [items(one('summary', 1)), 'a second summary'],
  ] as const) {
    assert.equal((await api('POST', `/tasks/${task.id}/runs`, { feedback: body })).statusCode, 400, why);
  }
  assert.equal((await pool.query(`SELECT 1 FROM agent_runs WHERE task_id = $1 AND state = 'queued'`, [task.id])).rowCount, 0);
  assert.equal((await api('POST', `/tasks/${task.id}/runs`, { feedback: items(one('summary', 0), one('evidence', 0)) })).statusCode, 201);
});

test('a retried run keeps its comments', async () => {
  const { api, task, repository, worker } = await specced();
  await api('POST', `/tasks/${task.id}/runs`, { feedback: feedback(1) });
  const first = (await claim(worker, repository)).json();
  await lapse(first.id);
  await sweepAll();
  const retry = (await claim(worker, repository)).json();
  assert.notEqual(retry.id, first.id);
  assert.equal((await latestRun(api, task.id)).attempt, 2);
  assert.deepEqual(retry.feedback, feedback(1));
  assert.deepEqual(retry.previousSpec, spec());
});
