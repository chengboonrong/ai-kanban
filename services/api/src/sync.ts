import Fastify, { type FastifyBaseLogger, type FastifyInstance, type FastifyReply } from 'fastify';
import type pg from 'pg';
import { type Db, httpError, tx } from './db.ts';
import { type GitHubClient, type GitHubConfig, GitHubError, validSignature } from './github.ts';
import { addTask, boardFor, logActivity } from './routes.ts';

const idParams = { type: 'object', required: ['id'], properties: { id: { type: 'string', format: 'uuid' } } } as const;
type Id = { id: string };

// ---- Queueing (inside the caller's transaction) ----

/** Queues the task's issue; a failed one is queued again (for `repository`), anything else is left as it is. */
export async function queueIssue(db: Db, taskId: string, repository: string) {
  await db.query(
    `INSERT INTO github_issues (task_id, repository) VALUES ($1, $2)
     ON CONFLICT (task_id) DO UPDATE SET state = 'pending', repository = EXCLUDED.repository, next_attempt_at = now(),
       last_error = NULL, updated_at = now()
     WHERE github_issues.state = 'failed'`,
    [taskId, repository],
  );
}

/**
 * Queues the spec comment on an imported task's issue, for `version`. attempts and the lease stay as they are: attempts
 * fences every write, and an attempt still in flight keeps its lease, so the next one starts after it and edits (or
 * adopts) what it posted instead of posting beside it.
 */
export async function queueComment(db: Db, taskId: string, version: number) {
  await db.query(
    `INSERT INTO github_comments (task_id, version) VALUES ($1, $2)
     ON CONFLICT (task_id) DO UPDATE SET version = EXCLUDED.version, state = 'pending', next_attempt_at = now(), last_error = NULL,
       updated_at = now()`,
    [taskId, version],
  );
}

/** The task page's view: unlike the card, the issue says where creation stands (state) apart from GitHub's issueState. */
async function githubOf(db: Db, taskId: string) {
  const { rows: [row] } = await db.query(
    `SELECT CASE state
       WHEN 'created' THEN json_build_object('state', 'created', 'number', number, 'url', url, 'issueState', issue_state, 'origin', origin)
       WHEN 'failed' THEN json_build_object('state', 'failed', 'error', last_error)
       ELSE json_build_object('state', 'pending') END AS issue
     FROM github_issues WHERE task_id = $1`,
    [taskId],
  );
  const { rows: prs } = await db.query(
    `SELECT p.number, p.title, p.url, p.author, p.state, p.draft, p.review, p.ci, p.github_updated_at AS "updatedAt", p.repository
     FROM pull_request_tasks pt JOIN pull_requests p ON p.id = pt.pull_request_id
     WHERE pt.task_id = $1 ORDER BY p.github_updated_at DESC NULLS LAST, p.number DESC`,
    [taskId],
  );
  const { rows: [comment] } = await db.query(
    `SELECT state, version, url, CASE WHEN state = 'failed' THEN last_error END AS error FROM github_comments WHERE task_id = $1`,
    [taskId],
  );
  return { issue: row?.issue ?? null, comment: comment ?? null, prs };
}

/** For each issue number already on a card (filed or imported): that card's task id if `userId` can see its board, else null. */
async function linkedTasks(db: Db, repositoryId: number, numbers: number[], userId: string) {
  const { rows } = await db.query(
    `SELECT gi.number, CASE WHEN m.user_id IS NOT NULL THEN gi.task_id END AS "taskId"
     FROM github_issues gi JOIN tasks t ON t.id = gi.task_id JOIN boards b ON b.id = t.board_id
     LEFT JOIN workspace_members m ON m.workspace_id = b.workspace_id AND m.user_id = $3
     WHERE gi.repository_id = $1 AND gi.number = ANY($2::int[])`,
    [repositoryId, numbers, userId],
  );
  return new Map<number, string | null>(rows.map((r) => [r.number, r.taskId]));
}

async function boardRepository(db: Db, boardId: string): Promise<string> {
  const { rows: [board] } = await db.query('SELECT repository FROM boards WHERE id = $1', [boardId]);
  if (!board?.repository) throw httpError(409, 'Connect a repository to this board first');
  return board.repository;
}

const notConfigured = (reply: FastifyReply) =>
  reply.code(503).send({ statusCode: 503, error: 'Service Unavailable', message: 'GitHub sync is not configured' });

/**
 * A GitHub failure as the answer: its message names a repository or a status, never a credential. Sent rather than
 * thrown, as the app's error handler hides the message of any 5xx it catches.
 */
export function gitHubFailed(reply: FastifyReply, e: unknown) {
  if (!(e instanceof GitHubError)) throw e;
  const statusCode = e.retryable ? 503 : 502;
  return reply.code(statusCode).send({ statusCode, error: e.retryable ? 'Service Unavailable' : 'Bad Gateway', message: e.message });
}

/**
 * AUTH_MODE=github: the user may act on `repository` through the app only with write (or admin) access on GitHub, asked
 * with the installation's token, so no user token is kept. Call it before any transaction: it calls GitHub.
 */
