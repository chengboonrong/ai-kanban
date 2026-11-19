import type { FastifyBaseLogger, FastifyInstance } from 'fastify';
import { randomBytes } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import type pg from 'pg';
import specSchema from '../../../packages/contracts/refined-spec.schema.json' with { type: 'json' };
import { type Db, httpError, sha256, tx } from './db.ts';
import { boardFor, enqueueRun, type Feedback, logActivity, REPOSITORY, RUN } from './routes.ts';
import { queueComment, queueIssue } from './sync.ts';

const uuid = { type: 'string', format: 'uuid' } as const;
const idParams = { type: 'object', required: ['id'], properties: { id: uuid } } as const;
const SPEC = `id, task_id AS "taskId", run_id AS "runId", version, content, repository_commit_sha AS "commitSha",
  approved_at AS "approvedAt", created_at AS "createdAt"`;
const WORKER = `id, name, repositories, last_seen_at AS "lastSeenAt", created_at AS "createdAt"`;
const ACTIVE = `state IN ('queued', 'running')`;
/** Renewed by every event batch, never past 20 minutes from the start: then the sweeper times the run out. */
const LEASE = `LEAST(now() + interval '90 seconds', started_at + interval '20 minutes')`;
const ONLINE = `last_seen_at > now() - interval '30 seconds'`;
const CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Crockford base32
/** Uppercase, no separators, and the letters people mistake for digits read as those digits. */
const normaliseCode = (code: string) => code.toUpperCase().replace(/[-\s]/g, '').replace(/[IL]/g, '1').replace(/O/g, '0');

/**
 * Each task's newest approved spec version ($1 = the worker's owner), with the content; the caller adds filters
 * (starting with AND) and `ORDER BY s.task_id, s.version DESC` so DISTINCT ON keeps the newest.
 */
const APPROVED_SPECS = `SELECT DISTINCT ON (s.task_id) s.task_id AS "taskId", t.title, b.name AS board, lower(b.repository) AS repository,
    s.version, s.approved_at AS "approvedAt",
    CASE WHEN gi.state = 'created' THEN json_build_object('number', gi.number, 'url', gi.url, 'state', gi.issue_state) END AS issue,
    s.content, s.repository_commit_sha AS "commitSha"
  FROM specs s
  JOIN tasks t ON t.id = s.task_id
  JOIN boards b ON b.id = t.board_id
  JOIN workspace_members m ON m.workspace_id = b.workspace_id AND m.user_id = $1
  LEFT JOIN github_issues gi ON gi.task_id = t.id
  WHERE s.approved_at IS NOT NULL AND b.repository IS NOT NULL`;

type Id = { id: string };

/** Optional: comments on the latest spec version for the Refiner to address; at least a general note or one item. */
const runBody = {
  type: 'object',
  additionalProperties: false,
  properties: {
    feedback: {
      type: 'object',
      required: ['specVersion'],
      additionalProperties: false,
      anyOf: [{ required: ['general'] }, { required: ['items'] }],
      properties: {
        specVersion: { type: 'integer', minimum: 1 },
        general: { type: 'string', minLength: 1, maxLength: 4000 },
        items: {
          type: 'array',
          minItems: 1,
          maxItems: 50,
          items: {
            type: 'object',
            required: ['section', 'index', 'comment'],
            additionalProperties: false,
            properties: {
              section: { enum: ['summary', 'requirements', 'acceptanceCriteria', 'ambiguities', 'approach', 'evidence'] },
              index: { type: 'integer', minimum: 0 },
              comment: { type: 'string', minLength: 1, maxLength: 2000 },
            },
          },
        },
      },
    },
  },
} as const;

