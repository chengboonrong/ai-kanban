import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { type Db, httpError, tx } from './db.ts';
import { waitingFor } from './refinement.ts';

const uuid = { type: 'string', format: 'uuid' } as const;
const idParams = { type: 'object', required: ['id'], properties: { id: uuid } } as const;
const text = (maxLength: number) => ({ type: 'string', minLength: 1, maxLength }) as const;
const body = (properties: Record<string, object>, required: string[] = []) =>
  ({ type: 'object', required, minProperties: 1, additionalProperties: false, properties }) as const;

const BOARD = `id, workspace_id AS "workspaceId", name, repository, created_at AS "createdAt"`;
const COLUMN = `id, board_id AS "boardId", name, position`;
const TASK = `id, board_id AS "boardId", column_id AS "columnId", title, description, position,
  created_by AS "createdBy", created_at AS "createdAt", updated_at AS "updatedAt"`;

export const REPOSITORY = { type: ['string', 'null'], pattern: '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$', maxLength: 140 } as const;

/** An agent_runs row as `user` (a query parameter such as '$2') sees it: the worker's name only if it is theirs (names leak hostnames). */
export const RUN = (user: string) => `id, task_id AS "taskId", repository, state, execution_target AS "executionTarget", worker_id AS "workerId",
  harness, model, session_id AS "sessionId", repository_commit_sha AS "commitSha", token_usage AS "tokenUsage", cost::float8 AS cost,
  error, attempt, retry_reason AS "retryReason", created_at AS "createdAt", started_at AS "startedAt", completed_at AS "completedAt",
  (SELECT w.name FROM workers w WHERE w.id = worker_id AND w.owner_id = ${user}) AS "workerName"`;

/** A github_issues row (alias gi) on a card: the issue once it exists, else where its creation stands. */
const ISSUE_JSON = `CASE gi.state
    WHEN 'created' THEN json_build_object('number', gi.number, 'url', gi.url, 'state', gi.issue_state)
    WHEN 'failed' THEN json_build_object('state', 'failed', 'error', gi.last_error)
    ELSE json_build_object('state', 'pending') END`;

const DEFAULT_COLUMNS = ['Backlog', 'Todo', 'In Progress', 'Done'];

type Id = { id: string };

/** Returns the user's role in the workspace; 404 when not a member (existence is not leaked). */
async function workspaceRole(db: Db, userId: string, workspaceId: string): Promise<string> {
  const { rows } = await db.query('SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2', [workspaceId, userId]);
  if (!rows[0]) throw httpError(404, 'workspace not found');
  return rows[0].role;
}

/** Resolves the board that owns a board/column/task the user can access; 404 otherwise. */
export async function boardFor(db: Db, userId: string, kind: 'board' | 'column' | 'task', id: string): Promise<string> {
  const [table, boardCol] = { board: ['boards', 'id'], column: ['columns', 'board_id'], task: ['tasks', 'board_id'] }[kind];
  const { rows } = await db.query(
    `SELECT b.id FROM ${table} x
     JOIN boards b ON b.id = x.${boardCol}
     JOIN workspace_members m ON m.workspace_id = b.workspace_id AND m.user_id = $2
     WHERE x.id = $1`,
    [id, userId],
  );
  if (!rows[0]) throw httpError(404, `${kind} not found`);
  return rows[0].id;
}

/** Serialises every ordering change on one board. Access was checked before the transaction, so re-check existence here. */
async function lockBoard(c: pg.PoolClient, boardId: string) {
  if (!(await c.query('SELECT 1 FROM boards WHERE id = $1 FOR UPDATE', [boardId])).rowCount) throw httpError(404, 'board not found');
}

/** Re-reads a row under the board lock: a concurrent request may have deleted it after the access check. */
async function lockedRow(c: pg.PoolClient, kind: 'column' | 'task', sql: string, id: string) {
  const { rows } = await c.query(sql, [id]);
  if (!rows[0]) throw httpError(404, `${kind} not found`);
  return rows[0];
}

