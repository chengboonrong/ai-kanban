import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../src/app.ts';
import { createPool, rateLimit } from '../src/db.ts';
import type { Mailer } from '../src/mail.ts';
import { migrate } from '../src/migrate.ts';

const pool = createPool(process.env.TEST_DATABASE_URL ?? 'postgres://kanban:kanban@localhost:55432/kanban_test');
let app: FastifyInstance;
/** Records what it sends (that's how tests get invite tokens); `fail` makes the next sends throw. */
const mailer = {
  sent: [] as Parameters<Mailer['sendInvite']>[0][],
  fail: false,
  async sendInvite(m: Parameters<Mailer['sendInvite']>[0]) {
    if (this.fail) throw new Error('provider down');
    this.sent.push(m);
  },
};

before(async () => {
  await migrate(pool);
  app = await buildApp({ pool, authMode: 'dev', mailer });
});
after(async () => {
  await app.close();
  await pool.end();
});

async function login() {
  const res = await app.inject({ method: 'POST', url: '/auth/dev-login', payload: { login: `u-${randomUUID().slice(0, 8)}` } });
  assert.equal(res.statusCode, 200);
  const token = res.json().token as string;
  return (method: 'GET' | 'POST' | 'PATCH' | 'DELETE', url: string, payload?: object, headers: Record<string, string> = {}) =>
    app.inject({ method, url, payload, headers: { authorization: `Bearer ${token}`, ...headers } });
}

async function boardFixture() {
  const api = await login();
  const ws = (await api('POST', '/workspaces', { name: 'Acme' })).json();
  const res = await api('POST', `/workspaces/${ws.id}/boards`, { name: 'Roadmap' });
  assert.equal(res.statusCode, 201);
  return { api, ws, board: res.json() };
}

test('rejects requests without a valid session', async () => {
  assert.equal((await app.inject({ method: 'GET', url: '/workspaces' })).statusCode, 401);
  const bad = await app.inject({ method: 'GET', url: '/workspaces', headers: { authorization: 'Bearer nope' } });
  assert.equal(bad.statusCode, 401);
});

test('dev login is absent unless AUTH_MODE=dev, and refused in production', async () => {
  const prod = await buildApp({ pool, authMode: 'none' });
  assert.equal((await prod.inject({ method: 'POST', url: '/auth/dev-login', payload: { login: 'x' } })).statusCode, 401);
  await prod.close();

  process.env.NODE_ENV = 'production';
  try {
    await assert.rejects(buildApp({ pool, authMode: 'dev' }), /refused/);
  } finally {
    delete process.env.NODE_ENV;
  }
});

test('logout revokes the session', async () => {
  const api = await login();
  assert.equal((await api('GET', '/me')).statusCode, 200);
  assert.equal((await api('POST', '/auth/logout')).statusCode, 204);
  assert.equal((await api('GET', '/me')).statusCode, 401);
});

test('creating a board seeds default columns and lists it under the workspace', async () => {
  const { api, ws, board } = await boardFixture();
  assert.deepEqual(
    board.columns.map((c: { name: string }) => c.name),
    ['Backlog', 'Todo', 'In Progress', 'Done'],
  );
  const list = (await api('GET', '/workspaces')).json();
  assert.deepEqual(list.map((w: { id: string }) => w.id), [ws.id]);
  assert.equal(list[0].boards[0].id, board.id);
});

