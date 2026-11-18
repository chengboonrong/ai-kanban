import Fastify, { type FastifyBaseLogger, type FastifyInstance } from 'fastify';
import type pg from 'pg';
import { type Db, httpError, tx } from './db.ts';
import { type GitHubClient, type GitHubConfig, GitHubError, gitHubClient, validSignature } from './github.ts';
import { boardFor, logActivity } from './routes.ts';

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

/** The task page's view: unlike the card, the issue says where creation stands (state) apart from GitHub's issueState. */
async function githubOf(db: Db, taskId: string) {
  const { rows: [row] } = await db.query(
    `SELECT CASE state
       WHEN 'created' THEN json_build_object('state', 'created', 'number', number, 'url', url, 'issueState', issue_state)
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
  return { issue: row?.issue ?? null, prs };
}

export function registerGitHubRoutes(app: FastifyInstance, pool: pg.Pool) {
  app.get('/tasks/:id/github', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    await boardFor(pool, req.userId, 'task', id);
    return githubOf(pool, id);
  });

  app.post('/tasks/:id/github/retry', { schema: { params: idParams } }, async (req) => {
    const { id } = req.params as Id;
    const boardId = await boardFor(pool, req.userId, 'task', id);
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
      if (board.repository !== spec.repository) {
        throw httpError(409, `the board now points at ${board.repository ?? 'no repository'}; refine again`);
      }
      await queueIssue(c, id, spec.repository);
    });
    return githubOf(pool, id);
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
const marker = (taskId: string) => `<!-- ai-kanban:task:${taskId} -->`;
/** Spec text is data: it must not mention (notify) people or open an HTML comment that hides the rest. */
// owner/repo#N would also post a cross-reference on another repository's issue.
const inert = (s: string) => s.replaceAll('@', '@​').replaceAll('<!--', '&lt;!--').replace(/([\w.-]+\/[\w.-]+)#(?=\d)/g, '$1#\u200B');
const section = (heading: string, lines: string[]) => (lines.length ? `\n\n## ${heading}\n\n${lines.join('\n')}` : '');

export function issueBody(taskId: string, spec: Spec) {
  const body =
    `${marker(taskId)}\n\n${inert(spec.summary)}` +
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
export function startGitHubSync({ pool, github, log }: { pool: pg.Pool; github: GitHubConfig; log: FastifyBaseLogger }) {
  const gh = gitHubClient(github);
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

/** One pass: file due issues, reconcile dirty pull requests, prune old delivery ids. */
export async function syncOnce(pool: pg.Pool, gh: GitHubClient) {
  // A queued issue whose board moved to another repository since approval is never filed.
  await pool.query(
    `UPDATE github_issues gi SET state = 'failed', last_error = 'the board''s repository changed', locked_until = NULL, updated_at = now()
     FROM tasks t JOIN boards b ON b.id = t.board_id
     WHERE t.id = gi.task_id AND gi.state IN ('pending', 'creating') AND (gi.locked_until IS NULL OR gi.locked_until < now())
       AND b.repository IS DISTINCT FROM gi.repository`,
  );
  for (let job; (job = await claimIssue(pool)); ) await createIssue(pool, gh, job);
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
  state: 'open' | 'closed';
  body?: string | null;
  created_at: string;
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
        body: issueBody(job.task_id, spec.content),
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

function failure(e: GitHubError, repository: string) {
  if (e.status === 403) return `the GitHub App isn't allowed to create issues in ${repository} (${e.message})`;
  if (e.status === 410) return `issues are disabled in ${repository}`;
  if (e.status === 422) return `GitHub rejected the issue (${e.message})`;
  return e.message;
}

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
      const byApp = issue.performed_via_github_app?.id === app.id || issue.user?.login === `${app.slug}[bot]`;
      if (!issue.pull_request && issue.body?.includes(marker(job.task_id)) && byApp) return issue;
    }
    if (issues.length < 100) return undefined;
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
