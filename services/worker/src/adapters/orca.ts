import { execFile } from 'node:child_process';
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import specSchema from '../../../../packages/contracts/refined-spec.schema.json' with { type: 'json' };
import { type Job, REFINER_PROMPT, type RunEvent, type Spec, taskBrief } from './opencode.ts';

type Reply = { ok: boolean; result?: unknown; error?: { code: string; message: string } };
type StreamLine = {
  type: string;
  model?: string;
  message?: { content?: { type: string; id?: string; name?: string; input?: Record<string, unknown>; tool_use_id?: string; is_error?: boolean }[] | string };
  is_error?: boolean;
  subtype?: string;
  result?: string;
  structured_output?: Spec;
  session_id?: string;
  usage?: object;
  total_cost_usd?: number;
  modelUsage?: Record<string, unknown>;
};

/**
 * Runs `orca <args> --json` against this machine's Orca. Orca prints its JSON reply even when it exits non-zero. Errors
 * name only the command: Node's message would repeat the arguments, which hold this machine's paths.
 */
async function orca(args: string[]): Promise<Reply> {
  const command = `orca ${args.slice(0, 2).join(' ')}`;
  const out = await promisify(execFile)('orca', [...args, '--json'], { timeout: 30_000 }).then(
    (r) => r.stdout,
    (e: Error & { stdout?: string; code?: unknown; killed?: boolean }) => {
      if (e.stdout) return e.stdout;
      throw new Error(`${command} ${e.killed ? 'timed out' : `failed (${e.code})`}; is the Orca CLI installed?`);
    },
  );
  try {
    return JSON.parse(out);
  } catch {
    throw new Error(`${command} answered something other than JSON`);
  }
}

/** Fails fast when Orca isn't running on this machine. Local Orca only: remote Orca environments aren't supported. */
export async function checkOrca() {
  const status = (await orca(['status'])).result as { runtime?: { reachable?: boolean } } | undefined;
  if (!status?.runtime?.reachable) throw new Error('Orca is not running on this machine; open the Orca app (or run `orca open`)');
}

const sh = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;

/**
 * Runs the Refiner as Claude Code in a terminal of the local Orca app, so the run shows up in Orca. Orca's own agent
 * launch can't restrict an agent (it runs with the user's settings, often with permissions bypassed), so the worker
 * starts Claude Code itself with flags that keep it read-only and confined to the export:
 * --restricted: no Bash or other code-running tools, no WebFetch, file tools confined to the working directory, no
 *   user or project settings (so no hooks from the checkout), bypassPermissions refused.
 * --safe-mode, --strict-mcp-config: no CLAUDE.md, skills, plugins or MCP servers, the checkout's or the user's.
 * --tools / --allowedTools Read,Glob,Grep with dontAsk: nothing else exists, and anything not allowed is denied rather
 *   than asked about, so a headless run can't hang.
 * `checkout` must be a repository added to Orca: the terminal opens in its workspace and then cds into the export.
 */