test('task creation is idempotent per Idempotency-Key', async () => {
  const { api, board } = await boardFixture();
  const headers = { 'idempotency-key': randomUUID() };
  const first = await api('POST', `/boards/${board.id}/tasks`, { title: 'Add login with GitHub' }, headers);
  const retry = await api('POST', `/boards/${board.id}/tasks`, { title: 'Add login with GitHub' }, headers);
  assert.equal(first.statusCode, 201);
  assert.equal(retry.statusCode, 200);
  assert.equal(retry.json().id, first.json().id);

  // concurrent retries of one capture still yield a single card
  const burst = { 'idempotency-key': randomUUID() };
  const results = await Promise.all(Array.from({ length: 5 }, () => api('POST', `/boards/${board.id}/tasks`, { title: 'Second task' }, burst)));
  assert.equal(new Set(results.map((r) => r.json().id)).size, 1);
  assert.deepEqual(results.map((r) => r.statusCode).sort(), [200, 200, 200, 200, 201]);

  const backlog = (await api('GET', `/boards/${board.id}`)).json().columns[0];
  assert.deepEqual(
    backlog.tasks.map((t: { title: string; position: number }) => [t.title, t.position]),
    [['Add login with GitHub', 0], ['Second task', 1]],
  );
});

test('moving a task between columns renumbers positions and records activity', async () => {
  const { api, board } = await boardFixture();
  const [backlog, todo] = board.columns;
  const ids: string[] = [];
  for (const title of ['a', 'b', 'c']) ids.push((await api('POST', `/boards/${board.id}/tasks`, { title })).json().id);

  const moved = await api('PATCH', `/tasks/${ids[0]}`, { columnId: todo.id });
  assert.equal(moved.statusCode, 200);
  assert.equal(moved.json().columnId, todo.id);

  const cols = (await api('GET', `/boards/${board.id}`)).json().columns;
  const titles = (i: number) => cols[i].tasks.map((t: { title: string; position: number }) => `${t.title}@${t.position}`);
  assert.deepEqual(titles(0), ['b@0', 'c@1']);
  assert.deepEqual(titles(1), ['a@0']);

  // reorder within a column: c to the top
  await api('PATCH', `/tasks/${ids[2]}`, { position: 0 });
  const after = (await api('GET', `/boards/${board.id}`)).json().columns[0].tasks;
  assert.deepEqual(after.map((t: { title: string }) => t.title), ['c', 'b']);

  await api('PATCH', `/tasks/${ids[0]}`, { title: 'a renamed', description: 'details' });
  const detail = (await api('GET', `/tasks/${ids[0]}`)).json();
  assert.deepEqual(
    detail.activity.map((a: { kind: string }) => a.kind),
    ['created', 'moved', 'updated'],
  );
  assert.deepEqual(detail.activity[1].data, { from: backlog.name, to: todo.name });
  assert.deepEqual(detail.activity[2].data, { title: { from: 'a', to: 'a renamed' }, description: true });
});

test('columns can be added, reordered, renamed and deleted only when empty', async () => {
  const { api, board } = await boardFixture();
  const added = await api('POST', `/boards/${board.id}/columns`, { name: 'Review' });
  assert.equal(added.statusCode, 201);
  assert.equal(added.json().position, 4);

  await api('PATCH', `/columns/${added.json().id}`, { position: 0, name: 'Triage' });
  const names = (await api('GET', `/boards/${board.id}`)).json().columns.map((c: { name: string; position: number }) => `${c.name}@${c.position}`);
  assert.deepEqual(names, ['Triage@0', 'Backlog@1', 'Todo@2', 'In Progress@3', 'Done@4']);

  await api('POST', `/boards/${board.id}/tasks`, { title: 'blocker', columnId: added.json().id });
  assert.equal((await api('DELETE', `/columns/${added.json().id}`)).statusCode, 409);
  assert.equal((await api('DELETE', `/columns/${board.columns[3].id}`)).statusCode, 204);
});

test('deleting a task closes the gap in its column', async () => {
  const { api, board } = await boardFixture();
  const a = (await api('POST', `/boards/${board.id}/tasks`, { title: 'a' })).json();
  await api('POST', `/boards/${board.id}/tasks`, { title: 'b' });
  assert.equal((await api('DELETE', `/tasks/${a.id}`)).statusCode, 204);
  const tasks = (await api('GET', `/boards/${board.id}`)).json().columns[0].tasks;
  assert.deepEqual(tasks.map((t: { title: string; position: number }) => [t.title, t.position]), [['b', 0]]);
});