export async function requireWriteAccess(pool: pg.Pool, gh: GitHubClient, userId: string, repository: string) {
  const { rows: [user] } = await pool.query('SELECT login, github_id FROM users WHERE id = $1', [userId]);
  // One answer for both, so it doesn't tell which repositories have the app.
  const denied = httpError(403, `You need write access to ${repository} on GitHub, with the GitHub App installed there`);
  if (!user?.github_id) throw denied; // a dev account
  await gh.app(repository).catch((e) => {
    throw e instanceof GitHubError && e.status === 404 ? denied : e; // the app isn't installed there
  });
  const access = await gh
    .request<{ permission: string; user?: { id: number } }>(repository, 'GET', `/repos/${repository}/collaborators/${encodeURIComponent(user.login)}/permission`)
    .catch((e) => {
      if (e instanceof GitHubError && e.status === 404) return undefined;
      throw e;
    });
  // maintain reads as write here; a login renamed on GitHub may belong to someone else now, so the id must match too.
  if (!access || String(access.user?.id) !== user.github_id || !['admin', 'write'].includes(access.permission)) throw denied;
}

const PER_PAGE = 50;
const importBody = {
  type: 'object',
  required: ['number'],
  additionalProperties: false,
  properties: { number: { type: 'integer', minimum: 1, maximum: 2147483647 } },
} as const;
/** At most n UTF-16 units, without splitting a surrogate pair. */
const cap = (s: string, n: number) => s.slice(0, n).replace(/[\uD800-\uDBFF]$/, '');

export function registerGitHubRoutes(app: FastifyInstance, pool: pg.Pool, gh?: GitHubClient) {
  app.get('/tasks/:id/github', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    await boardFor(pool, req.userId, 'task', id);
    return githubOf(pool, id);
  });

  app.post('/tasks/:id/github/retry', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    const boardId = await boardFor(pool, req.userId, 'task', id);
    const { rows: [latest] } = await pool.query(
      `SELECT r.repository FROM specs s JOIN agent_runs r ON r.id = s.run_id
       WHERE s.task_id = $1 AND s.approved_at IS NOT NULL ORDER BY s.version DESC LIMIT 1`,
      [id],
    );
    if (latest) await app.requireWrite(req.userId, latest.repository);
    await tx(pool, async (c) => {
      // Same lock order as approval: board (repository held still), then task.
      const { rows: [board] } = await c.query('SELECT repository FROM boards WHERE id = $1 FOR SHARE', [boardId]);
      if (!(await c.query('SELECT 1 FROM tasks WHERE id = $1 FOR UPDATE', [id])).rowCount) throw httpError(404, 'task not found');
      const { rows: [issue] } = await c.query('SELECT state FROM github_issues WHERE task_id = $1', [id]);
      if (issue?.state === 'created') throw httpError(409, 'the issue already exists');
      if (issue && issue.state !== 'failed') return; // already queued
      const { rows: [spec] } = await c.query(
        `SELECT r.repository FROM specs s JOIN agent_runs r ON r.id = s.run_id
         WHERE s.task_id = $1 AND s.approved_at IS NOT NULL ORDER BY s.version DESC LIMIT 1`,
        [id],
      );
      if (!spec) throw httpError(409, 'approve a spec first');
      if (spec.repository !== latest?.repository) throw httpError(409, 'a newer spec was approved meanwhile; try again'); // not the one checked
      if (board.repository !== spec.repository) {
        throw httpError(409, `the board now points at ${board.repository ?? 'no repository'}; refine again`);
      }
      await queueIssue(c, id, spec.repository);
    });
    return githubOf(pool, id);
  });

  app.post('/tasks/:id/github/comment/retry', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    await boardFor(pool, req.userId, 'task', id);
    // The comment goes on the imported issue, in its repository.
    const { rows: [issue] } = await pool.query('SELECT repository FROM github_issues WHERE task_id = $1', [id]);
    if (issue) await app.requireWrite(req.userId, issue.repository);
    // Only a failed comment is queued again; attempts are kept, as they fence a straggling attempt.
    const { rowCount } = await pool.query(
      `UPDATE github_comments SET state = 'pending', next_attempt_at = now(), last_error = NULL, updated_at = now()
       WHERE task_id = $1 AND state = 'failed'`,
      [id],
    );
    if (!rowCount) {
      const { rows: [comment] } = await pool.query('SELECT state FROM github_comments WHERE task_id = $1', [id]);
      if (!comment) throw httpError(409, 'there is no spec comment to post; approve a spec first');
      if (comment.state === 'posted') throw httpError(409, 'the comment is already posted');
    }
    return githubOf(pool, id);
  });

  // ---- Importing open issues as cards ----

  app.get(
    '/boards/:id/github/issues',
    { schema: { params: idParams, querystring: { type: 'object', properties: { page: { type: 'integer', minimum: 1, maximum: 1000, default: 1 } } } } },
    async (req, reply) => {
      if (!gh) return notConfigured(reply);
      const boardId = await boardFor(pool, req.userId, 'board', (req.params as Id).id);
      const { page } = req.query as { page: number };
      const repository = await boardRepository(pool, boardId);
      await app.requireWrite(req.userId, repository);
      let repo: { id: number }, listed: Issue[];
      try {
        repo = await gh.request<{ id: number }>(repository, 'GET', `/repos/${repository}`);
        listed = await gh.request<Issue[]>(
          repository,
          'GET',
          `/repos/${repository}/issues?state=open&sort=updated&direction=desc&per_page=${PER_PAGE}&page=${page}`,
        );
      } catch (e) {
        return gitHubFailed(reply, e);
      }
      const issues = listed.filter((i) => !i.pull_request); // the issues API lists pull requests too
      const linked = await linkedTasks(pool, repo.id, issues.map((i) => i.number), req.userId);
      return {
        issues: issues.map((i) => ({
          number: i.number,
          title: i.title,
          url: i.html_url,
          author: i.user?.login ?? null,
          updatedAt: i.updated_at,
          onBoard: linked.has(i.number),
          taskId: linked.get(i.number) ?? null,
        })),
        more: listed.length === PER_PAGE, // a full page (pull requests included) may not be the last
      };
    },
  );

  app.post('/boards/:id/github/import', { schema: { params: idParams, body: importBody } }, async (req, reply) => {
    if (!gh) return notConfigured(reply);
    const boardId = await boardFor(pool, req.userId, 'board', (req.params as Id).id);
    const { number } = req.body as { number: number };
    const repository = await boardRepository(pool, boardId);
    await app.requireWrite(req.userId, repository);
    let repo: { id: number }, issue: Issue | undefined;
    try {
      // Reading the repository first surfaces a missing installation, so a 404 below means the issue.
      repo = await gh.request<{ id: number }>(repository, 'GET', `/repos/${repository}`);
      issue = await gh.request<Issue>(repository, 'GET', `/repos/${repository}/issues/${number}`).catch((e) => {
        if (e instanceof GitHubError && (e.status === 404 || e.status === 410)) return undefined; // never existed, or deleted
        throw e;
      });
    } catch (e) {
      return gitHubFailed(reply, e);
    }
    // A transferred issue redirects to its new repository, which isn't this board's.
    if (!issue?.repository_url?.toLowerCase().endsWith(`/repos/${repository}`)) throw httpError(404, `issue #${number} not found in ${repository}`);
    if (issue.pull_request) throw httpError(400, `#${number} is a pull request, not an issue`);
    // An issue this app filed is a card's already; anyone can paste the marker, so only the app's own counts.
    if (issue.body?.includes(MARKER) && byApp(issue, await gh.app(repository))) {
      throw httpError(409, `#${number} was filed by AI Kanban; it is already a card`);
    }
    const found = issue;
    const taken = new Error('the issue is already on a board');
    try {
      const task = await tx(pool, async (c) => {
        // The board lock any new card takes; under it the repository must still be the one the issue was read from.
        const { rows: [board] } = await c.query('SELECT repository FROM boards WHERE id = $1 FOR UPDATE', [boardId]);
        if (!board) throw httpError(404, 'board not found');
        if (board.repository !== repository) throw httpError(409, `the board now points at ${board.repository ?? 'no repository'}; import again`);
        // The issue's text is data: it becomes the card's brief and, through it, the Refiner's.
        const task = await addTask(c, boardId, req.userId, {
          title: cap(found.title, 500).trim() || `Issue #${number}`,
          description: cap(found.body ?? '', 20_000),
        });
        // One card per issue across every board, filed or imported; a concurrent import of it waits here for the other to end.
        const { rowCount } = await c.query(
          `INSERT INTO github_issues (task_id, repository, repository_id, state, origin, number, node_id, url, issue_state, issue_updated_at)
           VALUES ($1, $2, $3, 'created', 'imported', $4, $5, $6, $7, $8) ON CONFLICT (repository_id, number) DO NOTHING`,
          [task.id, repository, repo.id, found.number, found.node_id, found.html_url, found.state, found.updated_at],
        );
        if (!rowCount) throw taken; // rolls the card back
        await logActivity(c, task.id, req.userId, 'github_issue_imported', { number: found.number, url: found.html_url });
        return task;
      });
      return reply.code(201).send(task);
    } catch (e) {
      if (e !== taken) throw e;
    }
    const taskId = (await linkedTasks(pool, repo.id, [number], req.userId)).get(number) ?? null;
    return reply.code(409).send({ statusCode: 409, error: 'Conflict', message: `#${number} is already on a board`, taskId });
  });
}

