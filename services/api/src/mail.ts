/** Sends the one email the API sends. Swapping providers means replacing mailerFromEnv only. */
export type Mailer = { sendInvite(m: { to: string; inviter: string; workspace: string; link: string }): Promise<void> };

/** Resend (https://resend.com) when RESEND_API_KEY and MAIL_FROM are set; otherwise none. */
export function mailerFromEnv(env = process.env): Mailer | undefined {
  const key = env.RESEND_API_KEY;
  const from = env.MAIL_FROM;
  if (!key || !from) return undefined;
  return {
    async sendInvite({ to, inviter, workspace, link }) {
      // User-chosen text in mail from the operator's domain: one line, bounded.
      const name = workspace.replace(/\s+/g, ' ').trim().slice(0, 100);
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json', 'user-agent': 'ai-kanban' },
        body: JSON.stringify({
          from,
          to: [to],
          subject: `${inviter} invited you to a workspace on AI Kanban`,
          // Only the inviter, the workspace's name and the link: nothing from boards or repositories.
          text: `${inviter} invited you to the workspace "${name}" on AI Kanban.\n\nJoin it here (sign in with GitHub first; the link works once and expires in 7 days):\n${link}\n`,
        }),
        signal: AbortSignal.timeout(20_000),
      });
      // The answer may echo the request, link included: keep it out of the error.
      if (!res.ok) throw new Error(`Resend answered ${res.status}`);
    },
  };
}