test('other users cannot see or change a board they are not a member of', async () => {
  const { board } = await boardFixture();
  const task = board.columns[0].id;
  const stranger = await login();
  assert.equal((await stranger('GET', `/boards/${board.id}`)).statusCode, 404);
  assert.equal((await stranger('POST', `/boards/${board.id}/tasks`, { title: 'x' })).statusCode, 404);
  assert.equal((await stranger('DELETE', `/columns/${task}`)).statusCode, 404);
  assert.deepEqual((await stranger('GET', '/workspaces')).json(), []);
});

test('validates input', async () => {
  const { api, board } = await boardFixture();
  assert.equal((await api('POST', `/boards/${board.id}/tasks`, { title: '' })).statusCode, 400);
  assert.equal((await api('GET', '/boards/not-a-uuid')).statusCode, 400);
  const foreign = await boardFixture();
  const res = await api('PATCH', `/tasks/${(await api('POST', `/boards/${board.id}/tasks`, { title: 't' })).json().id}`, {
    columnId: foreign.board.columns[0].id,
  });
  assert.equal(res.statusCode, 400);
});

test('racing deletes return 404 for the loser, never 500', async () => {
  const { api, board } = await boardFixture();
  const column = (await api('POST', `/boards/${board.id}/columns`, { name: 'Tmp' })).json();
  const task = (await api('POST', `/boards/${board.id}/tasks`, { title: 't' })).json();
  const columnDeletes = await Promise.all([1, 2, 3].map(() => api('DELETE', `/columns/${column.id}`)));
  assert.deepEqual(columnDeletes.map((r) => r.statusCode).sort(), [204, 404, 404]);
  const taskOps = await Promise.all([api('DELETE', `/tasks/${task.id}`), api('PATCH', `/tasks/${task.id}`, { title: 'x' }), api('DELETE', `/tasks/${task.id}`)]);
  assert.ok(taskOps.every((r) => [200, 204, 404].includes(r.statusCode)), taskOps.map((r) => r.statusCode).join());
  assert.equal(taskOps.filter((r) => r.statusCode === 204).length, 1);
});

// ---- Members and invites (AUTH_MODE=dev: no address check on accept) ----

type Api = Awaited<ReturnType<typeof login>>;
const address = () => `x-${randomUUID().slice(0, 8)}@example.com`;
/** The token in the last link mailed to `to`. */
const tokenFor = (to: string) => mailer.sent.findLast((m) => m.to === to)!.link.split('/#/invite/')[1];
const userId = async (api: Api) => (await api('GET', '/me')).json().id as string;

/** Invites a new user into the owner's workspace through an emailed link; returns their api and id. */
async function join(owner: Api, workspaceId: string) {
  const email = address();
  assert.equal((await owner('POST', `/workspaces/${workspaceId}/invites`, { email })).statusCode, 201);
  const api = await login();
  const res = await api('POST', '/invites/accept', { token: tokenFor(email) });
  assert.equal(res.statusCode, 200, res.body);
  return { api, id: await userId(api) };
}

