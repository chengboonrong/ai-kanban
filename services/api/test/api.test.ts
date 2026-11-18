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