// ---- Issue body ----

interface Spec {
  title: string;
  summary: string;
  requirements: string[];
  acceptanceCriteria: string[];
  evidence: { path: string; startLine: number; endLine: number; note: string }[];
  ambiguities: string[];
  approach: string[];
  readiness: number;
}

const MAX_BODY = 60_000;
const TRUNCATED = '\n\n_Truncated; the full spec is in AI Kanban._';
const MARKER = '<!-- ai-kanban:task:';
const marker = (taskId: string) => `${MARKER}${taskId} -->`;
const specMarker = (taskId: string) => `<!-- ai-kanban:spec:${taskId} -->`;
/** Spec text is data: it must not mention (notify) people or open an HTML comment that hides the rest. */
// owner/repo#N would also post a cross-reference on another repository's issue.
const inert = (s: string) => s.replaceAll('@', '@​').replaceAll('<!--', '&lt;!--').replace(/([\w.-]+\/[\w.-]+)#(?=\d)/g, '$1#\u200B');
const section = (heading: string, lines: string[]) => (lines.length ? `\n\n## ${heading}\n\n${lines.join('\n')}` : '');

/** The spec as Markdown after `head`: the marker first (adoption looks for it), then for a comment its heading. */
export function issueBody(head: string, spec: Spec) {
  const body =
    `${head}\n\n${inert(spec.summary)}` +
    section('Requirements', spec.requirements.map((r) => `- ${inert(r)}`)) +
    section('Acceptance criteria', spec.acceptanceCriteria.map((a) => `- [ ] ${inert(a)}`)) +
    section('Evidence', spec.evidence.map((e) => `- \`${e.path.replace(/\s+/g, ' ').replaceAll('`', '')}\` lines ${e.startLine}–${e.endLine}: ${inert(e.note)}`)) +
    section('Suggested approach', spec.approach.map((a) => `1. ${inert(a)}`)) +
    section('Open questions', spec.ambiguities.map((q) => `- ${inert(q)}`)) +
    `\n\n_Readiness ${spec.readiness}/100. Filed by AI Kanban._`;
  if (body.length <= MAX_BODY) return body;
  return body.slice(0, MAX_BODY - TRUNCATED.length).replace(/[\uD800-\uDBFF]$/, '') + TRUNCATED; // don't split a surrogate pair
}

// ---- Sync loop ----

// Longer than any one GitHub call chain (a create with its token refresh and 401 retry: at most 6 requests of 20 s).
const LEASE = `now() + interval '5 minutes'`;
/** Seconds until the next try: doubling from a minute, at most an hour, never sooner than GitHub asked. */
const backoff = (attempts: number, e: GitHubError) => Math.min(3600, Math.max(60 * 2 ** Math.max(0, attempts - 1), (e.retryAfter ?? 0) / 1000));
const asGitHubError = (e: unknown) => (e instanceof GitHubError ? e : new GitHubError(0, (e as Error).message, true));

/** Starts the background loop; returns stop(). */
export function startGitHubSync({ pool, gh, log }: { pool: pg.Pool; gh: GitHubClient; log: FastifyBaseLogger }) {
  let timer: NodeJS.Timeout | undefined;
  let stopped = false;
  const tick = async () => {
    await syncOnce(pool, gh).catch((e) => log.error(e, 'GitHub sync pass failed'));
    if (!stopped) timer = setTimeout(tick, 5_000);
  };
  void tick();
  return () => {
    stopped = true;
    clearTimeout(timer);
  };
}

/** One pass: file due issues, post due spec comments, reconcile dirty pull requests, prune old delivery ids. */
export async function syncOnce(pool: pg.Pool, gh: GitHubClient) {
  // A queued issue whose board moved to another repository since approval is never filed.
  await pool.query(
    `UPDATE github_issues gi SET state = 'failed', last_error = 'the board''s repository changed', locked_until = NULL, updated_at = now()
     FROM tasks t JOIN boards b ON b.id = t.board_id
     WHERE t.id = gi.task_id AND gi.state IN ('pending', 'creating') AND (gi.locked_until IS NULL OR gi.locked_until < now())
       AND b.repository IS DISTINCT FROM gi.repository`,
  );
  for (let job; (job = await claimIssue(pool)); ) await createIssue(pool, gh, job);
  for (let job; (job = await claimComment(pool)); ) await postComment(pool, gh, job);
  const seen: string[] = []; // each PR once per pass, so a PR that keeps getting bumped can't hold the loop
  for (let pr; (pr = await claimPullRequest(pool, seen)); seen.push(pr.id)) await reconcile(pool, gh, pr);
  await pool.query(`DELETE FROM github_deliveries WHERE received_at < now() - interval '30 days'`);
}

type IssueJob = { task_id: string; repository: string; attempts: number; created_at: Date };

/** Leases one due issue in a statement of its own; the lease (attempts) is what later writes check. */
async function claimIssue(pool: pg.Pool): Promise<IssueJob | undefined> {
  const { rows } = await pool.query(
    `UPDATE github_issues SET state = 'creating', attempts = attempts + 1, locked_until = ${LEASE}, updated_at = now()
     WHERE task_id = (
       SELECT gi.task_id FROM github_issues gi
       JOIN tasks t ON t.id = gi.task_id
       JOIN boards b ON b.id = t.board_id AND b.repository = gi.repository
       WHERE gi.state IN ('pending', 'creating') AND gi.next_attempt_at <= now() AND (gi.locked_until IS NULL OR gi.locked_until < now())
       ORDER BY gi.next_attempt_at LIMIT 1 FOR UPDATE OF gi SKIP LOCKED)
     RETURNING task_id, repository, attempts, created_at`,
  );
  return rows[0];
}

type Issue = {
  number: number;
  node_id: string;
  html_url: string;
  repository_url: string;
  state: 'open' | 'closed';
  title: string;
  body?: string | null;
  created_at: string;
  updated_at: string;
  pull_request?: object;
  performed_via_github_app?: { id: number } | null;
  user?: { login: string } | null;
};

async function createIssue(pool: pg.Pool, gh: GitHubClient, job: IssueJob) {
  const ours = [job.task_id, job.attempts];
  const { repository } = job;
  try {
    const { rows: [spec] } = await pool.query(
      `SELECT s.content, s.approved_by FROM specs s JOIN agent_runs r ON r.id = s.run_id
       WHERE s.task_id = $1 AND s.approved_at IS NOT NULL AND r.repository = $2 ORDER BY s.version DESC LIMIT 1`,
      [job.task_id, repository],
    );
    if (!spec) throw new GitHubError(0, 'there is no approved spec to file', false);
    const repo = await gh.request<{ id: number }>(repository, 'GET', `/repos/${repository}`);
    // An earlier attempt may have created the issue and lost the response: look for it before creating another.
    let issue = job.attempts > 1 ? await findOwnIssue(gh, job) : undefined;
    if (!issue) {
      // Renew the lease just before creating, so the create always ends inside it and nobody can claim the row meanwhile.
      // attempts is the fencing token: unchanged means nobody claimed it since, even if the lease lapsed while we looked.
      const { rowCount } = await pool.query(
        `UPDATE github_issues gi SET locked_until = ${LEASE} FROM tasks t JOIN boards b ON b.id = t.board_id
         WHERE gi.task_id = $1 AND gi.attempts = $2 AND gi.state = 'creating' AND t.id = gi.task_id AND b.repository = gi.repository`,
        ours,
      );
      if (!rowCount) return; // someone else claimed it (and adopts or creates), or the board moved (the next pass fails it)
      issue = await gh.request<Issue>(repository, 'POST', `/repos/${repository}/issues`, {
        title: (spec.content as Spec).title,
        body: issueBody(marker(job.task_id), spec.content),
      });
    }
    const created = issue;
    await tx(pool, async (c) => {
      await c.query('SELECT 1 FROM tasks WHERE id = $1 FOR KEY SHARE', [job.task_id]); // lock order of task delete: task first
      const { rowCount } = await c.query(
        `UPDATE github_issues SET state = 'created', number = $3, node_id = $4, url = $5, repository_id = $6, issue_state = $7,
           locked_until = NULL, last_error = NULL, updated_at = now()
         WHERE task_id = $1 AND attempts = $2 AND state = 'creating'`,
        [...ours, created.number, created.node_id, created.html_url, repo.id, created.state],
      );
      if (rowCount) await logActivity(c, job.task_id, spec.approved_by, 'github_issue_created', { number: created.number, url: created.html_url });
    });
  } catch (err) {
    const e = asGitHubError(err);
    await pool.query(
      `UPDATE github_issues SET state = $3, last_error = $4, locked_until = NULL, updated_at = now(),
         next_attempt_at = now() + make_interval(secs => $5)
       WHERE task_id = $1 AND attempts = $2 AND state = 'creating'`,
      [...ours, e.retryable ? 'pending' : 'failed', e.retryable ? e.message : failure(e, repository), backoff(job.attempts, e)],
    );
  }
}

function failure(e: GitHubError, repository: string, what: 'issue' | 'comment' = 'issue') {
  if (e.status === 403) return `the GitHub App isn't allowed to ${what === 'issue' ? 'create issues' : 'comment on issues'} in ${repository} (${e.message})`;
  if (e.status === 410) return what === 'issue' ? `issues are disabled in ${repository}` : `the issue was deleted, or issues are disabled in ${repository}`;
  if (e.status === 422) return `GitHub rejected the ${what} (${e.message})`;
  return e.message;
}

/** Whether the app created it: GitHub sets performed_via_github_app, or at least the author `<slug>[bot]`. */
const byApp = (x: Issue | Comment, app: { id: number; slug: string }) =>
  x.performed_via_github_app?.id === app.id || x.user?.login === `${app.slug}[bot]`;

/** The issue an earlier attempt created: newest first, back to an hour before the row was queued. */
// ponytail: pages through every issue since then; fine while retries are minutes apart, switch to the search API
// (marker in:body) if a row can stay unfiled for weeks in a busy repository.
async function findOwnIssue(gh: GitHubClient, job: IssueJob) {
  const app = await gh.app(job.repository);
  const since = job.created_at.getTime() - 3_600_000;
  const query = `state=all&sort=created&direction=desc&per_page=100&since=${new Date(since).toISOString()}`;
  for (let page = 1; ; page++) {
    const issues = await gh.request<Issue[]>(job.repository, 'GET', `/repos/${job.repository}/issues?${query}&page=${page}`);
    for (const issue of issues) {
      if (Date.parse(issue.created_at) < since) return undefined;
      // Anyone can paste the marker; only an issue this app created counts.
      if (!issue.pull_request && issue.body?.includes(marker(job.task_id)) && byApp(issue, app)) return issue;
    }
    if (issues.length < 100) return undefined;
  }
}

// An imported issue is someone else's: its approved spec goes on it as one comment, edited when a newer version is
// approved. The same queue, lease and fence as filing an issue.

type CommentJob = { task_id: string; version: number; comment_id: string | null; attempts: number; created_at: Date; repository: string; number: number };

/** Leases one due comment in a statement of its own, with the issue it goes on. */
async function claimComment(pool: pg.Pool): Promise<CommentJob | undefined> {
  const { rows } = await pool.query(
    `UPDATE github_comments gc SET state = 'posting', attempts = gc.attempts + 1, locked_until = ${LEASE}, updated_at = now()
     FROM github_issues gi
     WHERE gi.task_id = gc.task_id AND gc.task_id = (
       SELECT task_id FROM github_comments
       WHERE state IN ('pending', 'posting') AND next_attempt_at <= now() AND (locked_until IS NULL OR locked_until < now())
       ORDER BY next_attempt_at LIMIT 1 FOR UPDATE SKIP LOCKED)
     RETURNING gc.task_id, gc.version, gc.comment_id, gc.attempts, gc.created_at, gi.repository, gi.number`,
  );
  return rows[0];
}

type Comment = { id: number; html_url: string; body?: string | null; performed_via_github_app?: { id: number } | null; user?: { login: string } | null };

async function postComment(pool: pg.Pool, gh: GitHubClient, job: CommentJob) {
  const ours = [job.task_id, job.attempts];
  const { repository } = job; // the imported issue's
  try {
    const { rows: [spec] } = await pool.query(
      `SELECT s.content, s.approved_by, r.repository FROM specs s JOIN agent_runs r ON r.id = s.run_id
       WHERE s.task_id = $1 AND s.version = $2 AND s.approved_at IS NOT NULL`,
      [job.task_id, job.version],
    );
    if (!spec) throw new GitHubError(0, `spec version ${job.version} isn't approved`, false);
    // The board may point elsewhere since the import; a spec of another repository doesn't belong on this issue.
    if (spec.repository !== repository) {
      throw new GitHubError(0, `spec version ${job.version} describes ${spec.repository}, not ${repository} where the issue is`, false);
    }
    const body = issueBody(`${specMarker(job.task_id)}\n\n## AI Kanban spec (version ${job.version})`, spec.content);
    // An earlier attempt may have posted it and lost the response: look for it before posting another.
    const found = !job.comment_id && job.attempts > 1 ? await findOwnComment(gh, job) : undefined;
    let comment = found?.body === body ? found : undefined; // already says what it should
    if (!comment) {
      // Renewed just before writing, fenced by attempts, as for issues. A newer version approved meanwhile also stops
      // this attempt (state is pending again); the next one, once this lease lapses, writes that version.
      const renew = async () =>
        (await pool.query(`UPDATE github_comments SET locked_until = ${LEASE} WHERE task_id = $1 AND attempts = $2 AND state = 'posting'`, ours)).rowCount;
      if (!(await renew())) return;
      const path = `/repos/${repository}/issues`;
      const edit = (id: string | number) =>
        gh.request<Comment>(repository, 'PATCH', `${path}/comments/${id}`, { body }).catch((e) => {
          if (e instanceof GitHubError && e.status === 404) return undefined; // deleted on GitHub
          throw e;
        });
      const id = job.comment_id ?? found?.id;
      comment = id ? await edit(id) : undefined;
      if (id && !comment) {
        // Someone deleted it. An earlier attempt may have posted it again and lost the answer: adopt that one instead.
        const again = await findOwnComment(gh, job);
        if (!(await renew())) return; // the search may have outlasted the lease
        if (again) comment = await edit(again.id);
      }
      comment ??= await gh.request<Comment>(repository, 'POST', `${path}/${job.number}/comments`, { body });
      // fetch follows a redirect (a transferred issue) and turns the POST into a GET, which answers with something else.
      if (typeof comment?.id !== 'number') throw new GitHubError(0, "GitHub didn't return the comment; the issue may have been transferred", false);
    }
    const posted = comment;
    await tx(pool, async (c) => {
      await c.query('SELECT 1 FROM tasks WHERE id = $1 FOR KEY SHARE', [job.task_id]); // lock order of task delete: task first
      const { rowCount } = await c.query(
        `UPDATE github_comments SET state = 'posted', comment_id = $3, url = $4, locked_until = NULL, last_error = NULL, updated_at = now()
         WHERE task_id = $1 AND attempts = $2 AND state = 'posting'`,
        [...ours, posted.id, posted.html_url],
      );
      if (rowCount) await logActivity(c, job.task_id, spec.approved_by, 'github_comment_posted', { version: job.version, url: posted.html_url });
    });
  } catch (err) {
    const e = asGitHubError(err);
    await pool.query(
      `UPDATE github_comments SET state = $3, last_error = $4, locked_until = NULL, updated_at = now(),
         next_attempt_at = now() + make_interval(secs => $5)
       WHERE task_id = $1 AND attempts = $2 AND state = 'posting'`,
      [...ours, e.retryable ? 'pending' : 'failed', e.retryable ? e.message : failure(e, repository, 'comment'), backoff(job.attempts, e)],
    );
  }
}

/** The comment an earlier attempt posted: the app's own, carrying the marker, updated since an hour before the row was queued. */
// ponytail: pages through the issue's comments (oldest first); fine for issues with hundreds of comments.
async function findOwnComment(gh: GitHubClient, job: CommentJob) {
  const app = await gh.app(job.repository);
  const since = new Date(job.created_at.getTime() - 3_600_000).toISOString();
  for (let page = 1; ; page++) {
    const comments = await gh.request<Comment[]>(
      job.repository,
      'GET',
      `/repos/${job.repository}/issues/${job.number}/comments?since=${since}&per_page=100&page=${page}`,
    );
    for (const comment of comments) {
      // Anyone can paste the marker; only a comment this app posted counts.
      if (comment.body?.includes(specMarker(job.task_id)) && byApp(comment, app)) return comment;
    }
    if (comments.length < 100) return undefined;
  }
}

type PrJob = { id: string; repository: string; repository_id: string; number: number; dirty_seq: string };

async function claimPullRequest(pool: pg.Pool, seen: string[]): Promise<PrJob | undefined> {
  const { rows } = await pool.query(
    `UPDATE pull_requests SET locked_until = ${LEASE}
     WHERE id = (
       SELECT id FROM pull_requests
       WHERE dirty_seq > synced_seq AND (locked_until IS NULL OR locked_until < now()) AND id <> ALL($1::bigint[])
       ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
     RETURNING id, repository, repository_id, number, dirty_seq`,
    [seen],
  );
  return rows[0];
}

const PR_QUERY = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      title url state isDraft isCrossRepository headRefName headRefOid updatedAt reviewDecision author { login }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      closingIssuesReferences(first: 25) { nodes { number repository { databaseId } } }
    }
  }
}`;

type GraphQlPr = {
  title: string;
  url: string;
  state: string;
  isDraft: boolean;
  isCrossRepository?: boolean;
  headRefName: string;
  headRefOid: string;
  updatedAt: string;
  reviewDecision: string | null;
  author: { login: string } | null;
  commits: { nodes: { commit: { statusCheckRollup: { state: string } | null } }[] };
  closingIssuesReferences: { nodes: { number: number; repository: { databaseId: number } }[] };
};

const PR_STATE: Record<string, string> = { OPEN: 'open', CLOSED: 'closed', MERGED: 'merged' };
const REVIEW: Record<string, string> = { APPROVED: 'approved', CHANGES_REQUESTED: 'changes_requested', REVIEW_REQUIRED: 'review_required' };
const CI: Record<string, string> = { SUCCESS: 'success', FAILURE: 'failure', ERROR: 'failure', PENDING: 'pending', EXPECTED: 'pending' };

/** Reads the PR's current state from GitHub and relinks it: closing references in its repository, or a `N-...` branch. */
async function reconcile(pool: pg.Pool, gh: GitHubClient, pr: PrJob) {
  try {
    const [owner, name] = pr.repository.split('/');
    const data = await gh.graphql<{ repository: { pullRequest: GraphQlPr | null } | null }>(pr.repository, PR_QUERY, {
      owner,
      name,
      number: pr.number,
    });
    const p = data?.repository?.pullRequest;
    if (!p) throw new GitHubError(404, `pull request ${pr.repository}#${pr.number} not found`, false);
    const issues = p.closingIssuesReferences.nodes.filter((n) => String(n.repository.databaseId) === pr.repository_id).map((n) => n.number);
    // Anyone can name a fork's branch; only branches in the repository itself link that way.
    const branch = p.isCrossRepository ? undefined : /^(\d+)-/.exec(p.headRefName)?.[1];
    if (branch) issues.push(Number(branch));
    const rollup = p.commits.nodes[0]?.commit.statusCheckRollup?.state;
    await tx(pool, async (c) => {
      // Lock order of task delete: the tasks first, then their links.
      await c.query(
        `SELECT 1 FROM tasks WHERE id IN (
           SELECT task_id FROM pull_request_tasks WHERE pull_request_id = $1
           UNION SELECT task_id FROM github_issues WHERE repository_id = $2 AND state = 'created' AND number = ANY($3::int[]))
         ORDER BY id FOR KEY SHARE`,
        [pr.id, pr.repository_id, issues],
      );
      await c.query(
        `UPDATE pull_requests SET title = $2, url = $3, author = $4, state = $5, draft = $6, head_ref = $7, head_sha = $8, review = $9,
           ci = $10, github_updated_at = $11, synced_seq = GREATEST(synced_seq, $12), locked_until = NULL
         WHERE id = $1`,
        [
          pr.id,
          p.title,
          p.url,
          p.author?.login ?? null,
          PR_STATE[p.state] ?? 'open',
          p.isDraft,
          p.headRefName,
          p.headRefOid,
          REVIEW[p.reviewDecision ?? ''] ?? 'none',
          CI[rollup ?? ''] ?? 'none',
          p.updatedAt,
          pr.dirty_seq,
        ],
      );
      await c.query('DELETE FROM pull_request_tasks WHERE pull_request_id = $1', [pr.id]);
      await c.query(
        `INSERT INTO pull_request_tasks (pull_request_id, task_id)
         SELECT $1, task_id FROM github_issues WHERE repository_id = $2 AND state = 'created' AND number = ANY($3::int[])`,
        [pr.id, pr.repository_id, issues],
      );
    });
  } catch (err) {
    const e = asGitHubError(err);
    // Retryable: keep the lease as the backoff. Otherwise give up until the next webhook marks it dirty again.
    await pool.query(
      e.retryable
        ? `UPDATE pull_requests SET locked_until = now() + make_interval(secs => $2) WHERE id = $1`
        : `UPDATE pull_requests SET locked_until = NULL, synced_seq = GREATEST(synced_seq, $2) WHERE id = $1`,
      [pr.id, e.retryable ? backoff(1, e) : pr.dirty_seq],
    );
  }
}