test('members: listed owner first; the owner makes a member admin and back; only the owner changes roles or removes; the owner stays', async () => {
  const { api: owner, ws, board } = await boardFixture();
  const a = await join(owner, ws.id);
  const b = await join(owner, ws.id);
  const ownerId = await userId(owner);

  const members = (await b.api('GET', `/workspaces/${ws.id}/members`)).json();
  assert.deepEqual(Object.keys(members[0]).sort(), ['displayName', 'login', 'role', 'userId'], 'no addresses');
  assert.deepEqual(members.map((m: { role: string }) => m.role), ['owner', 'member', 'member']);
  assert.equal(members[0].userId, ownerId);
  assert.deepEqual(new Set(members.slice(1).map((m: { userId: string }) => m.userId)), new Set([a.id, b.id]));
  assert.ok(members[1].login < members[2].login, 'then by login');
  assert.equal((await (await login())('GET', `/workspaces/${ws.id}/members`)).statusCode, 404, 'a stranger learns nothing');

  assert.equal((await b.api('PATCH', `/workspaces/${ws.id}/members/${a.id}`, { role: 'admin' })).statusCode, 403, 'a member');
  const made = await owner('PATCH', `/workspaces/${ws.id}/members/${a.id}`, { role: 'admin' });
  assert.deepEqual([made.statusCode, made.json().role, made.json().userId], [200, 'admin', a.id]);
  assert.equal((await a.api('GET', '/workspaces')).json()[0].role, 'admin', 'on the next request');
  assert.equal((await a.api('PATCH', `/workspaces/${ws.id}/members/${b.id}`, { role: 'admin' })).statusCode, 403, 'an admin');
  assert.equal((await a.api('DELETE', `/workspaces/${ws.id}/members/${b.id}`)).statusCode, 403, 'an admin');
  assert.equal((await owner('PATCH', `/workspaces/${ws.id}/members/${a.id}`, { role: 'owner' })).statusCode, 400);
  assert.equal((await owner('PATCH', `/workspaces/${ws.id}/members/${ownerId}`, { role: 'member' })).statusCode, 400);
  assert.equal((await owner('PATCH', `/workspaces/${ws.id}/members/${randomUUID()}`, { role: 'admin' })).statusCode, 404);
  assert.equal((await owner('PATCH', `/workspaces/${ws.id}/members/${a.id}`, { role: 'member' })).json().role, 'member', 'and back');

  assert.equal((await owner('DELETE', `/workspaces/${ws.id}/members/${ownerId}`)).statusCode, 400, "the owner can't leave");
  assert.equal((await a.api('DELETE', `/workspaces/${ws.id}/members/${ownerId}`)).statusCode, 403, "or be removed");
  assert.equal((await b.api('DELETE', `/workspaces/${ws.id}/members/${b.id}`)).statusCode, 204, 'a member leaves');

  // A removed member loses the boards, tasks and runs at once.
  const task = (await a.api('POST', `/boards/${board.id}/tasks`, { title: 'by a' })).json();
  assert.equal((await a.api('GET', `/tasks/${task.id}/refinement`)).statusCode, 200);
  assert.equal((await owner('DELETE', `/workspaces/${ws.id}/members/${a.id}`)).statusCode, 204);
  for (const [method, url] of [['GET', `/boards/${board.id}`], ['GET', `/tasks/${task.id}`], ['GET', `/tasks/${task.id}/refinement`], ['GET', `/workspaces/${ws.id}/members`]] as const) {
    assert.equal((await a.api(method, url)).statusCode, 404, url);
  }
  assert.equal((await a.api('POST', `/boards/${board.id}/tasks`, { title: 'x' })).statusCode, 404);
  assert.deepEqual((await a.api('GET', '/workspaces')).json(), []);
  assert.equal((await owner('DELETE', `/workspaces/${ws.id}/members/${a.id}`)).statusCode, 404, 'already gone');
  assert.deepEqual((await owner('GET', `/workspaces/${ws.id}/members`)).json().map((m: { userId: string }) => m.userId), [ownerId]);
});

