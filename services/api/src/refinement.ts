import type { FastifyInstance } from 'fastify';
import { randomBytes } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import type pg from 'pg';
import specSchema from '../../../packages/contracts/refined-spec.schema.json' with { type: 'json' };
import { httpError, sha256, tx } from './db.ts';
import { boardFor, enqueueRun, logActivity, REPOSITORY, RUN } from './routes.ts';
import { queueIssue } from './sync.ts';

const uuid = { type: 'string', format: 'uuid' } as const;
const idParams = { type: 'object', required: ['id'], properties: { id: uuid } } as const;
const SPEC = `id, task_id AS "taskId", run_id AS "runId", version, content, repository_commit_sha AS "commitSha",
  approved_at AS "approvedAt", created_at AS "createdAt"`;
const WORKER = `id, name, repositories, last_seen_at AS "lastSeenAt", created_at AS "createdAt"`;
const ACTIVE = `state IN ('queued', 'running')`;

type Id = { id: string };

export function registerRefinementRoutes(app: FastifyInstance, pool: pg.Pool) {
  // ---- Worker registration (as the signed-in user) ----
  app.post(
    '/workers',
    { schema: { body: { type: 'object', required: ['name'], additionalProperties: false, properties: { name: { type: 'string', minLength: 1, maxLength: 100 } } } } },
    async (req, reply) => {
      const token = `wkr_${randomBytes(32).toString('base64url')}`;
      const { rows } = await pool.query(`INSERT INTO workers (owner_id, name, token_hash) VALUES ($1, $2, $3) RETURNING ${WORKER}`, [
        req.userId,
        (req.body as { name: string }).name,
        sha256(token),
      ]);
      return reply.code(201).send({ ...rows[0], token }); // the only time the token is shown
    },
  );

  app.get('/workers', async (req) => (await pool.query(`SELECT ${WORKER} FROM workers WHERE owner_id = $1 ORDER BY created_at`, [req.userId])).rows);

  app.delete('/workers/:id', { schema: { params: idParams } }, async (req, reply) => {
    const { id } = req.params as Id;
    await tx(pool, async (c) => {
      const { rowCount } = await c.query('SELECT 1 FROM workers WHERE id = $1 AND owner_id = $2 FOR UPDATE', [id, req.userId]);
      if (!rowCount) throw httpError(404, 'worker not found');
      // Its runs would otherwise stay "running" with nobody working on them, blocking those tasks.
      await c.query(
        `UPDATE agent_runs SET state = 'failed', completed_at = now(), error = 'the worker running this was removed'
         WHERE worker_id = $1 AND state = 'running'`,
        [id],
      );
      await c.query('DELETE FROM workers WHERE id = $1', [id]);
    });
    return reply.code(204).send();
  });

  // ---- Runs and specs (as the signed-in user) ----
  app.post('/tasks/:id/runs', { schema: { params: idParams } }, async (req, reply) => {
    const { id } = req.params as Id;
    const boardId = await boardFor(pool, req.userId, 'task', id);
    const { run, created } = await tx(pool, async (c) => {
      // Locked so the repository can't change before the run is queued for it.
      const { rows: [board] } = await c.query('SELECT repository FROM boards WHERE id = $1 FOR SHARE', [boardId]);
      if (!board?.repository) throw httpError(409, 'Connect a repository to this board first');
      return enqueueRun(c, id, req.userId, board.repository);
    }).catch((e) => {
      throw e.code === '23503' ? httpError(404, 'task not found') : e; // deleted meanwhile
    });
    return reply.code(created ? 201 : 200).send(run);
  });

  app.get('/tasks/:id/refinement', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    await boardFor(pool, req.userId, 'task', id);
    const { rows: [run] } = await pool.query(`SELECT ${RUN} FROM agent_runs WHERE task_id = $1 ORDER BY created_at DESC LIMIT 1`, [id]);
    const { rows: [spec] } = await pool.query(`SELECT ${SPEC} FROM specs WHERE task_id = $1 ORDER BY version DESC LIMIT 1`, [id]);
    return { run: run ?? null, spec: spec ?? null };
  });

  app.post('/runs/:id/cancel', { schema: { params: idParams } }, async (req) => {
    const run = await runForUser(pool, req.userId, (req.params as Id).id);
    const { rows } = await pool.query(
      `UPDATE agent_runs SET state = 'cancelled', completed_at = now() WHERE id = $1 AND ${ACTIVE} RETURNING ${RUN}`,
      [run.id],
    );
    if (!rows[0]) {
      const { rows: [now] } = await pool.query('SELECT state FROM agent_runs WHERE id = $1', [run.id]);
      throw httpError(409, `run is already ${now?.state ?? 'gone'}`);
    }
    return rows[0];
  });

  // ponytail: long-poll (Dio can't stream responses on web) that re-queries every 500ms per waiting client;
  // switch to LISTEN/NOTIFY when many people watch runs at once.
  app.get(
    '/runs/:id/events',
    { schema: { params: idParams, querystring: { type: 'object', properties: { after: { type: 'integer', minimum: 0, default: 0 } } } } },
    async (req) => {
      const { id } = await runForUser(pool, req.userId, (req.params as Id).id);
      const { after } = req.query as { after: number };
      const deadline = Date.now() + 20_000;
      for (;;) {
        // State first: events written before a run ends are then always in this read or a later one.
        const { rows: [run] } = await pool.query('SELECT state FROM agent_runs WHERE id = $1', [id]);
        if (!run) throw httpError(404, 'run not found');
        const { rows: events } = await pool.query(
          `SELECT id::float8 AS id, kind, data, created_at AS "createdAt" FROM run_events WHERE run_id = $1 AND id > $2 ORDER BY id LIMIT 200`,
          [id, after],
        );
        const active = run.state === 'queued' || run.state === 'running';
        // A full page may not be the last one, so report the run as still going until the client has caught up.
        const state = events.length === 200 && !active ? 'running' : run.state;
        if (events.length || !active || Date.now() > deadline || req.raw.destroyed) return { state, events };
        await sleep(500);
      }
    },
  );

  app.post('/specs/:id/approve', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    const { rows: [found] } = await pool.query('SELECT task_id FROM specs WHERE id = $1', [id]);
    if (!found) throw httpError(404, 'spec not found');
    const boardId = await boardFor(pool, req.userId, 'task', found.task_id);
    return tx(pool, async (c) => {
      // Board before task, the order a task delete takes them in; the share lock keeps the repository put until the issue is queued.
      const { rows: [board] } = await c.query('SELECT repository FROM boards WHERE id = $1 FOR SHARE', [boardId]);
      await c.query('SELECT 1 FROM tasks WHERE id = $1 FOR UPDATE', [found.task_id]); // serialises with a new version landing
      const { rows: [spec] } = await c.query(`SELECT ${SPEC} FROM specs WHERE id = $1 FOR UPDATE`, [id]);
      if (!spec) throw httpError(404, 'spec not found');
      if (spec.approvedAt) return spec;
      const { rows: [latest] } = await c.query('SELECT max(version) AS v FROM specs WHERE task_id = $1', [spec.taskId]);
      if (latest.v !== spec.version) throw httpError(409, 'a newer version of this spec exists');
      // The spec describes the repository it was refined against; the issue must not land anywhere else.
      const { rows: [run] } = await c.query('SELECT repository FROM agent_runs WHERE id = $1', [spec.runId]);
      if (board.repository !== run.repository) {
        throw httpError(409, `the board now points at ${board.repository ?? 'no repository'}; refine again`);
      }
      const { rows } = await c.query(`UPDATE specs SET approved_by = $2, approved_at = now() WHERE id = $1 RETURNING ${SPEC}`, [id, req.userId]);
      await logActivity(c, spec.taskId, req.userId, 'spec_approved', { version: spec.version });
      await queueIssue(c, spec.taskId, run.repository);
      return rows[0];
    });
  });

  // ---- Worker protocol (worker token) ----
  const worker = { worker: true };

  app.post(
    '/worker/claim',
    {
      config: worker,
      schema: {
        body: {
          type: 'object',
          required: ['repositories'],
          additionalProperties: false,
          properties: { repositories: { type: 'array', maxItems: 200, items: { ...REPOSITORY, type: 'string' } } },
        },
      },
    },
    async (req, reply) => {
      const repositories = (req.body as { repositories: string[] }).repositories.map((r) => r.toLowerCase());
      await pool.query('UPDATE workers SET repositories = $2 WHERE id = $1', [req.workerId, repositories]);
      // Only runs on boards whose owner connected the repository and can still see the board, for repositories this
      // worker has checked out. Another member can't point a board at a repo and have someone else's worker read it.
      // The repository check also drops a run queued just as the board was pointed elsewhere.
      // ponytail: per-person workers; shared team workers need workspace opt-in plus GitHub access checks (Milestones 4-5).
      const { rows: [run] } = await pool.query(
        `UPDATE agent_runs SET state = 'running', worker_id = $1, started_at = now()
         WHERE id = (
           SELECT r.id FROM agent_runs r
           JOIN tasks t ON t.id = r.task_id
           JOIN boards b ON b.id = t.board_id
           JOIN workspace_members m ON m.workspace_id = b.workspace_id AND m.user_id = $2
           WHERE r.state = 'queued' AND b.repository_connected_by = $2 AND b.repository = r.repository AND r.repository = ANY($3)
           ORDER BY r.created_at LIMIT 1 FOR UPDATE OF r SKIP LOCKED)
         RETURNING id, task_id, repository`,
        [req.workerId, req.userId, repositories],
      );
      if (!run) return reply.code(204).send();
      const { rows: [task] } = await pool.query('SELECT title, description FROM tasks WHERE id = $1', [run.task_id]);
      return { id: run.id, repository: run.repository, task };
    },
  );

  app.post(
    '/worker/runs/:id/events',
    {
      config: worker,
      schema: {
        params: idParams,
        body: {
          type: 'object',
          required: ['events'],
          additionalProperties: false,
          properties: {
            events: {
              type: 'array',
              maxItems: 100, // an empty batch is a heartbeat
              items: {
                type: 'object',
                required: ['kind'],
                additionalProperties: false,
                properties: { kind: { type: 'string', pattern: '^[a-z_]{1,40}$' }, data: { type: 'object' } },
              },
            },
          },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params as Id;
      const { events } = req.body as { events: { kind: string; data?: object }[] };
      // 409 tells the worker to stop: the run was cancelled or isn't its own.
      await tx(pool, async (c) => {
        await activeRunForWorker(c, id, req.workerId);
        await c.query(
          `INSERT INTO run_events (run_id, kind, data)
           SELECT $1, e.kind, COALESCE(e.data, '{}') FROM jsonb_to_recordset($2::jsonb) AS e(kind text, data jsonb)`,
          [id, JSON.stringify(events)],
        );
      });
      return reply.code(204).send();
    },
  );

  const finish = {
    model: { type: 'string', maxLength: 200 },
    sessionId: { type: 'string', maxLength: 200 },
    commitSha: { type: 'string', pattern: '^[0-9a-f]{40,64}$' },
  };

  app.post(
    '/worker/runs/:id/complete',
    {
      config: worker,
      schema: {
        params: idParams,
        body: {
          type: 'object',
          required: ['model', 'commitSha', 'spec'],
          additionalProperties: false,
          properties: { ...finish, tokenUsage: { type: 'object' }, cost: { type: 'number', minimum: 0 }, spec: specSchema },
        },
      },
    },
    async (req) => {
      const { id } = req.params as Id;
      const b = req.body as { model: string; sessionId?: string; commitSha: string; tokenUsage?: object; cost?: number; spec: object };
      return tx(pool, async (c) => {
        // Task before run, the same order a task delete takes them in; also serialises with approve.
        await c.query('SELECT 1 FROM tasks WHERE id = (SELECT task_id FROM agent_runs WHERE id = $1) FOR UPDATE', [id]);
        const run = await activeRunForWorker(c, id, req.workerId);
        const { rows: [spec] } = await c.query(
          `INSERT INTO specs (task_id, run_id, version, content, repository_commit_sha)
           VALUES ($1, $2, (SELECT COALESCE(max(version), 0) + 1 FROM specs WHERE task_id = $1), $3, $4) RETURNING ${SPEC}`,
          [run.task_id, id, b.spec, b.commitSha],
        );
        await c.query(
          `UPDATE agent_runs SET state = 'succeeded', completed_at = now(), model = $2, session_id = $3, repository_commit_sha = $4,
             token_usage = $5, cost = $6 WHERE id = $1`,
          [id, b.model, b.sessionId ?? null, b.commitSha, b.tokenUsage ?? null, b.cost ?? null],
        );
        await logActivity(c, run.task_id, run.requested_by, 'spec_ready', { version: spec.version });
        return spec;
      });
    },
  );

  app.post(
    '/worker/runs/:id/fail',
    {
      config: worker,
      schema: {
        params: idParams,
        body: {
          type: 'object',
          required: ['error'],
          additionalProperties: false,
          properties: { ...finish, error: { type: 'string', minLength: 1, maxLength: 2000 } },
        },
      },
    },
    async (req, reply) => {
      const { id } = req.params as Id;
      const b = req.body as { error: string; model?: string; sessionId?: string; commitSha?: string };
      await tx(pool, async (c) => {
        // Task before run, the same order a task delete takes them in.
        await c.query('SELECT 1 FROM tasks WHERE id = (SELECT task_id FROM agent_runs WHERE id = $1) FOR UPDATE', [id]);
        const run = await activeRunForWorker(c, id, req.workerId);
        await c.query(
          `UPDATE agent_runs SET state = 'failed', completed_at = now(), error = $2, model = $3, session_id = $4, repository_commit_sha = $5
           WHERE id = $1`,
          [id, b.error, b.model ?? null, b.sessionId ?? null, b.commitSha ?? null],
        );
        await logActivity(c, run.task_id, run.requested_by, 'refinement_failed', { error: b.error });
      });
      return reply.code(204).send();
    },
  );
}

async function runForUser(db: pg.Pool, userId: string, runId: string) {
  const { rows: [run] } = await db.query('SELECT id, task_id, state FROM agent_runs WHERE id = $1', [runId]);
  if (!run) throw httpError(404, 'run not found');
  await boardFor(db, userId, 'task', run.task_id).catch(() => {
    throw httpError(404, 'run not found');
  });
  return run as { id: string; task_id: string; state: string };
}

/** Locks a run this worker is executing; 409 once it was cancelled, finished, or belongs to another worker. */
async function activeRunForWorker(c: pg.PoolClient, runId: string, workerId: string) {
  const { rows: [run] } = await c.query('SELECT task_id, requested_by FROM agent_runs WHERE id = $1 AND worker_id = $2 AND state = $3 FOR UPDATE', [
    runId,
    workerId,
    'running',
  ]);
  if (!run) throw httpError(409, 'run is not running on this worker');
  return run as { task_id: string; requested_by: string };
}
