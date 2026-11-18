import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.ts';
import { createPool } from '../src/db.ts';
import { migrate } from '../src/migrate.ts';

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

async function registerWorker(api: ReturnType<typeof as>) {
  const res = await api('POST', '/workers', { name: 'My Mac' });
  assert.equal(res.statusCode, 201);
  return as(res.json().token);
}

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
  const res = await api('POST', '/workers', { name: 'My Mac' });
  const { id, token } = res.json();
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
  assert.equal((await worker('POST', `/worker/runs/${run.id}/complete`, done())).statusCode, 409, 'a repeated completion adds nothing');
  assert.equal(await refinementOf(api, board.id, task.id), 'ready');
  const lastId = polled.events.at(-1).id;
  const final = (await api('GET', `/runs/${run.id}/events?after=${lastId}`)).json();
  assert.deepEqual(final, { state: 'succeeded', events: [] }, 'a finished run answers at once instead of waiting');

  // Refine again: a second version supersedes the first.
  assert.equal((await api('POST', `/tasks/${task.id}/runs`)).statusCode, 201);
  const run2 = (await worker('POST', '/worker/claim', { repositories: [repository] })).json();
  const v2 = (await worker('POST', `/worker/runs/${run2.id}/complete`, { ...done(spec('Add GitHub sign-in')), harness: 'orca' })).json();
  assert.equal(v2.version, 2);
  assert.equal((await api('POST', `/specs/${v1.id}/approve`)).statusCode, 409);
  const approved = await api('POST', `/specs/${v2.id}/approve`);
  assert.equal(approved.statusCode, 200);
  assert.ok(approved.json().approvedAt);
  assert.equal(await refinementOf(api, board.id, task.id), 'approved');

  const refinement = (await api('GET', `/tasks/${task.id}/refinement`)).json();
  assert.equal(refinement.spec.content.title, 'Add GitHub sign-in');
  assert.equal(refinement.run.commitSha, 'a'.repeat(40));
  assert.equal(refinement.run.harness, 'orca', 'the run records the harness the worker used');
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
  assert.equal((await worker('POST', '/worker/claim', { repositories: [repository] })).json().task.title, bobsTask.title);

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
  const res = await api('POST', '/workers', { name: 'Laptop' });
  const worker = as(res.json().token);
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
  assert.equal((await api('DELETE', `/workers/${res.json().id}`)).statusCode, 204);
  const after = (await api('GET', `/tasks/${task.id}/refinement`)).json().run;
  assert.equal(after.id, run3.id);
  assert.equal(after.state, 'failed', 'a removed worker does not leave its run stuck as running');
});