test('invites: owners and admins only; inviting again or resending voids the old link; revoking voids its link', async () => {
  const { api: owner, ws } = await boardFixture();
  const member = await join(owner, ws.id);
  const email = address();
  const created = await owner('POST', `/workspaces/${ws.id}/invites`, { email: email.toUpperCase() });
  assert.equal(created.statusCode, 201);
  const invite = created.json();
  const ownerLogin = (await owner('GET', '/me')).json().login;
  assert.deepEqual({ ...invite, id: typeof invite.id, createdAt: typeof invite.createdAt, expiresAt: typeof invite.expiresAt }, {
    id: 'string', email, invitedBy: ownerLogin, createdAt: 'string', expiresAt: 'string',
  }, 'lowercased');
  const days = (Date.parse(invite.expiresAt) - Date.parse(invite.createdAt)) / 86_400_000;
  assert.ok(Math.abs(days - 7) < 0.01, `${days} days`);
  const mail = mailer.sent.at(-1)!;
  assert.deepEqual({ ...mail, link: mail.link.replace(/[^/]+$/, 'TOKEN') }, { to: email, inviter: ownerLogin, workspace: 'Acme', link: 'http://localhost:3000/#/invite/TOKEN' });

  // A member can't see or manage invites; a non-member gets 404.
  for (const [method, url] of [['GET', `/workspaces/${ws.id}/invites`], ['POST', `/workspaces/${ws.id}/invites`], ['POST', `/workspaces/${ws.id}/invites/${invite.id}/resend`], ['DELETE', `/workspaces/${ws.id}/invites/${invite.id}`]] as const) {
    assert.equal((await member.api(method, url, method === 'POST' && url.endsWith('invites') ? { email: address() } : undefined)).statusCode, 403, `${method} ${url}`);
    assert.equal((await (await login())(method, url, method === 'POST' && url.endsWith('invites') ? { email: address() } : undefined)).statusCode, 404, `${method} ${url}`);
  }
  assert.equal((await owner('POST', `/workspaces/${ws.id}/invites`, { email: 'not an address' })).statusCode, 400);
  assert.equal((await owner('POST', `/workspaces/${ws.id}/invites`, { email: `${'a'.repeat(250)}@x.io` })).statusCode, 400, 'over 254 characters');

  // Inviting the address again resends the same invite with a new token.
  const first = tokenFor(email);
  const again = await owner('POST', `/workspaces/${ws.id}/invites`, { email });
  assert.deepEqual([again.statusCode, again.json().id], [200, invite.id]);
  const second = tokenFor(email);
  assert.notEqual(second, first);
  const resent = await owner('POST', `/workspaces/${ws.id}/invites/${invite.id}/resend`);
  assert.deepEqual([resent.statusCode, resent.json().id], [200, invite.id]);
  const invitee = await login();
  for (const old of [first, second]) {
    const res = await invitee('POST', '/invites/accept', { token: old });
    assert.deepEqual([res.statusCode, res.json().message], [404, 'This invite expired or was already used']);
  }

  // An admin manages invites too. Revoking voids the link; a revoked invite can't be resent or revoked again.
  await owner('PATCH', `/workspaces/${ws.id}/members/${member.id}`, { role: 'admin' });
  const other = address();
  const revocable = (await member.api('POST', `/workspaces/${ws.id}/invites`, { email: other })).json();
  assert.equal((await member.api('DELETE', `/workspaces/${ws.id}/invites/${revocable.id}`)).statusCode, 204);
  assert.equal((await owner('DELETE', `/workspaces/${ws.id}/invites/${revocable.id}`)).statusCode, 404);
  assert.equal((await owner('POST', `/workspaces/${ws.id}/invites/${revocable.id}/resend`)).statusCode, 404);
  assert.equal((await invitee('POST', '/invites/accept', { token: tokenFor(other) })).statusCode, 404);

  // A failed send keeps the invite for a resend.
  mailer.fail = true;
  const failed = await owner('POST', `/workspaces/${ws.id}/invites`, { email: other });
  mailer.fail = false;
  assert.equal(failed.statusCode, 502);
  mailer.fail = true;
  const failedResend = await owner('POST', `/workspaces/${ws.id}/invites/${invite.id}/resend`);
  mailer.fail = false;
  assert.deepEqual([failedResend.statusCode, failedResend.json().message], [502, 'The invite was saved but its email could not be sent; resend it']);
  assert.equal((await owner('POST', `/workspaces/${ws.id}/invites/${invite.id}/resend`)).statusCode, 200, 'the unsent token is replaced on resend');
  const pending = (await member.api('GET', `/workspaces/${ws.id}/invites`)).json();
  assert.deepEqual(pending.map((i: { email: string }) => i.email).sort(), [email, other].sort(), 'pending only, with addresses');
  assert.equal(pending.find((i: { email: string }) => i.email === email).invitedBy, ownerLogin);

  // Someone already in the workspace (by a verified address) isn't invited again.
  await pool.query('INSERT INTO user_emails (user_id, email) VALUES ($1, $2)', [member.id, 'admin@example.com']);
  assert.equal((await owner('POST', `/workspaces/${ws.id}/invites`, { email: 'Admin@example.com' })).statusCode, 409);

  // The last link works.
  const joined = await invitee('POST', '/invites/accept', { token: tokenFor(email) });
  assert.deepEqual([joined.statusCode, joined.json()], [200, { workspaceId: ws.id, name: 'Acme' }]);
  assert.equal((await invitee('GET', '/workspaces')).json()[0].role, 'member');
});

