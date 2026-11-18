import type { FastifyInstance } from 'fastify';
import type pg from 'pg';
import { type Db, httpError, tx } from './db.ts';

const uuid = { type: 'string', format: 'uuid' } as const;
const idParams = { type: 'object', required: ['id'], properties: { id: uuid } } as const;
const text = (maxLength: number) => ({ type: 'string', minLength: 1, maxLength }) as const;
const body = (properties: Record<string, object>, required: string[] = []) =>
  ({ type: 'object', required, minProperties: 1, additionalProperties: false, properties }) as const;

const BOARD = `id, workspace_id AS "workspaceId", name, created_at AS "createdAt"`;
const COLUMN = `id, board_id AS "boardId", name, position`;
const TASK = `id, board_id AS "boardId", column_id AS "columnId", title, description, position,
  created_by AS "createdBy", created_at AS "createdAt", updated_at AS "updatedAt"`;

const DEFAULT_COLUMNS = ['Backlog', 'Todo', 'In Progress', 'Done'];

type Id = { id: string };

/** Returns the user's role in the workspace; 404 when not a member (existence is not leaked). */
async function workspaceRole(db: Db, userId: string, workspaceId: string): Promise<string> {
  const { rows } = await db.query('SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2', [workspaceId, userId]);
  if (!rows[0]) throw httpError(404, 'workspace not found');
  return rows[0].role;
}

/** Resolves the board that owns a board/column/task the user can access; 404 otherwise. */
async function boardFor(db: Db, userId: string, kind: 'board' | 'column' | 'task', id: string): Promise<string> {
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

/** Serialises every ordering change on one board. */
const lockBoard = (c: pg.PoolClient, boardId: string) => c.query('SELECT 1 FROM boards WHERE id = $1 FOR UPDATE', [boardId]);

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
  const { rows: tasks } = await db.query(`SELECT ${TASK} FROM tasks WHERE board_id = $1 ORDER BY position`, [boardId]);
  return { ...board, columns: columns.map((col) => ({ ...col, tasks: tasks.filter((t) => t.columnId === col.id) })) };
}

const logActivity = (db: Db, taskId: string, actorId: string, kind: string, data: object = {}) =>
  db.query('INSERT INTO task_activity (task_id, actor_id, kind, data) VALUES ($1, $2, $3, $4)', [taskId, actorId, kind, data]);

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
    await pool.query('DELETE FROM workspaces WHERE id = $1', [id]);
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

  app.patch('/boards/:id', { schema: { params: idParams, body: body({ name: text(200) }, ['name']) } }, async (req) => {
    const boardId = await boardFor(pool, req.userId, 'board', (req.params as Id).id);
    const { rows } = await pool.query(`UPDATE boards SET name = $2 WHERE id = $1 RETURNING ${BOARD}`, [boardId, (req.body as { name: string }).name]);
    return rows[0];
  });

  app.delete('/boards/:id', { schema: { params: idParams } }, async (req, reply) => {
    await pool.query('DELETE FROM boards WHERE id = $1', [await boardFor(pool, req.userId, 'board', (req.params as Id).id)]);
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
        if (name !== undefined) await c.query('UPDATE columns SET name = $2 WHERE id = $1', [id, name]);
        if (position !== undefined) {
          const { rows: [col] } = await c.query('SELECT position FROM columns WHERE id = $1', [id]);
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
        return { task, created: true };
      });
      return reply.code(result.created ? 201 : 200).send(result.task);
    },
  );

  app.get('/tasks/:id', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    await boardFor(pool, req.userId, 'task', id);
    const { rows: [task] } = await pool.query(`SELECT ${TASK} FROM tasks WHERE id = $1`, [id]);
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
        const { rows: [task] } = await c.query(`SELECT ${TASK} FROM tasks WHERE id = $1`, [id]);

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
      const { rows: [t] } = await c.query('DELETE FROM tasks WHERE id = $1 RETURNING column_id, position', [id]);
      await c.query('UPDATE tasks SET position = position - 1 WHERE column_id = $1 AND position > $2', [t.column_id, t.position]);
    });
    return reply.code(204).send();
  });
}
