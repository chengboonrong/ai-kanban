import assert from 'node:assert/strict';
import { createHmac, generateKeyPairSync, randomInt, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.ts';
import { createPool } from '../src/db.ts';
import { type GitHubClient, type GitHubConfig, gitHubClient, validSignature } from '../src/github.ts';
import { migrate } from '../src/migrate.ts';
import { buildWebhookApp, syncOnce } from '../src/sync.ts';

const pool = createPool(process.env.TEST_DATABASE_URL ?? 'postgres://kanban:kanban@localhost:55432/kanban_test');
const APP_ID = 4242;
const BOT = 'ai-kanban-test[bot]';
const SECRET = 'webhook-secret';

// ---- Fake GitHub: just the endpoints the sync uses, per repository, with injectable failures ----

type FakeIssue = { number: number; node_id: string; html_url: string; state: 'open'; title: string; body: string; created_at: string;
  performed_via_github_app: { id: number } | null; user: { login: string } };
/** An injected response for the next matching call: an error status, a dropped connection, or a hold until `wait` settles. */
type Failure = { match: string; status?: number; headers?: Record<string, string>; drop?: boolean; wait?: Promise<void> };
type FakeRepo = { id: number; issues: FakeIssue[]; prs: Map<number, object>; failures: Failure[]; onGraphql?: (n: number) => Promise<void> };
const repos = new Map<string, FakeRepo>();
const calls: string[] = [];

const fake = createServer(async (req, res) => {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
  const url = new URL(req.url!, 'http://fake');
  calls.push(`${req.method} ${url.pathname}`);
  const send = (status: number, data: unknown, headers: Record<string, string> = {}) => {
    res.writeHead(status, { 'content-type': 'application/json', ...headers });
    res.end(JSON.stringify(data));
  };
  if (url.pathname.startsWith('/app/installations/')) return send(201, { token: 'ghs_fake', expires_at: new Date(Date.now() + 3_600_000).toISOString() });
  const [, name, rest] =
    url.pathname === '/graphql' ? ['', `${body.variables.owner}/${body.variables.name}`, '/graphql'] : (/^\/repos\/([^/]+\/[^/]+)(.*)$/.exec(url.pathname) ?? []);
  const repo = name ? repos.get(name) : undefined;
  if (!repo) return send(404, { message: 'Not Found' });
  const call = `${req.method} ${rest || '/'}`;
  const i = repo.failures.findIndex((f) => f.match === call);
  const failure = i >= 0 ? repo.failures.splice(i, 1)[0] : undefined;
  await failure?.wait;
  if (failure?.status) return send(failure.status, { message: `injected ${failure.status}` }, failure.headers);

  if (call === 'GET /installation') return send(200, { id: 1, app_id: APP_ID, app_slug: 'ai-kanban-test' });
  if (call === 'GET /') return send(200, { id: repo.id, full_name: name });
  if (call === 'POST /issues') {
    const number = repo.issues.length + 1;
    repo.issues.push({ number, node_id: `I_${number}`, html_url: `https://github.com/${name}/issues/${number}`, state: 'open', title: body.title,
      // Recognised by its bot author alone, in case GitHub leaves performed_via_github_app empty.
      body: body.body, created_at: new Date().toISOString(), performed_via_github_app: null, user: { login: BOT } });
    if (failure?.drop) return res.socket!.destroy(); // created, but the response never arrives
    return send(201, repo.issues.at(-1));
  }
  if (call === 'GET /issues') {
    const page = Number(url.searchParams.get('page') ?? 1);
    const sorted = [...repo.issues].sort((a, b) => b.created_at.localeCompare(a.created_at));
    return send(200, sorted.slice((page - 1) * 100, page * 100));
  }
  if (call === 'POST /graphql') {
    await repo.onGraphql?.(body.variables.number);
    return send(200, { data: { repository: { pullRequest: repo.prs.get(body.variables.number) ?? null } } });
  }
  send(404, { message: 'Not Found' });
});

let app: FastifyInstance;
let webhooks: FastifyInstance;
let gh: GitHubClient;
let config: GitHubConfig;

before(async () => {
  await migrate(pool);
  await new Promise<void>((resolve) => fake.listen(0, '127.0.0.1', resolve));
  config = {
    clientId: 'Iv23-test',
    privateKey: generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey,
    webhookSecret: SECRET,
    apiUrl: `http://127.0.0.1:${(fake.address() as AddressInfo).port}`,
  };
  app = await buildApp({ pool, authMode: 'dev' });
  webhooks = await buildWebhookApp({ pool, github: config });
  gh = gitHubClient(config);
});
after(async () => {
  await Promise.all([app.close(), webhooks.close(), new Promise((resolve) => fake.close(resolve))]);
  await pool.end();
});

// ---- Helpers ----

type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';
const as = (token: string) => (method: Method, url: string, payload?: object) =>
  app.inject({ method, url, payload, headers: { authorization: `Bearer ${token}` } });
type Api = ReturnType<typeof as>;

async function user() {
  const res = await app.inject({ method: 'POST', url: '/auth/dev-login', payload: { login: `u-${randomUUID().slice(0, 8)}` } });
  return as(res.json().token);
}

/** A board on a repository of its own (the fake has it installed unless told otherwise), with a worker. */
async function fixture({ installed = true } = {}) {
  const api = await user();
  const repository = `acme/gh-${randomUUID().slice(0, 8)}`;
  const ws = (await api('POST', '/workspaces', { name: 'Acme' })).json();
  const board = (await api('POST', `/workspaces/${ws.id}/boards`, { name: 'Roadmap' })).json();
  await api('PATCH', `/boards/${board.id}`, { repository });
  const worker = as((await api('POST', '/workers', { name: 'Mac' })).json().token);
  const repo: FakeRepo = { id: randomInt(1, 2 ** 47), issues: [], prs: new Map(), failures: [] };
  if (installed) repos.set(repository, repo);
  return { api, board, repository, worker, repo };
}
type Fixture = Awaited<ReturnType<typeof fixture>>;

const spec = (overrides = {}) => ({
  title: 'Add GitHub login to settings',
  summary: 'Let people connect GitHub from the settings page.',
  requirements: ['A Connect GitHub button on settings'],
  acceptanceCriteria: ['Clicking it starts the device flow'],
  evidence: [{ path: 'lib/settings.dart', startLine: 1, endLine: 20, note: 'Settings page lives here', verified: true }],
  ambiguities: [],
  approach: ['Add a button that calls the auth service'],
  readiness: 70,
  ...overrides,
});

/** A new card refined to a ready (unapproved) spec. */
async function refined(f: Fixture, s = spec()) {
  const task = (await f.api('POST', `/boards/${f.board.id}/tasks`, { title: 'Add GitHub login' })).json();
  const run = (await f.worker('POST', '/worker/claim', { repositories: [f.repository] })).json();
  const complete = await f.worker('POST', `/worker/runs/${run.id}/complete`, { model: 'm', commitSha: 'a'.repeat(40), spec: s });
  assert.equal(complete.statusCode, 200, complete.body);
  return { task, specId: complete.json().id as string };
}

async function approved(f: Fixture, s = spec()) {
  const { task, specId } = await refined(f, s);
  assert.equal((await f.api('POST', `/specs/${specId}/approve`)).statusCode, 200);
  return task as { id: string };
}

const row = async (taskId: string) => (await pool.query('SELECT * FROM github_issues WHERE task_id = $1', [taskId])).rows[0];
const posts = (repository: string) => calls.filter((c) => c === `POST /repos/${repository}/issues`).length;
const waitSeconds = async (taskId: string) =>
  (await pool.query('SELECT extract(epoch FROM next_attempt_at - now())::int AS s FROM github_issues WHERE task_id = $1', [taskId])).rows[0].s;
const card = async (api: Api, boardId: string, taskId: string) =>
  (await api('GET', `/boards/${boardId}`)).json().columns.flatMap((c: { tasks: object[] }) => c.tasks).find((t: { id: string }) => t.id === taskId).github;
const dueNow = (taskId: string) => pool.query('UPDATE github_issues SET next_attempt_at = now() WHERE task_id = $1', [taskId]);

const sign = (raw: string) => `sha256=${createHmac('sha256', SECRET).update(raw).digest('hex')}`;
function deliver(event: string, payload: object, id: string = randomUUID(), signature?: string, to = webhooks) {
  const raw = JSON.stringify(payload);
  const headers: Record<string, string> = { 'content-type': 'application/json', 'x-github-event': event, 'x-github-delivery': id };
  headers['x-hub-signature-256'] = signature ?? sign(raw);
  if (signature === '') delete headers['x-hub-signature-256'];
  return to.inject({ method: 'POST', url: '/github/webhook', headers, payload: raw });
}
const prEvent = (f: Fixture, number: number | string, updatedAt = new Date().toISOString()) => ({
  action: 'opened',
  repository: { id: f.repo.id, full_name: f.repository },
  pull_request: { number, title: `PR ${number}`, html_url: `https://github.com/${f.repository}/pull/${number}`, user: { login: 'octocat' },
    state: 'open', draft: false, head: { sha: `sha${number}`, ref: 'feature' }, updated_at: updatedAt },
});
const pr = async (f: Fixture, number: number) =>
  (await pool.query('SELECT dirty_seq::int, synced_seq::int FROM pull_requests WHERE repository_id = $1 AND number = $2', [f.repo.id, number])).rows[0];

// ---- Tests ----

test('webhook signatures: GitHub test vector; bad, missing or short ones are 401; unconfigured is 503', async () => {
  // https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries#testing-the-webhook-payload-validation
  const vector = 'sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17';
  assert.ok(validSignature("It's a Secret to Everybody", Buffer.from('Hello, World!'), vector));
  assert.ok(!validSignature("It's a Secret to Everybody", Buffer.from('Hello, World?'), vector));

  assert.equal((await deliver('ping', { zen: 'hi' })).statusCode, 200);
  assert.equal((await deliver('ping', { zen: 'hi' }, randomUUID(), '')).statusCode, 401, 'missing');
  assert.equal((await deliver('ping', { zen: 'hi' }, randomUUID(), 'sha256=00')).statusCode, 401, 'short');
  assert.equal((await deliver('ping', { zen: 'hi' }, randomUUID(), sign('{"zen":"other"}'))).statusCode, 401, 'wrong body');

  const unconfigured = await buildWebhookApp({ pool });
  assert.equal((await deliver('ping', { zen: 'hi' }, randomUUID(), undefined, unconfigured)).statusCode, 503);
  await unconfigured.close();
});

test('approving files exactly one issue, even when approved twice and synced twice at once', async () => {
  const f = await fixture();
  const { task, specId } = await refined(f);
  const approvals = await Promise.all([1, 2].map(() => f.api('POST', `/specs/${specId}/approve`)));
  assert.deepEqual(approvals.map((r) => r.statusCode), [200, 200]);
  assert.deepEqual(await card(f.api, f.board.id, task.id), { issue: { state: 'pending' }, prs: 0, review: null, ci: null });

  await Promise.all([syncOnce(pool, gh), syncOnce(pool, gh)]);
  await syncOnce(pool, gh);
  assert.equal(posts(f.repository), 1);
  assert.equal(f.repo.issues[0].title, 'Add GitHub login to settings');
  assert.ok(f.repo.issues[0].body.startsWith(`<!-- ai-kanban:task:${task.id} -->`));

  const url = `https://github.com/${f.repository}/issues/1`;
  assert.deepEqual((await f.api('GET', `/tasks/${task.id}/github`)).json(), { issue: { state: 'created', number: 1, url, issueState: 'open' }, prs: [] });
  assert.equal((await row(task.id)).repository_id, String(f.repo.id));
  const activity = (await f.api('GET', `/tasks/${task.id}`)).json().activity;
  assert.deepEqual(activity.at(-1).data, { number: 1, url });
  assert.equal(activity.at(-1).kind, 'github_issue_created');
  assert.equal((await f.api('POST', `/tasks/${task.id}/github/retry`)).statusCode, 409, 'nothing to retry');
});

test('a create whose response is lost is adopted on the next attempt, not filed again; a pasted marker is not adopted', async () => {
  const f = await fixture();
  f.repo.failures.push({ match: 'POST /issues', drop: true });
  const task = await approved(f);
  await syncOnce(pool, gh);
  const lost = await row(task.id);
  assert.equal(lost.state, 'pending');
  assert.match(lost.last_error, /unreachable/);
  assert.equal(f.repo.issues.length, 1, 'GitHub did create it');

  // Someone pastes the marker into a newer issue; the app didn't create it, so it must not be adopted.
  f.repo.issues.push({ ...f.repo.issues[0], number: 2, html_url: 'x', created_at: new Date(Date.now() + 1000).toISOString(), user: { login: 'mallory' } });
  await dueNow(task.id);
  await syncOnce(pool, gh);
  const adopted = await row(task.id);
  assert.equal(adopted.state, 'created');
  assert.equal(adopted.attempts, 2);
  assert.equal(adopted.number, 1);
  assert.equal(posts(f.repository), 1, 'still only one POST');
});

test('an attempt whose row was claimed by someone else meanwhile never files; the new owner files once', async () => {
  const f = await fixture();
  let release!: () => void;
  f.repo.failures.push({ match: 'GET /', wait: new Promise<void>((resolve) => (release = resolve)) });
  const task = await approved(f);
  const stale = syncOnce(pool, gh);
  while ((await row(task.id)).state !== 'creating') await sleep(10);
  // Its lease lapsed and another process claimed the row: claiming counts attempts up, and that is the fence.
  await pool.query('UPDATE github_issues SET attempts = attempts + 1 WHERE task_id = $1', [task.id]);
  release();
  await stale;
  assert.equal(posts(f.repository), 0, 'the stale attempt never creates');

  // The other process died too: once its lease lapses the row is claimed again, looked for, and filed once.
  await pool.query(`UPDATE github_issues SET locked_until = now() - interval '1 second' WHERE task_id = $1`, [task.id]);
  await syncOnce(pool, gh);
  assert.equal((await row(task.id)).state, 'created');
  assert.equal(posts(f.repository), 1);
});

test('a rate limit stops every request until it resets; the issue waits as long as GitHub asked', async () => {
  const limitedGh = gitHubClient(config); // a client of its own: its pause would hold up the other tests
  const limited = await fixture();
  limited.repo.failures.push({ match: 'POST /issues', status: 429, headers: { 'retry-after': '600' } });
  const next = await fixture();
  const a = await approved(limited);
  const b = await approved(next);
  await dueNow(b.id); // queued after a, so a is claimed first
  await pool.query(`UPDATE github_issues SET next_attempt_at = now() - interval '1 minute' WHERE task_id = $1`, [a.id]);
  await syncOnce(pool, limitedGh);

  assert.equal((await row(a.id)).state, 'pending');
  assert.ok(Math.abs((await waitSeconds(a.id)) - 600) <= 2, "GitHub's retry-after wins");
  assert.equal((await row(b.id)).state, 'pending');
  assert.match((await row(b.id)).last_error, /waiting for it to reset/);
  assert.ok(!calls.some((c) => c.includes(next.repository)), 'no request for the next issue');
});

test('not installed and rejected issues fail with a reason; retry re-queues; 5xx backs off; a revoked token is renewed', async () => {
  const missing = await fixture({ installed: false });
  const rejected = await fixture();
  rejected.repo.failures.push({ match: 'POST /issues', status: 422 });
  const flaky = await fixture();
  flaky.repo.failures.push({ match: 'POST /issues', status: 500 });
  const revoked = await fixture();
  revoked.repo.failures.push({ match: 'POST /issues', status: 401 });
  const [a, b, c, e] = await Promise.all([missing, rejected, flaky, revoked].map((f) => approved(f)));
  await syncOnce(pool, gh);

  assert.equal((await row(a.id)).state, 'failed');
  const failed = (await missing.api('GET', `/tasks/${a.id}/github`)).json().issue;
  assert.equal(failed.state, 'failed');
  assert.match(failed.error, /isn't installed on/);
  assert.equal((await row(b.id)).state, 'failed');
  assert.match((await row(b.id)).last_error, /GitHub rejected the issue/);

  assert.equal((await row(c.id)).state, 'pending');
  assert.ok(Math.abs((await waitSeconds(c.id)) - 60) <= 2, 'first retry after a minute');

  assert.equal((await row(e.id)).state, 'created');
  assert.equal(posts(revoked.repository), 2, 'retried once with a fresh token');

  // Install the app, then retry: queued again (attempts kept) and filed.
  repos.set(missing.repository, missing.repo);
  const retried = await missing.api('POST', `/tasks/${a.id}/github/retry`);
  assert.equal(retried.statusCode, 200);
  assert.deepEqual(retried.json().issue, { state: 'pending' });
  await syncOnce(pool, gh);
  assert.equal((await row(a.id)).state, 'created');
  assert.equal((await row(a.id)).attempts, 2);
  assert.equal((await (await user())('POST', `/tasks/${a.id}/github/retry`)).statusCode, 404, 'board members only');
});

test('the issue body stays within the cap with its marker first, and spec text cannot mention anyone', async () => {
  const f = await fixture();
  const long = (n: number) => Array.from({ length: n }, () => 'y'.repeat(1000));
  const task = await approved(
    f,
    spec({
      summary: `Ping @octocat <!-- hide the rest --> see other/repo#12 ${'x'.repeat(3900)}`,
      requirements: long(30),
      acceptanceCriteria: long(30),
      evidence: Array.from({ length: 30 }, (_, i) => ({ path: `src/${'p'.repeat(400)}${i}.ts\n\n<!--`, startLine: 1, endLine: 2, note: 'n'.repeat(1000) })),
      ambiguities: long(20),
      approach: long(20),
    }),
  );
  await syncOnce(pool, gh);
  const { body } = f.repo.issues[0];
  assert.ok(body.length <= 60_000, `${body.length}`);
  assert.ok(body.startsWith(`<!-- ai-kanban:task:${task.id} -->\n`));
  assert.ok(body.endsWith('_Truncated; the full spec is in AI Kanban._'));
  assert.ok(body.includes('Ping @​octocat'));
  assert.ok(body.includes('other/repo#\u200B12'), 'no cross-reference on another repository');
  assert.ok(!body.includes('\n\n<!--'), 'a path stays on its line');
  assert.equal(body.split('<!--').length, 2, 'only the marker opens a comment');
});

test("a board that moves to another repository: approval is refused and queued issues fail", async () => {
  const f = await fixture();
  const ready = await refined(f);
  const queued = await approved(f);
  assert.equal((await row(queued.id)).state, 'pending');

  await f.api('PATCH', `/boards/${f.board.id}`, { repository: 'acme/elsewhere' });
  const approve = await f.api('POST', `/specs/${ready.specId}/approve`);
  assert.equal(approve.statusCode, 409);
  assert.match(approve.json().message, /now points at acme\/elsewhere; refine again/);
  assert.equal(await row(ready.task.id), undefined);
  assert.equal((await row(queued.id)).state, 'failed');
  assert.match((await row(queued.id)).last_error, /repository changed/);
  assert.equal((await f.api('POST', `/tasks/${queued.id}/github/retry`)).statusCode, 409);
  await syncOnce(pool, gh);
  assert.equal(posts(f.repository), 0);
});

test('webhooks: a duplicate delivery is processed once, a failing one rolls back, unknown repositories are ignored', async () => {
  const f = await fixture();
  const task = await approved(f);
  await syncOnce(pool, gh);

  const id = randomUUID();
  assert.equal((await deliver('pull_request', prEvent(f, 7), id)).statusCode, 200);
  assert.equal((await deliver('pull_request', prEvent(f, 7), id)).json().duplicate, true);
  assert.equal((await pr(f, 7)).dirty_seq, 1, 'processed once');
  assert.equal((await deliver('pull_request', prEvent(f, 7))).statusCode, 200);
  assert.equal((await pr(f, 7)).dirty_seq, 2);

  const broken = randomUUID();
  assert.equal((await deliver('pull_request', prEvent(f, 'not-a-number'), broken)).statusCode, 500);
  assert.equal((await pool.query('SELECT 1 FROM github_deliveries WHERE id = $1', [broken])).rowCount, 0, 'redelivery will be processed');

  const stranger = { ...f, repo: { ...f.repo, id: randomInt(1, 2 ** 47) } };
  assert.equal((await deliver('pull_request', prEvent(stranger, 7))).statusCode, 200);
  assert.equal(await pr(stranger, 7), undefined);

  const issue = (action: string, updated_at: string) => ({ action, repository: { id: f.repo.id, full_name: f.repository }, issue: { number: 1, updated_at } });
  await deliver('issues', issue('closed', '2026-11-02T00:00:00Z'));
  assert.equal((await card(f.api, f.board.id, task.id)).issue.state, 'closed');
  await deliver('issues', issue('reopened', '2026-11-01T00:00:00Z'));
  assert.equal((await card(f.api, f.board.id, task.id)).issue.state, 'closed', 'an older event arriving late is ignored');
  await deliver('issues', issue('reopened', '2026-11-03T00:00:00Z'));
  assert.equal((await card(f.api, f.board.id, task.id)).issue.state, 'open');
});

test('pull requests link by closing reference or an N- branch, not a mention; review and CI come from GraphQL', async () => {
  const f = await fixture();
  const task = await approved(f);
  await syncOnce(pool, gh);
  const node = (n: number, o: object) => ({
    title: `PR ${n}`, url: `https://github.com/${f.repository}/pull/${n}`, state: 'OPEN', isDraft: false, headRefName: 'feature', headRefOid: `sha${n}`,
    updatedAt: '2026-11-01T00:00:00Z', reviewDecision: null, author: { login: 'octocat' }, commits: { nodes: [] }, closingIssuesReferences: { nodes: [] }, ...o,
  });
  const rollup = (state: string) => ({ nodes: [{ commit: { statusCheckRollup: { state } } }] });
  f.repo.prs.set(7, node(7, { reviewDecision: 'APPROVED', commits: rollup('FAILURE'), updatedAt: '2026-11-02T00:00:00Z',
    closingIssuesReferences: { nodes: [{ number: 1, repository: { databaseId: f.repo.id } }] } }));
  f.repo.prs.set(8, node(8, { headRefName: '1-fix-login', isDraft: true, commits: rollup('PENDING') }));
  // "Fixes #1" in another repository, and a body that only mentions #1 (bodies are never read): no link.
  f.repo.prs.set(9, node(9, { headRefName: 'feature-1', closingIssuesReferences: { nodes: [{ number: 1, repository: { databaseId: f.repo.id + 1 } }] } }));
  // A fork's branch can be named anything: it doesn't link.
  f.repo.prs.set(10, node(10, { headRefName: '1-from-a-fork', isCrossRepository: true }));
  for (const n of [7, 8, 9, 10]) await deliver('pull_request', prEvent(f, n));

  // A check run lands while #7 is being read: it must stay dirty for the next pass.
  f.repo.onGraphql = async (n) => {
    if (n !== 7) return;
    f.repo.onGraphql = undefined;
    await deliver('check_run', { repository: { id: f.repo.id, full_name: f.repository }, check_run: { head_sha: 'other', pull_requests: [{ number: 7 }] } });
  };
  await syncOnce(pool, gh);
  const seven = await pr(f, 7);
  assert.ok(seven.dirty_seq > seven.synced_seq, 'bumped mid-read stays dirty');
  assert.equal((await pr(f, 8)).dirty_seq, (await pr(f, 8)).synced_seq);

  const { prs } = (await f.api('GET', `/tasks/${task.id}/github`)).json();
  assert.deepEqual(prs, [
    { number: 7, title: 'PR 7', url: `https://github.com/${f.repository}/pull/7`, author: 'octocat', state: 'open', draft: false, review: 'approved',
      ci: 'failure', updatedAt: '2026-11-02T00:00:00.000Z', repository: f.repository },
    { number: 8, title: 'PR 8', url: `https://github.com/${f.repository}/pull/8`, author: 'octocat', state: 'open', draft: true, review: 'none',
      ci: 'pending', updatedAt: '2026-11-01T00:00:00.000Z', repository: f.repository },
  ]);
  assert.deepEqual(await card(f.api, f.board.id, task.id), {
    issue: { number: 1, url: `https://github.com/${f.repository}/issues/1`, state: 'open' }, prs: 2, review: 'approved', ci: 'failure',
  });

  await syncOnce(pool, gh);
  assert.equal((await pr(f, 7)).dirty_seq, (await pr(f, 7)).synced_seq, 'clean after the next pass');

  // A commit status finds the PR by its head commit.
  const before8 = (await pr(f, 8)).dirty_seq;
  await deliver('status', { repository: { id: f.repo.id, full_name: f.repository }, sha: 'sha8', state: 'success' });
  assert.equal((await pr(f, 8)).dirty_seq, before8 + 1);
});