// ponytail: dense integer positions renumbered under the board lock; fine for human-sized boards,
// switch to fractional ranks if boards reach thousands of cards.
async function move(
  c: pg.PoolClient,
  table: 'tasks' | 'columns',
  scope: 'column_id' | 'board_id',
  item: { id: string; scope: string; position: number },
  toScope: string,
  toPosition: number,
): Promise<number> {
  await c.query(`UPDATE ${table} SET position = position - 1 WHERE ${scope} = $1 AND position > $2`, [item.scope, item.position]);
  const { rows } = await c.query(`SELECT count(*)::int AS n FROM ${table} WHERE ${scope} = $1 AND id <> $2`, [toScope, item.id]);
  const position = Math.min(Math.max(toPosition, 0), rows[0].n);
  await c.query(`UPDATE ${table} SET position = position + 1 WHERE ${scope} = $1 AND position >= $2 AND id <> $3`, [
    toScope,
    position,
    item.id,
  ]);
  await c.query(`UPDATE ${table} SET ${scope} = $1, position = $2 WHERE id = $3`, [toScope, position, item.id]);
  return position;
}

async function loadBoard(db: Db, boardId: string) {
  const { rows: [board] } = await db.query(`SELECT ${BOARD} FROM boards WHERE id = $1`, [boardId]);
  const { rows: columns } = await db.query(`SELECT ${COLUMN} FROM columns WHERE board_id = $1 ORDER BY position`, [boardId]);
  // refinement: the card's AI state — an active run wins, then the latest spec's approval, then the last run's outcome.
  // github: the issue, how many PRs link to it, and for open ones the newest PR's review and the worst CI result.
  const { rows: tasks } = await db.query(
    `SELECT ${TASK},
       CASE WHEN r.state IN ('queued', 'running') THEN r.state
            WHEN s.approved_at IS NOT NULL THEN 'approved'
            WHEN r.state = 'failed' THEN 'failed'
            WHEN s.version IS NOT NULL THEN 'ready' END AS refinement,
       CASE WHEN g.issue IS NOT NULL THEN json_build_object('issue', g.issue, 'prs', p.n, 'review', p.review, 'ci', p.ci) END AS github
     FROM tasks t
     LEFT JOIN LATERAL (SELECT state FROM agent_runs WHERE task_id = t.id ORDER BY created_at DESC LIMIT 1) r ON true
     LEFT JOIN LATERAL (SELECT version, approved_at FROM specs WHERE task_id = t.id ORDER BY version DESC LIMIT 1) s ON true
     LEFT JOIN LATERAL (SELECT ${ISSUE_JSON} AS issue FROM github_issues gi WHERE gi.task_id = t.id) g ON true
     LEFT JOIN LATERAL (
       SELECT count(*)::int AS n,
         (array_agg(pr.review ORDER BY pr.github_updated_at DESC NULLS LAST) FILTER (WHERE pr.state = 'open'))[1] AS review,
         (array_agg(pr.ci ORDER BY array_position(ARRAY['failure', 'pending', 'success', 'none'], pr.ci)) FILTER (WHERE pr.state = 'open'))[1] AS ci
       FROM pull_request_tasks pt JOIN pull_requests pr ON pr.id = pt.pull_request_id WHERE pt.task_id = t.id) p ON true
     WHERE board_id = $1 ORDER BY position`,
    [boardId],
  );
  // One reason for the whole board: it depends only on the board's connector and repository, not on the card.
  const waiting = board?.repository && tasks.some((t) => t.refinement === 'queued') ? await waitingFor(db, boardId, board.repository) : null;
  return { ...board, waiting, columns: columns.map((col) => ({ ...col, tasks: tasks.filter((t) => t.columnId === col.id) })) };
}

