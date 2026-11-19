import { randomBytes } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type pg from 'pg';
import { httpError, rateLimit, sha256, tx } from './db.ts';
import type { Mailer } from './mail.ts';
import { workspaceRole } from './routes.ts';

const uuid = { type: 'string', format: 'uuid' } as const;
const params = (...names: string[]) => ({ type: 'object', required: names, properties: Object.fromEntries(names.map((n) => [n, uuid])) }) as const;
const object = (properties: Record<string, object>) =>
  ({ type: 'object', required: Object.keys(properties), additionalProperties: false, properties }) as const;

type Ws = { id: string };
type Member = Ws & { userId: string };
type Invite = Ws & { inviteId: string };

const MEMBER = `u.id AS "userId", u.login, u.display_name AS "displayName", m.role`;
/** A workspace_invites row `i` as owners and admins see it. */
const INVITE = `i.id, i.email, (SELECT login FROM users WHERE id = i.invited_by) AS "invitedBy", i.created_at AS "createdAt", i.expires_at AS "expiresAt"`;
const PENDING = 'i.accepted_at IS NULL AND i.revoked_at IS NULL';
const HOUR = 3_600_000;

/** The app's error handler hides 5xx messages (they may carry internals); these are ours to explain, so they're sent here. */
const unavailable = (reply: FastifyReply, statusCode: 502 | 503, message: string) =>
  reply.code(statusCode).send({ statusCode, error: statusCode === 502 ? 'Bad Gateway' : 'Service Unavailable', message });

/** `j***@example.com`: enough for the invitee to recognise the address, not enough to harvest it. */
const masked = (email: string) => `${email[0]}***${email.slice(email.indexOf('@'))}`;