export function registerRefinementRoutes(app: FastifyInstance, pool: pg.Pool) {
  // ---- Worker pairing: the signed-in user gets a code, `connect` on their machine trades it for a token ----
  app.post('/workers/pairing', async (req, reply) => {
    const code = Array.from(randomBytes(10), (b) => CODE_ALPHABET[b & 31]).join('');
    const { rows } = await tx(pool, async (c) => {
      await c.query('DELETE FROM worker_pairings WHERE owner_id = $1 AND (used_at IS NOT NULL OR expires_at <= now())', [req.userId]);
      const inserted = await c.query(
        `INSERT INTO worker_pairings (code_hash, owner_id, expires_at) VALUES ($1, $2, now() + interval '10 minutes') RETURNING expires_at AS "expiresAt"`,
        [sha256(code), req.userId],
      );
      await c.query(
        `DELETE FROM worker_pairings WHERE owner_id = $1 AND code_hash NOT IN (
           SELECT code_hash FROM worker_pairings WHERE owner_id = $1 ORDER BY created_at DESC LIMIT 5)`,
        [req.userId],
      );
      return inserted;
    });
    return reply.code(201).send({ code: `${code.slice(0, 5)}-${code.slice(5)}`, expiresAt: rows[0].expiresAt });
  });

  // ponytail: no attempt limiter (50-bit codes, 10 minutes, at most 5 open per user); add one before the API is public.
  app.post(
    '/workers/pair',
    {
      config: { public: true },
      schema: {
        body: {
          type: 'object',
          required: ['code', 'name'],
          additionalProperties: false,
          properties: { code: { type: 'string', maxLength: 40 }, name: { type: 'string', minLength: 1, maxLength: 100 } },
        },
      },
    },
    async (req, reply) => {
      const { code, name } = req.body as { code: string; name: string };
      const token = `wkr_${randomBytes(32).toString('base64url')}`;
      const paired = await tx(pool, async (c) => {
        const { rows: [pairing] } = await c.query(
          'UPDATE worker_pairings SET used_at = now() WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING owner_id',
          [sha256(normaliseCode(code))],
        );
        if (!pairing) throw httpError(400, 'invalid or expired code');
        const { rows } = await c.query(`INSERT INTO workers (owner_id, name, token_hash) VALUES ($1, $2, $3) RETURNING ${WORKER}, owner_id AS "ownerId"`, [
          pairing.owner_id,
          name,
          sha256(token),
        ]);
        return rows[0];
      });
      return reply.code(201).send({ ...paired, token }); // the only time the token is shown
    },
  );

  // busy: running a job; online: seen in the last 30 s (every worker call counts).
  app.get('/workers', async (req) => {
    const { rows } = await pool.query(
      `SELECT ${WORKER}, CASE WHEN cur.task IS NOT NULL THEN 'busy' WHEN ${ONLINE} THEN 'online' ELSE 'offline' END AS state,
         cur.task AS "currentTask"
       FROM workers w
       LEFT JOIN LATERAL (
         SELECT json_build_object('id', t.id, 'title', t.title) AS task
         FROM agent_runs r JOIN tasks t ON t.id = r.task_id WHERE r.worker_id = w.id AND r.state = 'running' LIMIT 1) cur ON true
       WHERE owner_id = $1 ORDER BY created_at`,
      [req.userId],
    );
    return rows;
  });

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
  app.post(
    '/tasks/:id/runs',
    {
      schema: { params: idParams, body: runBody },
      // A bare POST, as before comments existed, asks for a plain refinement; the schema needs an object to check.
      preValidation: async (req) => {
        req.body ??= {};
      },
    },
    async (req, reply) => {
      const { id } = req.params as Id;
      const { feedback } = req.body as { feedback?: Feedback };
      const boardId = await boardFor(pool, req.userId, 'task', id);
      const { run, created } = await tx(pool, async (c) => {
        // Locked so the repository can't change before the run is queued for it.
        const { rows: [board] } = await c.query('SELECT repository FROM boards WHERE id = $1 FOR SHARE', [boardId]);
        if (!board?.repository) throw httpError(409, 'Connect a repository to this board first');
        if (feedback) {
          // Board before task, as approve takes them; the task lock keeps a new version from landing until the run is queued.
          if (!(await c.query('SELECT 1 FROM tasks WHERE id = $1 FOR UPDATE', [id])).rowCount) throw httpError(404, 'task not found');
          const { rows: [latest] } = await c.query('SELECT version, content FROM specs WHERE task_id = $1 ORDER BY version DESC LIMIT 1', [id]);
          if (latest?.version !== feedback.specVersion) throw httpError(409, 'the comments are not on the latest version of this spec');
          for (const { section, index } of feedback.items ?? []) {
            const items = section === 'summary' ? 1 : latest.content[section].length;
            if (index >= items) throw httpError(400, `the spec has no ${section} item ${index}`);
          }
        }
        const queued = await enqueueRun(c, id, req.userId, board.repository, { feedback });
        // Returning the active run would drop the comments without a word.
        if (feedback && !queued.created) throw httpError(409, 'a refinement is already running; cancel it first');
        return queued;
      }).catch((e) => {
        throw e.code === '23503' ? httpError(404, 'task not found') : e; // deleted meanwhile
      });
      return reply.code(created ? 201 : 200).send(run);
    },
  );

  app.get('/tasks/:id/refinement', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    const boardId = await boardFor(pool, req.userId, 'task', id);
    const { rows: [run] } = await pool.query(`SELECT ${RUN('$2')} FROM agent_runs WHERE task_id = $1 ORDER BY created_at DESC LIMIT 1`, [
      id,
      req.userId,
    ]);
    const { rows: [spec] } = await pool.query(`SELECT ${SPEC} FROM specs WHERE task_id = $1 ORDER BY version DESC LIMIT 1`, [id]);
    return { run: run ?? null, spec: spec ?? null, waiting: run?.state === 'queued' ? await waitingFor(pool, boardId, run.repository) : null };
  });

  app.post('/runs/:id/cancel', { schema: { params: idParams } }, async (req) => {
    const run = await runForUser(pool, req.userId, (req.params as Id).id);
    const { rows } = await pool.query(
      `UPDATE agent_runs SET state = 'cancelled', completed_at = now() WHERE id = $1 AND ${ACTIVE} RETURNING ${RUN('$2')}`,
      [run.id, req.userId],
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
      // An imported issue is GitHub's (someone else wrote it): the spec goes on it as a comment, never as a second issue.
      const { rows: [issue] } = await c.query('SELECT origin FROM github_issues WHERE task_id = $1', [spec.taskId]);
      if (issue?.origin === 'imported') await queueComment(c, spec.taskId, spec.version);
      else await queueIssue(c, spec.taskId, run.repository);
      return rows[0];
    });
  });

  // ---- Worker protocol (worker token) ----
  const worker = { worker: true };

  app.get('/worker/me', { config: worker }, async (req) => (await pool.query('SELECT id, name, owner_id AS "ownerId" FROM workers WHERE id = $1', [req.workerId])).rows[0]);

  app.post(
    '/worker/claim',
    {
      config: worker,
      schema: {
        body: {
          type: 'object',
          required: ['repositories'],
          additionalProperties: false,
          properties: {
            repositories: { type: 'array', maxItems: 200, items: { ...REPOSITORY, type: 'string' } },
            harness: { enum: ['opencode', 'claude-code'] }, // which agent this worker refines with, shown while it runs
          },
        },
      },
    },
    async (req, reply) => {
      const { harness = 'opencode' } = req.body as { harness?: string };
      const repositories = (req.body as { repositories: string[] }).repositories.map((r) => r.toLowerCase());
      await pool.query('UPDATE workers SET repositories = $2 WHERE id = $1', [req.workerId, repositories]);
      // A worker runs one job at a time, so a run still running on it was lost in a crash: retry it now, not after the lease.
      const { rows: stale } = await pool.query(`SELECT id FROM agent_runs WHERE worker_id = $1 AND state = 'running'`, [req.workerId]);
      for (const { id } of stale) await expireRun(pool, id, 'the worker restarted', { retry: true, workerId: req.workerId });
      // Only runs on boards whose owner connected the repository and can still see the board, for repositories this
      // worker has checked out. Another member can't point a board at a repo and have someone else's worker read it.
      // The repository check also drops a run queued just as the board was pointed elsewhere.
      // ponytail: per-person workers; shared team workers need workspace opt-in plus GitHub access checks (Milestones 4-5).
      const { rows: [run] } = await pool.query(
        `UPDATE agent_runs SET state = 'running', worker_id = $1, started_at = now(), lease_until = now() + interval '90 seconds', harness = $4
         WHERE id = (
           SELECT r.id FROM agent_runs r
           JOIN tasks t ON t.id = r.task_id
           JOIN boards b ON b.id = t.board_id
           JOIN workspace_members m ON m.workspace_id = b.workspace_id AND m.user_id = $2
           WHERE r.state = 'queued' AND b.repository_connected_by = $2 AND b.repository = r.repository AND r.repository = ANY($3)
           ORDER BY r.created_at LIMIT 1 FOR UPDATE OF r SKIP LOCKED)
         RETURNING id, task_id, repository, feedback`,
        [req.workerId, req.userId, repositories, harness],
      );
      if (!run) return reply.code(204).send();
      const { rows: [task] } = await pool.query('SELECT title, description FROM tasks WHERE id = $1', [run.task_id]);
      if (!run.feedback) return { id: run.id, repository: run.repository, task, feedback: null };
      // The comments quote items of this version, so the Refiner gets it to revise.
      const { rows: [previous] } = await pool.query('SELECT content FROM specs WHERE task_id = $1 AND version = $2', [
        run.task_id,
        run.feedback.specVersion,
      ]);
      return { id: run.id, repository: run.repository, task, feedback: run.feedback, previousSpec: previous?.content };
    },
  );

  // Approved specs for the worker's own coding agent (its MCP server). Scope is the owner's, as for a signed-in call: boards
  // of workspaces they belong to. Only a person's approval makes a spec readable here; a draft never is.
  app.get(
    '/worker/specs',
    {
      config: worker,
      schema: { querystring: { type: 'object', properties: { repository: { type: 'array', maxItems: 200, items: { ...REPOSITORY, type: 'string' } } } } },
    },
    async (req) => {
      const { repository } = req.query as { repository?: string[] };
      const { rows } = await pool.query(
        `SELECT "taskId", title, board, repository, version, "approvedAt", issue FROM (${APPROVED_SPECS} ${
          repository ? 'AND lower(b.repository) = ANY($2)' : ''
        } ORDER BY s.task_id, s.version DESC) latest ORDER BY "approvedAt" DESC LIMIT 100`,
        repository ? [req.userId, repository.map((r) => r.toLowerCase())] : [req.userId],
      );
      return rows;
    },
  );

  app.get('/worker/specs/:taskId', { config: worker, schema: { params: { type: 'object', required: ['taskId'], properties: { taskId: uuid } } } }, async (req) => {
    const { rows: [found] } = await pool.query(`${APPROVED_SPECS} AND s.task_id = $2 ORDER BY s.task_id, s.version DESC`, [
      req.userId,
      (req.params as { taskId: string }).taskId,
    ]);
    if (!found) throw httpError(404, 'no approved spec for this task'); // also when it is outside the owner's boards
    return found;
  });

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
          properties: {
            ...finish,
            tokenUsage: { type: 'object' },
            cost: { type: 'number', minimum: 0 },
            spec: specSchema,
          },
        },
      },
    },
    async (req) => {
      const { id } = req.params as Id;
      const b = req.body as { model: string; sessionId?: string; commitSha: string; tokenUsage?: object; cost?: number; spec: object };
      return tx(pool, async (c) => {
        // Task before run, the same order a task delete takes them in; also serialises with approve.
        await c.query('SELECT 1 FROM tasks WHERE id = (SELECT task_id FROM agent_runs WHERE id = $1) FOR UPDATE', [id]);
        // Already handed in by this worker: a retry after the answer was lost gets the same spec, not a 409.
        const { rows: [handedIn] } = await c.query(
          `SELECT ${SPEC} FROM specs WHERE run_id = $1 AND EXISTS (SELECT 1 FROM agent_runs WHERE id = $1 AND worker_id = $2 AND state = 'succeeded')`,
          [id, req.workerId],
        );
        if (handedIn) return handedIn;
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

  // The worker is shutting down (SIGTERM): hand the run back for a retry instead of waiting for its lease to lapse.
  app.post('/worker/runs/:id/release', { config: worker, schema: { params: idParams } }, async (req, reply) => {
    const released = await expireRun(pool, (req.params as Id).id, 'the worker was stopped', { retry: true, workerId: req.workerId });
    if (!released) throw httpError(409, 'run is not running on this worker');
    return reply.code(204).send();
  });
}

/**
 * Why the board's queued runs aren't being picked up, judged from the workers of whoever connected its repository.
 * no_connector: that account is gone (the column is SET NULL), so no worker can ever claim them.
 */
export async function waitingFor(db: Db, boardId: string, repository: string) {
  const { rows: [w] } = await db.query(
    `SELECT u.login AS connector, CASE
         WHEN b.repository_connected_by IS NULL THEN 'no_connector'
         WHEN NOT COALESCE(bool_or(w.online), false) THEN 'no_worker_online'
         WHEN NOT bool_or(w.online AND w.listed) THEN 'repository_not_listed'
         WHEN NOT bool_or(w.online AND w.listed AND NOT w.busy) THEN 'busy' END AS reason
     FROM boards b
     LEFT JOIN users u ON u.id = b.repository_connected_by
     LEFT JOIN LATERAL (
       SELECT ${ONLINE} AS online, $2 = ANY(repositories) AS listed,
         EXISTS (SELECT 1 FROM agent_runs r WHERE r.worker_id = x.id AND r.state = 'running') AS busy
       FROM workers x WHERE x.owner_id = b.repository_connected_by) w ON true
     WHERE b.id = $1 GROUP BY u.login, b.repository_connected_by`,
    [boardId, repository],
  );
  return w?.reason ? { reason: w.reason, connector: w.connector } : null;
}

/**
 * The one place the system fails a running run: lease lapsed (sweeper), worker stopped (release) or restarted (claim).
 * Locks board (share) → task → run, the order deletes and approve take them in. False if it wasn't running (or
 * wasn't this worker's, or its lease was renewed meanwhile).
 */
export async function expireRun(pool: pg.Pool, runId: string, reason: string, opts: { retry: boolean; workerId?: string; lapsed?: boolean }) {
  return tx(pool, async (c) => {
    // The share lock keeps the board on its repository until a retry is queued for it.
    const { rows: [board] } = await c.query(
      `SELECT repository FROM boards WHERE id = (SELECT t.board_id FROM agent_runs r JOIN tasks t ON t.id = r.task_id WHERE r.id = $1) FOR SHARE`,
      [runId],
    );
    if (!board) return false; // the run or its task is gone
    await c.query('SELECT 1 FROM tasks WHERE id = (SELECT task_id FROM agent_runs WHERE id = $1) FOR UPDATE', [runId]);
    const { rows: [run] } = await c.query(
      `UPDATE agent_runs SET state = 'failed', completed_at = now(), error = $2
       WHERE id = $1 AND state = 'running' AND ($3::uuid IS NULL OR worker_id = $3) AND (NOT $4 OR lease_until < now())
       RETURNING id, task_id, requested_by, repository, attempt, feedback`,
      [runId, reason, opts.workerId ?? null, opts.lapsed ?? false],
    );
    if (!run) return false;
    if (!(opts.retry && (await retryRun(c, run, board.repository, reason)))) {
      const { rows: [failed] } = await c.query('SELECT error FROM agent_runs WHERE id = $1', [run.id]);
      await logActivity(c, run.task_id, run.requested_by, 'refinement_failed', { error: failed.error });
    }
    return true;
  });
}

/** Queues the next attempt (true), unless the board moved to another repository since (the run must not read that one) or this was the third. */
async function retryRun(
  c: pg.PoolClient,
  run: { id: string; task_id: string; requested_by: string; repository: string; attempt: number; feedback: Feedback | null },
  boardRepository: string | null,
  reason: string,
) {
  if (boardRepository !== run.repository) return false;
  if (run.attempt >= 3) {
    await c.query('UPDATE agent_runs SET error = $2 WHERE id = $1', [run.id, `gave up after 3 attempts: ${reason}`]);
    return false;
  }
  // The same comments: the next attempt revises the same version for the same reviewer.
  const retry = { attempt: run.attempt + 1, retryReason: reason };
  await enqueueRun(c, run.task_id, run.requested_by, run.repository, { retry, feedback: run.feedback });
  return true;
}

/** One pass over runs whose lease lapsed; returns how many it looked at (at most 20). */
export async function sweepRuns(pool: pg.Pool, log: FastifyBaseLogger) {
  const { rows } = await pool.query(
    `SELECT id, started_at + interval '20 minutes' <= now() AS capped FROM agent_runs WHERE state = 'running' AND lease_until < now() LIMIT 20`,
  );
  for (const { id, capped } of rows) {
    try {
      if (capped) await expireRun(pool, id, 'timed out after 20 minutes', { retry: false, lapsed: true });
      else await expireRun(pool, id, 'the worker stopped responding', { retry: true, lapsed: true });
    } catch (err) {
      log.error(err, `expiring run ${id} failed`); // the next pass tries again
    }
  }
  return rows.length;
}

/** Every 15 s; the first pass waits a full lease so workers that were up before an API restart can renew theirs. */
export function startRunSweeper({ pool, log }: { pool: pg.Pool; log: FastifyBaseLogger }) {
  let timer: NodeJS.Timeout | undefined;
  let stopped = false;
  const tick = async () => {
    await sweepRuns(pool, log).catch((e) => log.error(e, 'run sweep failed'));
    if (!stopped) timer = setTimeout(tick, 15_000);
  };
  timer = setTimeout(tick, 90_000);
  return () => {
    stopped = true;
    clearTimeout(timer);
  };
}

async function runForUser(db: pg.Pool, userId: string, runId: string) {
  const { rows: [run] } = await db.query('SELECT id, task_id, state FROM agent_runs WHERE id = $1', [runId]);
  if (!run) throw httpError(404, 'run not found');
  await boardFor(db, userId, 'task', run.task_id).catch(() => {
    throw httpError(404, 'run not found');
  });
  return run as { id: string; task_id: string; state: string };
}

/** Locks a run this worker is executing and renews its lease; 409 once it was cancelled, finished, or belongs to another worker. */
async function activeRunForWorker(c: pg.PoolClient, runId: string, workerId: string) {
  const { rows: [run] } = await c.query(
    `UPDATE agent_runs SET lease_until = ${LEASE} WHERE id = $1 AND worker_id = $2 AND state = 'running' RETURNING task_id, requested_by`,
    [runId, workerId],
  );
  if (!run) throw httpError(409, 'run is not running on this worker');
  return run as { task_id: string; requested_by: string };
}