export const logActivity = (db: Db, taskId: string, actorId: string, kind: string, data: object = {}) =>
  db.query('INSERT INTO task_activity (task_id, actor_id, kind, data) VALUES ($1, $2, $3, $4)', [taskId, actorId, kind, data]);

/** Queues a refinement unless one is already queued or running for the task; returns the active run either way. */
export async function enqueueRun(
  db: Db,
  taskId: string,
  userId: string,
  repository: string,
  retry?: { attempt: number; retryReason: string },
) {
  const { rows } = await db.query(
    `INSERT INTO agent_runs (task_id, requested_by, repository, attempt, retry_reason) VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (task_id) WHERE state IN ('queued', 'running') DO NOTHING RETURNING id`,
    [taskId, userId, repository, retry?.attempt ?? 1, retry?.retryReason ?? null],
  );
  if (rows[0] && retry) await logActivity(db, taskId, userId, 'refinement_retried', { reason: retry.retryReason, attempt: retry.attempt });
  else if (rows[0]) await logActivity(db, taskId, userId, 'refinement_requested');
  const { rows: [run] } = await db.query(`SELECT ${RUN('$2')} FROM agent_runs WHERE task_id = $1 AND state IN ('queued', 'running')`, [
    taskId,
    userId,
  ]);
  if (!run) return enqueueRun(db, taskId, userId, repository, retry); // the active run ended in between: queue a new one
  return { run, created: !!rows[0] };
}

const columnName = async (db: Db, id: string) => (await db.query('SELECT name FROM columns WHERE id = $1', [id])).rows[0]?.name;