test('accepting: once per link; a second accept is a no-op; expired, used and revoked links are 404; races have one winner', async () => {
  const { api: owner, ws, board } = await boardFixture();
  const invite = async () => {
    const email = address();
    const { id } = (await owner('POST', `/workspaces/${ws.id}/invites`, { email })).json();
    return { id, token: tokenFor(email) };
  };
  const [a, b] = [await login(), await login()];

  const first = await invite();
  assert.equal((await a('POST', '/invites/accept', { token: first.token })).statusCode, 200);
  assert.equal((await a('GET', `/boards/${board.id}`)).statusCode, 200, 'sees the boards');
  const twice = await a('POST', '/invites/accept', { token: first.token });
  assert.deepEqual([twice.statusCode, twice.json()], [200, { workspaceId: ws.id, name: 'Acme' }], 'a no-op');
  assert.equal((await b('POST', '/invites/accept', { token: first.token })).statusCode, 404, 'used: adds nobody else');
  assert.equal((await b('GET', `/boards/${board.id}`)).statusCode, 404);
  assert.equal((await owner('GET', `/workspaces/${ws.id}/members`)).json().length, 2);

  const expired = await invite();
  await pool.query(`UPDATE workspace_invites SET expires_at = now() - interval '1 second' WHERE id = $1`, [expired.id]);
  assert.ok((await owner('GET', `/workspaces/${ws.id}/invites`)).json().some((i: { id: string }) => i.id === expired.id), 'listed, as expired');
  assert.equal((await b('POST', '/invites/accept', { token: expired.token })).statusCode, 404);
  assert.equal((await b('POST', '/invites/accept', { token: 'x'.repeat(43) })).statusCode, 404, 'unknown');

  // Already a member: accepting a pending invite marks it used.
  const spare = await invite();
  assert.equal((await a('POST', '/invites/accept', { token: spare.token })).statusCode, 200);
  assert.ok(!(await owner('GET', `/workspaces/${ws.id}/invites`)).json().some((i: { id: string }) => i.id === spare.id));
  assert.equal((await owner('GET', `/workspaces/${ws.id}/members`)).json().length, 2);

  // Removed since: the used link doesn't bring them back.
  await owner('DELETE', `/workspaces/${ws.id}/members/${await userId(a)}`);
  assert.equal((await a('POST', '/invites/accept', { token: first.token })).statusCode, 404);

  // Two people at once: exactly one joins. Accept against revoke: one of them wins.
  const raced = await invite();
  const both = await Promise.all([a('POST', '/invites/accept', { token: raced.token }), b('POST', '/invites/accept', { token: raced.token })]);
  assert.deepEqual(both.map((r) => r.statusCode).sort(), [200, 404]);
  const contested = await invite();
  const [accepted, revoked] = await Promise.all([
    (await login())('POST', '/invites/accept', { token: contested.token }),
    owner('DELETE', `/workspaces/${ws.id}/invites/${contested.id}`),
  ]);
  assert.ok(
    (accepted.statusCode === 200 && revoked.statusCode === 404) || (accepted.statusCode === 404 && revoked.statusCode === 204),
    `${accepted.statusCode} ${revoked.statusCode}`,
  );
  assert.equal((await owner('GET', `/workspaces/${ws.id}/members`)).json().length, accepted.statusCode === 200 ? 3 : 2);

  // One person accepting two invites at once: both succeed, one membership.
  const [x, y] = [await invite(), await invite()];
  const d = await login();
  const pair = await Promise.all([d('POST', '/invites/accept', { token: x.token }), d('POST', '/invites/accept', { token: y.token })]);
  assert.deepEqual(pair.map((r) => r.statusCode), [200, 200], pair.map((r) => r.body).join());

  // Accepting is rate limited per user, like the device-code endpoints.
  const c = await login();
  for (let i = 0; i < 30; i++) assert.equal((await c('POST', '/invites/accept', { token: `nope-${i}` })).statusCode, 404);
  const limited = await c('POST', '/invites/accept', { token: 'nope' });
  assert.deepEqual([limited.statusCode, Number(limited.headers['retry-after']) > 0], [429, true]);
});