export async function refineWithOrca(opts: {
  checkout: string;
  dir: string;
  job: Job;
  commitSha: string;
  model?: string;
  onEvent: (e: RunEvent) => void;
  signal: AbortSignal;
}) {
  const { checkout, dir, job, model, onEvent, signal } = opts;
  // Prompt, schema and output live outside the export, where the agent can't read or overwrite them.
  const ctl = await realpath(await mkdtemp(path.join(os.tmpdir(), 'ai-kanban-orca-')));
  const file = (name: string) => path.join(ctl, name);
  const fail = (message: string) => new Error(message.replaceAll(ctl, '.').slice(0, 2000));
  let handle: string | undefined;
  const close = async () => {
    if (handle) await orca(['terminal', 'close', '--terminal', handle]).catch(() => {});
    // Also stop Claude Code directly, in case Orca quit or couldn't close the terminal. run.sh execs it, so this is
    // its pid; once it has exited there is nothing to kill.
    const pid = Number(await readFile(file('pid'), 'utf8').catch(() => ''));
    if (pid > 0) {
      try {
        process.kill(pid);
      } catch {
        // already gone
      }
    }
  };
  signal.addEventListener('abort', close, { once: true });
  try {
    await writeFile(file('prompt.txt'), taskBrief(job, opts.commitSha));
    await writeFile(file('system.txt'), REFINER_PROMPT);
    await writeFile(file('schema.json'), JSON.stringify(specSchema));
    const claude = [
      'exec "$CLAUDE" -p --restricted --safe-mode --strict-mcp-config --tools Read,Glob,Grep --allowedTools Read,Glob,Grep',
      '--permission-mode dontAsk --no-session-persistence --output-format stream-json --verbose',
      ...(model ? [`--model ${sh(model)}`] : []),
      `--json-schema "$(/bin/cat ${sh(file('schema.json'))})" --append-system-prompt "$(/bin/cat ${sh(file('system.txt'))})"`,
      `< ${sh(file('prompt.txt'))} > ${sh(file('out.jsonl'))} 2> ${sh(file('err.txt'))}`,
    ].join(' ');
    // A script run by /bin/sh, so the user's login shell (zsh, fish, ...) only has to run one plain command, and its
    // aliases (say, claude with permissions skipped) don't apply. Claude Code is looked up before the cd: after it, an
    // empty or "." entry in PATH would find an executable `claude` committed to the repository.
    await writeFile(
      file('run.sh'),
      [
        `CLAUDE=$(command -v claude) || { echo 'claude (Claude Code) is not on PATH' > ${sh(file('err.txt'))}; exit 127; }`,
        `cd ${sh(dir)} || exit 1`,
        `echo $$ > ${sh(file('pid'))}`,
        claude,
        '',
      ].join('\n'),
    );

    if (signal.aborted) throw new Error('cancelled');
    const created = await orca([
      'terminal', 'create', '--worktree', `path:${checkout}`, '--title', `Refine: ${job.task.title}`.slice(0, 80),
      '--command', `/bin/sh ${sh(file('run.sh'))}; exit`,
    ]);
    handle = (created.result as { terminal?: { handle?: string } } | undefined)?.terminal?.handle;
    if (!handle) throw fail(`Orca could not open a terminal for ${job.repository} (${created.error?.message}); add the checkout to Orca`);
    onEvent({ kind: 'model', data: { model: `claude/${model ?? 'default'}`, via: 'orca' } });

    const calls = new Map<string, { tool: string; target: string }>();
    let read = 0;
    let result: StreamLine | undefined;
    let sessionModel: string | undefined;
    // ponytail: rereads the whole transcript each second; keep a byte offset if long runs make this slow.
    const drain = async () => {
      const lines = (await readFile(file('out.jsonl'), 'utf8').catch(() => '')).split('\n');
      lines.pop(); // empty, or a line still being written
      for (const line of lines.slice(read)) {
        let e: StreamLine;
        try {
          e = JSON.parse(line);
        } catch {
          continue;
        }
        const content = Array.isArray(e.message?.content) ? e.message.content : [];
        for (const c of content) {
          if (c.type === 'tool_use' && c.id && c.name && c.name !== 'StructuredOutput') {
            const target = String(c.input?.file_path ?? c.input?.path ?? c.input?.pattern ?? '');
            // Paths relative to the export, so no machine paths leave the worker.
            const shown = path.isAbsolute(target) ? path.relative(dir, target) || '.' : target;
            calls.set(c.id, { tool: c.name.toLowerCase(), target: shown.slice(0, 300) });
          }
          const call = c.type === 'tool_result' && c.tool_use_id ? calls.get(c.tool_use_id) : undefined;
          if (call) onEvent({ kind: 'tool', data: { ...call, ok: !c.is_error } });
        }
        if (e.type === 'system' && e.model) sessionModel = e.model;
        if (e.type === 'result') result = e;
      }
      read = lines.length;
    };

    // Waiting a second at a time doubles as the poll interval for progress. The run is over when its result is written
    // (whatever Orca then says about the terminal), or when the terminal exits without one, e.g. the user closed the tab.
    for (;;) {
      if (signal.aborted) throw new Error('cancelled'); // a cancel, or the worker's deadline; finally stops Claude Code
      const waited = await orca(['terminal', 'wait', '--terminal', handle, '--for', 'exit', '--timeout-ms', '1000']);
      await drain();
      if (result || waited.ok) break;
      if (waited.error?.code !== 'timeout') throw fail(`lost the Orca terminal: ${waited.error?.message}`);
    }
    if (!result) {
      const err = (await readFile(file('err.txt'), 'utf8').catch(() => '')).trim();
      throw fail(`Claude Code ended without a result: ${err.slice(-500) || 'the Orca terminal was closed'}`);
    }
    if (result.is_error || !result.structured_output) throw fail(`Claude Code ended without a spec: ${result.result ?? result.subtype}`);
    return {
      spec: result.structured_output,
      model: `claude/${sessionModel ?? Object.keys(result.modelUsage ?? {})[0] ?? model ?? 'default'}`,
      sessionId: result.session_id,
      tokenUsage: result.usage,
      cost: result.total_cost_usd,
    };
  } finally {
    signal.removeEventListener('abort', close);
    await close(); // a no-op once the script exited; otherwise don't leave Claude Code running
    await rm(ctl, { recursive: true, force: true });
  }
}