export function registerInviteRoutes(app: FastifyInstance, pool: pg.Pool, { authMode, mailer }: { authMode: string; mailer?: Mailer }) {
  const appUrl = (process.env.APP_URL ?? 'http://localhost:3000').replace(/\/$/, '');
  // Invite emails go to addresses the inviter types: limited per workspace and per inviter, so the API can't spam.
  const perWorkspace = rateLimit(pool, 'invite-workspace', 20, HOUR);
  const perInviter = rateLimit(pool, 'invite-inviter', 20, HOUR);
  const acceptLimit = rateLimit(pool, 'invite-accept', 30);

  /** Owners and admins manage invites; members get 403, non-members 404. */
  async function requireAdmin(req: FastifyRequest) {
    const { id } = req.params as Ws;
    if ((await workspaceRole(pool, req.userId, id)) === 'member') throw httpError(403, 'Only the owner and admins can manage invites');
  }

  /** Checked before anything is stored, so a misconfigured server doesn't collect addresses it can't email. */
  const noMail = (reply: FastifyReply) => !mailer && authMode === 'github' && unavailable(reply, 503, 'Email is not configured');

  /**
   * Emails the invite with a fresh token (the row already holds its hash). A failed send answers 502 (and returns that
   * reply) with the invite kept, so it can be resent; the provider's error is logged, the link only when there's no mailer.
   */
  async function deliver(req: FastifyRequest, reply: FastifyReply, invite: { email: string; workspace: string }, token: string) {
    const link = `${appUrl}/#/invite/${token}`;
    if (!mailer) {
      app.log.info(`No mailer configured: invite link for ${invite.email}: ${link}`);
      return;
    }
    const { rows: [me] } = await pool.query('SELECT login FROM users WHERE id = $1', [req.userId]);
    try {
      await mailer.sendInvite({ to: invite.email, inviter: me.login, workspace: invite.workspace, link });
    } catch (err) {
      req.log.error(err);
      return unavailable(reply, 502, 'The invite was saved but its email could not be sent; resend it');
    }
  }

  const newToken = () => randomBytes(32).toString('base64url');
  const limitSends = async (req: FastifyRequest) => {
    await perWorkspace((req.params as Ws).id);
    await perInviter(req.userId);
  };

  // ---- Members ----
  app.get('/workspaces/:id/members', { schema: { params: params('id') } }, async (req) => {
    const { id } = req.params as Ws;
    await workspaceRole(pool, req.userId, id);
    const { rows } = await pool.query(
      `SELECT ${MEMBER} FROM workspace_members m JOIN users u ON u.id = m.user_id WHERE m.workspace_id = $1 ORDER BY m.role = 'owner' DESC, u.login`,
      [id],
    );
    return rows;
  });

  app.patch(
    '/workspaces/:id/members/:userId',
    { schema: { params: params('id', 'userId'), body: object({ role: { enum: ['admin', 'member'] } }) } },
    async (req) => {
      const { id, userId } = req.params as Member;
      if ((await workspaceRole(pool, req.userId, id)) !== 'owner') throw httpError(403, 'Only the owner can change roles');
      // The owner's role never changes (no ownership transfer), so checking it apart from the update can't race.
      const { rows: [target] } = await pool.query('SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2', [id, userId]);
      if (target?.role === 'owner') throw httpError(400, "The owner's role can't change");
      const { rows: [member] } = await pool.query(
        `UPDATE workspace_members m SET role = $3 FROM users u WHERE m.workspace_id = $1 AND m.user_id = $2 AND u.id = m.user_id RETURNING ${MEMBER}`,
        [id, userId, (req.body as { role: string }).role],
      );
      if (!member) throw httpError(404, 'member not found');
      return member;
    },
  );

  // The owner removes anyone else; anyone else may leave. Access goes with the row: every board, task and run check joins it.
  app.delete('/workspaces/:id/members/:userId', { schema: { params: params('id', 'userId') } }, async (req, reply) => {
    const { id, userId } = req.params as Member;
    const role = await workspaceRole(pool, req.userId, id);
    if (userId !== req.userId && role !== 'owner') throw httpError(403, 'Only the owner can remove members');
    const { rows: [target] } = await pool.query('SELECT role FROM workspace_members WHERE workspace_id = $1 AND user_id = $2', [id, userId]);
    if (target?.role === 'owner') throw httpError(400, "The owner can't leave or be removed");
    const { rowCount } = await pool.query(`DELETE FROM workspace_members WHERE workspace_id = $1 AND user_id = $2 AND role <> 'owner'`, [id, userId]);
    if (!rowCount) throw httpError(404, 'member not found');
    return reply.code(204).send();
  });

  // ---- Invites ----
  app.get('/workspaces/:id/invites', { schema: { params: params('id') } }, async (req) => {
    await requireAdmin(req);
    // Expired ones too: the app shows them as expired, with Resend.
    const { rows } = await pool.query(`SELECT ${INVITE} FROM workspace_invites i WHERE i.workspace_id = $1 AND ${PENDING} ORDER BY i.created_at`, [
      (req.params as Ws).id,
    ]);
    return rows;
  });

  app.post(
    '/workspaces/:id/invites',
    { schema: { params: params('id'), body: object({ email: { type: 'string', format: 'email', maxLength: 254 } }) } },
    async (req, reply) => {
      const { id } = req.params as Ws;
      await requireAdmin(req);
      if (noMail(reply)) return reply;
      const email = (req.body as { email: string }).email.toLowerCase();
      const member = await pool.query(
        'SELECT 1 FROM user_emails e JOIN workspace_members m ON m.user_id = e.user_id WHERE m.workspace_id = $1 AND e.email = $2',
        [id, email],
      );
      if (member.rowCount) throw httpError(409, 'Someone with this address is already a member');
      await limitSends(req); // before storing anything: past the limit the address isn't kept either
      const token = newToken();
      // A pending invite for the address is resent: a new token voids the old link. One statement, so two at once can't both insert.
      const { rows: [{ created, workspace, ...invite }] } = await pool.query(
        `WITH i AS (
           INSERT INTO workspace_invites (workspace_id, email, token_hash, invited_by, expires_at) VALUES ($1, $2, $3, $4, now() + interval '7 days')
           ON CONFLICT (workspace_id, email) WHERE accepted_at IS NULL AND revoked_at IS NULL
           DO UPDATE SET token_hash = EXCLUDED.token_hash, invited_by = EXCLUDED.invited_by, expires_at = EXCLUDED.expires_at
           RETURNING *, xmax = 0 AS created)
         SELECT ${INVITE}, i.created, (SELECT name FROM workspaces WHERE id = i.workspace_id) AS workspace FROM i`,
        [id, email, sha256(token), req.userId],
      );
      if (await deliver(req, reply, { email, workspace }, token)) return reply;
      return reply.code(created ? 201 : 200).send(invite);
    },
  );

  app.post('/workspaces/:id/invites/:inviteId/resend', { schema: { params: params('id', 'inviteId') } }, async (req, reply) => {
    const { id, inviteId } = req.params as Invite;
    await requireAdmin(req);
    if (noMail(reply)) return reply;
    const token = newToken();
    // Limited only once the invite is known pending, and before the new token is stored, so a 429 leaves the old link working.
    // Not inside a transaction: the limit is its own statement on the shared table, and a connection held while waiting
    // for a second one could starve the pool.
    const pending = await pool.query(`SELECT 1 FROM workspace_invites i WHERE i.id = $1 AND i.workspace_id = $2 AND ${PENDING}`, [inviteId, id]);
    if (!pending.rowCount) throw httpError(404, 'invite not found');
    await limitSends(req);
    const { rows: [row] } = await pool.query(
      `UPDATE workspace_invites i SET token_hash = $3, invited_by = $4, expires_at = now() + interval '7 days'
       WHERE i.id = $1 AND i.workspace_id = $2 AND ${PENDING}
       RETURNING ${INVITE}, (SELECT name FROM workspaces WHERE id = i.workspace_id) AS workspace`,
      [inviteId, id, sha256(token), req.userId],
    );
    if (!row) throw httpError(404, 'invite not found');
    const { workspace, ...invite } = row;
    if (await deliver(req, reply, { email: invite.email, workspace }, token)) return reply;
    return invite;
  });

  app.delete('/workspaces/:id/invites/:inviteId', { schema: { params: params('id', 'inviteId') } }, async (req, reply) => {
    const { id, inviteId } = req.params as Invite;
    await requireAdmin(req);
    // Waits for an accept holding the row; then finds it accepted (404).
    const { rowCount } = await pool.query(`UPDATE workspace_invites i SET revoked_at = now() WHERE i.id = $1 AND i.workspace_id = $2 AND ${PENDING}`, [
      inviteId,
      id,
    ]);
    if (!rowCount) throw httpError(404, 'invite not found');
    return reply.code(204).send();
  });

  // The token travels in the body: request logs record the URL.
  app.post(
    '/invites/accept',
    { schema: { body: object({ token: { type: 'string', minLength: 1, maxLength: 100 } }) } },
    async (req) => {
      await acceptLimit(req.userId);
      const gone = httpError(404, 'This invite expired or was already used');
      return tx(pool, async (c) => {
        // The row lock serialises accepts of one token (and a revoke): the second sees the first one's result.
        const { rows: [inv] } = await c.query(
          `SELECT i.id, i.workspace_id AS "workspaceId", w.name, i.email, i.accepted_by AS "acceptedBy", i.accepted_at IS NOT NULL AS accepted,
             i.revoked_at IS NOT NULL AS revoked, i.expires_at <= now() AS expired,
             EXISTS (SELECT 1 FROM workspace_members WHERE workspace_id = i.workspace_id AND user_id = $2) AS member
           FROM workspace_invites i JOIN workspaces w ON w.id = i.workspace_id WHERE i.token_hash = $1 FOR UPDATE OF i`,
          [sha256((req.body as { token: string }).token), req.userId],
        );
        if (!inv || inv.revoked) throw gone;
        const ok = { workspaceId: inv.workspaceId, name: inv.name };
        // Accepting twice is a no-op; a used link adds nobody else, nor someone who was removed since.
        if (inv.accepted) {
          if (inv.acceptedBy === req.userId && inv.member) return ok;
          throw gone;
        }
        if (inv.expired) throw gone;
        // Checked before the already-a-member shortcut, so nobody else can use up the invitee's link.
        if (authMode === 'github') {
          const { rows: [e] } = await c.query('SELECT count(*)::int AS n, COALESCE(bool_or(email = $2), false) AS mine FROM user_emails WHERE user_id = $1', [
            req.userId,
            inv.email,
          ]);
          // No addresses at all: signed in before this check existed, or before the app could read them. `code` lets the app say so.
          if (!e.n) throw Object.assign(httpError(403, 'Sign in again so we can check your GitHub email addresses'), { code: 'sign_in_again' });
          if (!e.mine) throw httpError(403, `This invite was sent to ${masked(inv.email)}`);
        }
        // Not trusting `member` from the snapshot: an accept of another invite, or a removal, may have committed since.
        await c.query(`INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ($1, $2, 'member') ON CONFLICT (workspace_id, user_id) DO NOTHING`, [
          inv.workspaceId,
          req.userId,
        ]);
        await c.query('UPDATE workspace_invites SET accepted_by = $2, accepted_at = now() WHERE id = $1', [inv.id, req.userId]);
        return ok;
      });
    },
  );
}