test('invite emails stop at 20 an hour per workspace and per inviter, with 429', async () => {
  const { api: owner, ws } = await boardFixture();
  const admin = await login();
  await pool.query(`INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'admin')`, [ws.id, await userId(admin)]);
  for (let i = 0; i < 20; i++) assert.equal((await owner('POST', `/workspaces/${ws.id}/invites`, { email: address() })).statusCode, 201);
  const limited = await owner('POST', `/workspaces/${ws.id}/invites`, { email: address() });
  assert.equal(limited.statusCode, 429);
  assert.ok(Number(limited.headers['retry-after']) > 3000, 'about an hour');
  assert.equal((await admin('POST', `/workspaces/${ws.id}/invites`, { email: address() })).statusCode, 429, 'per workspace');
  const elsewhere = (await owner('POST', '/workspaces', { name: 'Other' })).json();
  assert.equal((await owner('POST', `/workspaces/${elsewhere.id}/invites`, { email: address() })).statusCode, 429, 'per inviter');
  const fresh = await owner('GET', `/workspaces/${ws.id}/invites`);
  assert.equal(fresh.json().length, 20, 'nothing stored past the limit');
  // Attempts that send nothing are answered as such, not counted.
  await pool.query('INSERT INTO user_emails (user_id, email) VALUES ($1, $2)', [await userId(admin), `${await userId(admin)}@example.com`]);
  assert.equal((await owner('POST', `/workspaces/${ws.id}/invites`, { email: `${await userId(admin)}@example.com` })).statusCode, 409);
  assert.equal((await owner('POST', `/workspaces/${ws.id}/invites/${randomUUID()}/resend`)).statusCode, 404);
  const limitedResend = await owner('POST', `/workspaces/${ws.id}/invites/${fresh.json()[0].id}/resend`);
  assert.equal(limitedResend.statusCode, 429);
});

test('dev mode without a mailer logs the link instead of sending it', async (t) => {
  const devApp = await buildApp({ pool, authMode: 'dev' });
  const token = (await devApp.inject({ method: 'POST', url: '/auth/dev-login', payload: { login: `u-${randomUUID().slice(0, 8)}` } })).json().token;
  const api = (method: 'GET' | 'POST', url: string, payload?: object) =>
    devApp.inject({ method, url, payload, headers: { authorization: `Bearer ${token}` } });
  const ws = (await api('POST', '/workspaces', { name: 'Acme' })).json();
  const info = t.mock.method(devApp.log, 'info');
  const email = address();
  assert.equal((await api('POST', `/workspaces/${ws.id}/invites`, { email })).statusCode, 201);
  const line = info.mock.calls.map((c) => String(c.arguments[0])).find((l) => l.includes(email))!;
  const link = /http:\/\/localhost:3000\/#\/invite\/(\S+)$/.exec(line);
  assert.ok(link, line);
  assert.ok(!mailer.sent.some((m) => m.to === email), 'nothing sent');
  assert.equal((await (await login())('POST', '/invites/accept', { token: link[1] })).statusCode, 200);
  await devApp.close();
});