// ---- Webhooks (their own listener, so the tunnel never reaches the API) ----

type Check = { head_sha: string; pull_requests?: { number: number }[] };
type Payload = {
  action?: string;
  repository?: { id: number; full_name: string };
  pull_request?: {
    number: number;
    title: string;
    html_url: string;
    user?: { login: string };
    state: string;
    merged?: boolean;
    draft?: boolean;
    head: { sha: string; ref: string };
    updated_at: string;
  };
  check_run?: Check;
  check_suite?: Check;
  sha?: string;
  issue?: { number: number; updated_at: string };
};

export async function buildWebhookApp({ pool, github, logger = false }: { pool: pg.Pool; github?: GitHubConfig; logger?: boolean }) {
  // The subscribed events are well under this (a PR body is at most 65,536 characters); it bounds what anyone can make us buffer.
  const app = Fastify({ logger, bodyLimit: 2 * 1024 * 1024 });
  // The signature covers the exact bytes GitHub sent, so parse only after checking it.
  app.addContentTypeParser('application/json', { parseAs: 'buffer' }, (_req, body, done) => done(null, body));
  app.setErrorHandler((err: { statusCode?: number }, req, reply) => {
    if ((err.statusCode ?? 500) < 500) return reply.send(err);
    req.log.error(err);
    return reply.code(500).send({ statusCode: 500, error: 'Internal Server Error', message: 'Internal server error' });
  });

  app.post('/github/webhook', async (req, reply) => {
    if (!github) return reply.code(503).send({ message: 'GitHub sync is not configured' });
    const signature = req.headers['x-hub-signature-256'];
    if (!Buffer.isBuffer(req.body) || !validSignature(github.webhookSecret, req.body, typeof signature === 'string' ? signature : undefined)) {
      throw httpError(401, 'invalid signature');
    }
    const delivery = req.headers['x-github-delivery'];
    const event = req.headers['x-github-event'];
    if (typeof delivery !== 'string' || typeof event !== 'string') throw httpError(400, 'missing X-GitHub-Delivery or X-GitHub-Event');
    let payload: Payload;
    try {
      payload = JSON.parse(req.body.toString('utf8'));
    } catch {
      throw httpError(400, 'invalid JSON');
    }
    // One transaction: if processing fails the delivery isn't recorded either, so redelivering it (by hand, from the
    // app's Advanced settings; GitHub doesn't retry) processes it.
    const fresh = await tx(pool, async (c) => {
      const { rowCount } = await c.query('INSERT INTO github_deliveries (id, event) VALUES ($1, $2) ON CONFLICT DO NOTHING', [delivery, event]);
      if (rowCount) await handleEvent(c, event, payload);
      return !!rowCount;
    });
    return { ok: true, duplicate: !fresh };
  });
  return app;
}

