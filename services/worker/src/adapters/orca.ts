import { execFile } from 'node:child_process';
import { appendFile, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { refineWithClaude } from './claude.ts';
import type { RunEvent } from './opencode.ts';

type Reply = { ok: boolean; result?: unknown; error?: { message?: string } };

const sh = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;
/** Titles and paths come from teammates and the repository: no escape sequences into the user's terminal. */
// eslint-disable-next-line no-control-regex
const plain = (s: string) => s.replace(/[\x00-\x09\x0b-\x1f\x7f-\x9f]/g, '?');

/** `orca <args> --json` against this machine's Orca; the reply, or why it failed (never the arguments: they hold paths). */
async function orca(args: string[], opts: { timeout: number; signal?: AbortSignal }): Promise<Reply> {
  // Without the variables that would point the CLI at a paired remote Orca instead of this machine's app.
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !['ORCA_ENVIRONMENT', 'ORCA_PAIRING_CODE', 'ORCA_REMOTE_PAIRING'].includes(k)));
  for (const bin of ['orca', '/Applications/Orca.app/Contents/Resources/bin/orca']) {
    try {
      return JSON.parse((await promisify(execFile)(bin, [...args, '--json'], { ...opts, env })).stdout);
    } catch (e) {
      const err = e as { stdout?: string; code?: unknown; killed?: boolean };
      if (err.code === 'ENOENT') continue;
      try {
        return JSON.parse(err.stdout ?? ''); // Orca prints its JSON reply even when it exits non-zero
      } catch {
        return { ok: false, error: { message: err.killed ? 'timed out' : `the Orca CLI failed (${err.code})` } };
      }
    }
  }
  return { ok: false, error: { message: 'the Orca CLI was not found' } };
}

/** One readable line per event, for the Orca terminal. */
const line = (e: RunEvent) =>
  plain(
    e.kind === 'tool'
      ? `${e.data.ok ? ' ' : '✗'} ${e.data.tool} ${e.data.target}`
      : e.kind === 'model'
        ? `Claude Code (${e.data.model}), read-only, in an export of the commit`
        : `${e.kind} ${JSON.stringify(e.data)}`,
  );

/**
 * refineWithClaude, unchanged, with its progress shown in a terminal of the local Orca app. The worker runs and
 * supervises Claude Code itself, so its flags, PATH, environment, init check, stray-tool stop and kill all stay as in
 * the direct path; the terminal only tails a log of the run's events. It opens in the checkout's Orca workspace (the
 * checkout must be added to Orca), and its login shell starts there, so the command uses only absolute paths and
 * builtins. It ends by itself once the log is removed or the worker is gone, in case the close never comes. If Orca
 * isn't running, the run goes ahead unwatched. Local Orca only: remote Orca environments aren't supported.
 */
export async function refineInOrca(opts: Parameters<typeof refineWithClaude>[0] & { checkout: string }) {
  const { checkout, onEvent, ...rest } = opts;
  const title = plain(rest.job.task.title);
  const ctl = await realpath(await mkdtemp(path.join(os.tmpdir(), 'ai-kanban-orca-')));
  const file = path.join(ctl, 'run.log');
  const log = sh(file);
  let handle: string | undefined;
  let shown = Promise.resolve(); // appends in order, and all of them land before the terminal closes
  try {
    await writeFile(file, `Refining "${title}"\n`);
    const created = await orca(
      [
        'terminal', 'create', '--worktree', `path:${checkout}`, '--title', [...`Refine: ${title}`].slice(0, 80).join(''),
        // Typed into the shell: the leading space keeps it out of history where the shell ignores such lines.
        '--command', ` /usr/bin/tail -n +1 -f ${log} & while [ -e ${log} ] && kill -0 ${process.pid} 2>/dev/null; do /bin/sleep 1; done; kill $!; exit`,
      ],
      { timeout: 30_000, signal: rest.signal },
    );
    handle = (created.result as { terminal?: { handle?: string } } | undefined)?.terminal?.handle;
    if (!handle) console.error(`Not shown in Orca (${created.error?.message ?? 'no terminal'}); is Orca open with this checkout added?`);
    const show = (e: RunEvent) => (shown = shown.then(() => appendFile(file, line(e) + '\n')).catch(() => {}));
    return await refineWithClaude({ ...rest, onEvent: (e) => (onEvent(e), void show(e)) });
  } finally {
    await shown;
    const closed = handle ? await orca(['terminal', 'close', '--terminal', handle], { timeout: 5000 }) : undefined;
    if (closed && !closed.ok) console.error(`Could not close the Orca terminal (${closed.error?.message}); it ends by itself`);
    await rm(ctl, { recursive: true, force: true });
  }
}