test("invite tokens never reach the request log", async () => {
  const lines: string[] = [];
  const logged = await buildApp({ pool, authMode: 'dev', mailer, logger: { stream: { write: (line: string) => void lines.push(line) } } });
  const call = async (token: string, method: 'POST', url: string, payload?: object) =>
    logged.inject({ method, url, payload, headers: { authorization: `Bearer ${token}` } });
  const session = async () => (await logged.inject({ method: 'POST', url: '/auth/dev-login', payload: { login: `u-${randomUUID().slice(0, 8)}` } })).json().token;
  const [owner, invitee] = [await session(), await session()];
  const ws = (await call(owner, 'POST', '/workspaces', { name: 'Acme' })).json();
  const email = address();
  await call(owner, 'POST', `/workspaces/${ws.id}/invites`, { email });
  const token = tokenFor(email);
  assert.equal((await call(invitee, 'POST', '/invites/accept', { token })).statusCode, 200);
  await logged.close();
  assert.ok(lines.some((l) => l.includes('/invites/accept')), 'requests are logged');
  assert.ok(!lines.some((l) => l.includes(token)), 'the token is not');
});

test('a denial is remembered in the process: further checks answer 429 without touching the table', async () => {
  const name = `denied-${randomUUID()}`;
  const limit = rateLimit(pool, name, 2);
  const key = randomUUID();
  await limit(key);
  await limit(key);
  await assert.rejects(limit(key), (e: Error & { statusCode: number }) => e.statusCode === 429);
  await pool.query('DELETE FROM rate_limits WHERE limiter = $1', [name]);
  await assert.rejects(limit(key), (e: Error & { statusCode: number; headers: Record<string, string> }) =>
    e.statusCode === 429 && Number(e.headers['retry-after']) > 0, 'still refused with the row gone');
  const { rowCount } = await pool.query('SELECT 1 FROM rate_limits WHERE limiter = $1', [name]);
  assert.equal(rowCount, 0, 'and nothing was written');
  await limit(randomUUID()); // other keys still go to the table
});

test('two limiter instances on one database enforce one combined limit per key', async () => {
  // Two instances of the same limiter stand in for two API processes.
  const name = `shared-${randomUUID()}`;
  const a = rateLimit(pool, name, 5);
  const b = rateLimit(pool, name, 5);
  const key = randomUUID();
  for (let i = 0; i < 5; i++) await (i % 2 ? a : b)(key);
  for (const limiter of [a, b]) {
    await assert.rejects(limiter(key), (e: Error & { statusCode: number; headers: Record<string, string> }) =>
      e.statusCode === 429 && Number(e.headers['retry-after']) > 0 && /Too many requests; try again in \d+ s/.test(e.message));
  }
  await b(randomUUID()); // another key is unaffected
  await rateLimit(pool, `${name}-other`, 5)(key); // so is another limiter

  // A new window starts once the database clock passes reset_at.
  await pool.query(`UPDATE rate_limits SET reset_at = now() - interval '1 second' WHERE limiter = $1 AND key = $2`, [name, key]);
  await rateLimit(pool, name, 5)(key); // a process that hadn't seen the denial (one that had keeps refusing until its window ends)
  const { rows: [w] } = await pool.query('SELECT count FROM rate_limits WHERE limiter = $1 AND key = $2', [name, key]);
  assert.equal(w.count, 1);
});