const ISSUE_EVENT: Record<string, [string, string | null]> = {
  closed: ['closed', null],
  reopened: ['open', null],
  deleted: ['closed', 'the issue was deleted on GitHub'],
  transferred: ['closed', 'the issue was transferred to another repository'],
};

/** Webhooks only record that something changed; reconcile reads the truth from GitHub. */
async function handleEvent(c: pg.PoolClient, event: string, p: Payload) {
  const repositoryId = p.repository?.id;
  if (!repositoryId) return; // ping, installation*
  const { rowCount } = await c.query(`SELECT 1 FROM github_issues WHERE repository_id = $1 AND state = 'created' LIMIT 1`, [repositoryId]);
  if (!rowCount) return; // a repository we never filed an issue in
  const bump = (where: string, value: unknown) =>
    c.query(
      // Rows locked in id order, so concurrent deliveries touching the same PRs can't deadlock.
      `UPDATE pull_requests SET dirty_seq = dirty_seq + 1
       WHERE id IN (SELECT id FROM pull_requests WHERE repository_id = $1 AND ${where} ORDER BY id FOR UPDATE)`,
      [repositoryId, value],
    );

  if (event === 'pull_request' && p.pull_request) {
    const pr = p.pull_request;
    await c.query(
      `INSERT INTO pull_requests (repository_id, repository, number, title, url, author, state, draft, head_sha, head_ref, github_updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
       ON CONFLICT (repository_id, number) DO UPDATE SET title = EXCLUDED.title, url = EXCLUDED.url, author = EXCLUDED.author,
         state = EXCLUDED.state, draft = EXCLUDED.draft, head_sha = EXCLUDED.head_sha, head_ref = EXCLUDED.head_ref,
         github_updated_at = EXCLUDED.github_updated_at, dirty_seq = pull_requests.dirty_seq + 1`,
      [
        repositoryId,
        p.repository!.full_name.toLowerCase(),
        pr.number,
        pr.title,
        pr.html_url,
        pr.user?.login ?? null,
        pr.merged ? 'merged' : pr.state,
        pr.draft ?? false,
        pr.head.sha,
        pr.head.ref,
        pr.updated_at,
      ],
    );
  } else if (event === 'pull_request_review' && p.pull_request) {
    await bump('number = $2', p.pull_request.number);
  } else if (event === 'check_run' || event === 'check_suite') {
    const check = event === 'check_run' ? p.check_run : p.check_suite;
    const numbers = check?.pull_requests?.map((pr) => pr.number) ?? [];
    await (numbers.length ? bump('number = ANY($2::int[])', numbers) : bump('head_sha = $2', check?.head_sha));
  } else if (event === 'status') {
    await bump('head_sha = $2', p.sha);
  } else if (event === 'issues' && p.issue && ISSUE_EVENT[p.action ?? '']) {
    const [state, note] = ISSUE_EVENT[p.action!];
    // Deliveries can arrive out of order: an older event never overwrites a newer one.
    await c.query(
      `UPDATE github_issues SET issue_state = $3, last_error = $4, issue_updated_at = $5, updated_at = now()
       WHERE repository_id = $1 AND number = $2 AND (issue_updated_at IS NULL OR issue_updated_at <= $5)`,
      [repositoryId, p.issue.number, state, note, p.issue.updated_at],
    );
  }
}