export function registerRoutes(app: FastifyInstance, pool: pg.Pool) {
  // ---- Workspaces ----
  app.get('/workspaces', async (req) => {
    const { rows } = await pool.query(
      `SELECT w.id, w.name, w.created_at AS "createdAt", m.role,
         COALESCE(json_agg(json_build_object('id', b.id, 'name', b.name) ORDER BY b.created_at)
           FILTER (WHERE b.id IS NOT NULL), '[]') AS boards
       FROM workspaces w
       JOIN workspace_members m ON m.workspace_id = w.id AND m.user_id = $1
       LEFT JOIN boards b ON b.workspace_id = w.id
       GROUP BY w.id, m.role ORDER BY w.created_at`,
      [req.userId],
    );
    return rows;
  });

  app.post('/workspaces', { schema: { body: body({ name: text(200) }, ['name']) } }, async (req, reply) => {
    const { name } = req.body as { name: string };
    const ws = await tx(pool, async (c) => {
      const { rows: [w] } = await c.query('INSERT INTO workspaces (name) VALUES ($1) RETURNING id, name, created_at AS "createdAt"', [name]);
      await c.query(`INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'owner')`, [w.id, req.userId]);
      return { ...w, role: 'owner', boards: [] };
    });
    return reply.code(201).send(ws);
  });

  app.patch('/workspaces/:id', { schema: { params: idParams, body: body({ name: text(200) }, ['name']) } }, async (req) => {
    const { id } = req.params as Id;
    await workspaceRole(pool, req.userId, id);
    const { rows } = await pool.query('UPDATE workspaces SET name = $2 WHERE id = $1 RETURNING id, name, created_at AS "createdAt"', [
      id,
      (req.body as { name: string }).name,
    ]);
    return rows[0];
  });

  app.delete('/workspaces/:id', { schema: { params: idParams } }, async (req, reply) => {
    const { id } = req.params as Id;
    if ((await workspaceRole(pool, req.userId, id)) !== 'owner') throw httpError(403, 'only owners can delete a workspace');
    await tx(pool, async (c) => {
      // Boards before tasks, as expiring a run takes them; tasks in id order, as the GitHub sync locks them. Otherwise the cascade deadlocks with either.
      await c.query('SELECT 1 FROM boards WHERE workspace_id = $1 ORDER BY id FOR UPDATE', [id]);
      await c.query('SELECT 1 FROM tasks t JOIN boards b ON b.id = t.board_id WHERE b.workspace_id = $1 ORDER BY t.id FOR UPDATE OF t', [id]);
      await c.query('DELETE FROM workspaces WHERE id = $1', [id]);
    });
    return reply.code(204).send();
  });

  // ---- Boards ----
  app.post('/workspaces/:id/boards', { schema: { params: idParams, body: body({ name: text(200) }, ['name']) } }, async (req, reply) => {
    const { id } = req.params as Id;
    await workspaceRole(pool, req.userId, id);
    const board = await tx(pool, async (c) => {
      const { rows: [b] } = await c.query('INSERT INTO boards (workspace_id, name) VALUES ($1, $2) RETURNING id', [
        id,
        (req.body as { name: string }).name,
      ]);
      await c.query('INSERT INTO columns (board_id, name, position) SELECT $1, name, ord - 1 FROM unnest($2::text[]) WITH ORDINALITY AS t(name, ord)', [
        b.id,
        DEFAULT_COLUMNS,
      ]);
      return loadBoard(c, b.id);
    });
    return reply.code(201).send(board);
  });

  app.get('/boards/:id', { schema: { params: idParams } }, async (req) => {
    return loadBoard(pool, await boardFor(pool, req.userId, 'board', (req.params as Id).id));
  });

  app.patch('/boards/:id', { schema: { params: idParams, body: body({ name: text(200), repository: REPOSITORY }) } }, async (req) => {
    const boardId = await boardFor(pool, req.userId, 'board', (req.params as Id).id);
    const patch = req.body as { name?: string; repository?: string | null };
    const repository = patch.repository?.toLowerCase() ?? null; // GitHub names are case-insensitive
    return tx(pool, async (c) => {
      const { rows } = await c.query(
        `UPDATE boards SET name = COALESCE($2, name), repository = CASE WHEN $3 THEN $4 ELSE repository END,
           repository_connected_by = CASE WHEN $3 AND $4 IS DISTINCT FROM repository THEN $5 ELSE repository_connected_by END
         WHERE id = $1 RETURNING ${BOARD}`,
        [boardId, patch.name ?? null, 'repository' in patch, repository, repository && req.userId],
      );
      if (!rows[0]) throw httpError(404, 'board not found'); // deleted meanwhile
      // Queued runs must not go on to read a repository the board no longer points at.
      await c.query(
        `UPDATE agent_runs SET state = 'cancelled', completed_at = now()
         WHERE state = 'queued' AND repository IS DISTINCT FROM $2 AND task_id IN (SELECT id FROM tasks WHERE board_id = $1)`,
        [boardId, rows[0].repository],
      );
      // Likewise issues not yet filed: their spec describes the old repository.
      await c.query(
        `UPDATE github_issues SET state = 'failed', last_error = 'the board''s repository changed', updated_at = now()
         WHERE state = 'pending' AND repository IS DISTINCT FROM $2 AND task_id IN (SELECT id FROM tasks WHERE board_id = $1)`,
        [boardId, rows[0].repository],
      );
      return rows[0];
    });
  });

  app.delete('/boards/:id', { schema: { params: idParams } }, async (req, reply) => {
    const id = await boardFor(pool, req.userId, 'board', (req.params as Id).id);
    await tx(pool, async (c) => {
      await c.query('SELECT 1 FROM boards WHERE id = $1 FOR UPDATE', [id]); // as for workspaces above
      await c.query('SELECT 1 FROM tasks WHERE board_id = $1 ORDER BY id FOR UPDATE', [id]);
      await c.query('DELETE FROM boards WHERE id = $1', [id]);
    });
    return reply.code(204).send();
  });

  // ---- Columns ----
  app.post('/boards/:id/columns', { schema: { params: idParams, body: body({ name: text(100) }, ['name']) } }, async (req, reply) => {
    const boardId = await boardFor(pool, req.userId, 'board', (req.params as Id).id);
    const column = await tx(pool, async (c) => {
      await lockBoard(c, boardId);
      const { rows } = await c.query(
        `INSERT INTO columns (board_id, name, position)
         VALUES ($1, $2, (SELECT count(*) FROM columns WHERE board_id = $1)) RETURNING ${COLUMN}`,
        [boardId, (req.body as { name: string }).name],
      );
      return { ...rows[0], tasks: [] };
    });
    return reply.code(201).send(column);
  });

  app.patch(
    '/columns/:id',
    { schema: { params: idParams, body: body({ name: text(100), position: { type: 'integer', minimum: 0 } }) } },
    async (req) => {
      const { id } = req.params as Id;
      const { name, position } = req.body as { name?: string; position?: number };
      const boardId = await boardFor(pool, req.userId, 'column', id);
      return tx(pool, async (c) => {
        await lockBoard(c, boardId);
        const col = await lockedRow(c, 'column', 'SELECT position FROM columns WHERE id = $1', id);
        if (name !== undefined) await c.query('UPDATE columns SET name = $2 WHERE id = $1', [id, name]);
        if (position !== undefined) {
          await move(c, 'columns', 'board_id', { id, scope: boardId, position: col.position }, boardId, position);
        }
        return (await c.query(`SELECT ${COLUMN} FROM columns WHERE id = $1`, [id])).rows[0];
      });
    },
  );

  app.delete('/columns/:id', { schema: { params: idParams } }, async (req, reply) => {
    const { id } = req.params as Id;
    const boardId = await boardFor(pool, req.userId, 'column', id);
    await tx(pool, async (c) => {
      await lockBoard(c, boardId);
      await lockedRow(c, 'column', 'SELECT 1 FROM columns WHERE id = $1', id);
      if ((await c.query('SELECT 1 FROM tasks WHERE column_id = $1 LIMIT 1', [id])).rows[0]) {
        throw httpError(409, 'column still has tasks; move or delete them first');
      }
      const { rows: [col] } = await c.query('DELETE FROM columns WHERE id = $1 RETURNING position', [id]);
      await c.query('UPDATE columns SET position = position - 1 WHERE board_id = $1 AND position > $2', [boardId, col.position]);
    });
    return reply.code(204).send();
  });

  // ---- Tasks ----
  app.post(
    '/boards/:id/tasks',
    {
      schema: {
        params: idParams,
        headers: { type: 'object', properties: { 'idempotency-key': text(200) } },
        body: body({ title: text(500), description: { type: 'string', maxLength: 20000 }, columnId: uuid }, ['title']),
      },
    },
    async (req, reply) => {
      const boardId = await boardFor(pool, req.userId, 'board', (req.params as Id).id);
      const key = req.headers['idempotency-key'] as string | undefined;
      const { title, description = '', columnId } = req.body as { title: string; description?: string; columnId?: string };
      const result = await tx(pool, async (c) => {
        await lockBoard(c, boardId);
        if (key) {
          const { rows } = await c.query(`SELECT ${TASK} FROM tasks WHERE board_id = $1 AND idempotency_key = $2`, [boardId, key]);
          if (rows[0]) return { task: rows[0], created: false };
        }
        const { rows: [col] } = columnId
          ? await c.query('SELECT id FROM columns WHERE id = $1 AND board_id = $2', [columnId, boardId])
          : await c.query('SELECT id FROM columns WHERE board_id = $1 ORDER BY position LIMIT 1', [boardId]);
        if (!col) throw httpError(400, columnId ? 'columnId is not on this board' : 'board has no columns');
        const { rows: [task] } = await c.query(
          `INSERT INTO tasks (board_id, column_id, title, description, position, created_by, idempotency_key)
           VALUES ($1, $2, $3, $4, (SELECT count(*) FROM tasks WHERE column_id = $2), $5, $6) RETURNING ${TASK}`,
          [boardId, col.id, title, description, req.userId, key ?? null],
        );
        await logActivity(c, task.id, req.userId, 'created', { title, column: await columnName(c, col.id) });
        // refinement.auto_start: a board with a repository refines every new card.
        const { rows: [board] } = await c.query('SELECT repository FROM boards WHERE id = $1', [boardId]);
        if (board.repository) await enqueueRun(c, task.id, req.userId, board.repository);
        return { task, created: true };
      });
      return reply.code(result.created ? 201 : 200).send(result.task);
    },
  );

  app.get('/tasks/:id', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    await boardFor(pool, req.userId, 'task', id);
    const { rows: [task] } = await pool.query(`SELECT ${TASK} FROM tasks WHERE id = $1`, [id]);
    if (!task) throw httpError(404, 'task not found');
    const { rows: activity } = await pool.query(
      `SELECT a.id, a.kind, a.data, a.created_at AS "createdAt", u.display_name AS actor
       FROM task_activity a JOIN users u ON u.id = a.actor_id WHERE a.task_id = $1 ORDER BY a.id`,
      [id],
    );
    return { ...task, activity };
  });

  app.patch(
    '/tasks/:id',
    {
      schema: {
        params: idParams,
        body: body({
          title: text(500),
          description: { type: 'string', maxLength: 20000 },
          columnId: uuid,
          position: { type: 'integer', minimum: 0 },
        }),
      },
    },
    async (req) => {
      const { id } = req.params as Id;
      const patch = req.body as { title?: string; description?: string; columnId?: string; position?: number };
      const boardId = await boardFor(pool, req.userId, 'task', id);
      return tx(pool, async (c) => {
        await lockBoard(c, boardId);
        const task = await lockedRow(c, 'task', `SELECT ${TASK} FROM tasks WHERE id = $1`, id);

        const changes: Record<string, unknown> = {};
        if (patch.title !== undefined && patch.title !== task.title) changes.title = { from: task.title, to: patch.title };
        if (patch.description !== undefined && patch.description !== task.description) changes.description = true;
        if (Object.keys(changes).length) {
          await c.query('UPDATE tasks SET title = $2, description = $3 WHERE id = $1', [
            id,
            patch.title ?? task.title,
            patch.description ?? task.description,
          ]);
          await logActivity(c, id, req.userId, 'updated', changes);
        }

        const toColumn = patch.columnId ?? task.columnId;
        if (toColumn !== task.columnId || (patch.position !== undefined && patch.position !== task.position)) {
          if (toColumn !== task.columnId && !(await c.query('SELECT 1 FROM columns WHERE id = $1 AND board_id = $2', [toColumn, boardId])).rows[0]) {
            throw httpError(400, 'columnId is not on this board');
          }
          await move(c, 'tasks', 'column_id', { id, scope: task.columnId, position: task.position }, toColumn, patch.position ?? Number.MAX_SAFE_INTEGER);
          if (toColumn !== task.columnId) {
            await logActivity(c, id, req.userId, 'moved', { from: await columnName(c, task.columnId), to: await columnName(c, toColumn) });
          }
        }

        const { rows } = await c.query(`UPDATE tasks SET updated_at = now() WHERE id = $1 RETURNING ${TASK}`, [id]);
        return rows[0];
      });
    },
  );

  app.delete('/tasks/:id', { schema: { params: idParams } }, async (req, reply) => {
    const { id } = req.params as Id;
    const boardId = await boardFor(pool, req.userId, 'task', id);
    await tx(pool, async (c) => {
      await lockBoard(c, boardId);
      const t = await lockedRow(c, 'task', 'DELETE FROM tasks WHERE id = $1 RETURNING column_id, position', id);
      await c.query('UPDATE tasks SET position = position - 1 WHERE column_id = $1 AND position > $2', [t.column_id, t.position]);
    });
    return reply.code(204).send();
  });
}
