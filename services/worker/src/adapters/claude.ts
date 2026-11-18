import { spawn } from 'node:child_process';
import path from 'node:path';
import { createInterface } from 'node:readline';
import specSchema from '../../../../packages/contracts/refined-spec.schema.json' with { type: 'json' };
import { brief, type Job, REFINER_PROMPT, type RunEvent, type Spec } from './opencode.ts';

// --json-schema adds StructuredOutput, the tool the answer comes back through (seen in claude 2.1.325's init line).
const TOOLS = ['Glob', 'Grep', 'Read', 'StructuredOutput'];
const REFUSED = 'Claude Code started with tools beyond Read/Glob/Grep; refusing to run';
const STRAY = 'Claude Code called a tool beyond Read/Glob/Grep; stopped it';

/**
 * Claude Code in print mode with only Read/Glob/Grep: --restricted drops the built-in Bash/edit tools and refuses reads
 * outside the folder, and the user's MCP servers, skills, slash commands, hooks and saved sessions stay out.
 */
export function claudeArgs(o: { schema: object; prompt: string; systemPrompt: string; model?: string }) {
  return [
    '-p',
    '--restricted',
    '--strict-mcp-config',
    '--tools',
    'Read,Glob,Grep',
    '--disable-slash-commands',
    '--no-session-persistence',
    '--settings',
    JSON.stringify({ disableAllHooks: true }),
    '--output-format',
    'stream-json',
    '--verbose',
    '--json-schema',
    JSON.stringify(o.schema),
    '--append-system-prompt',
    o.systemPrompt,
    ...(o.model ? ['--model', o.model] : []),
    o.prompt,
  ];
}

type Content = { type?: string; id?: string; name?: string; input?: Record<string, unknown>; tool_use_id?: string; is_error?: boolean };
type Call = { tool: string; target: string };
export type ClaudeResult = Record<string, unknown> & { subtype?: string; is_error?: boolean; structured_output?: unknown };

/**
 * One line of `--output-format stream-json`. A tool call and its result arrive on separate lines, so `calls` (owned by
 * the caller) holds the calls still waiting for a result; each finished call becomes one event, like OpenCode's.
 */
export function parseClaudeLine(
  line: string,
  dir: string,
  calls: Map<string, Call>,
): { init: { tools: string[]; mcpServers: unknown[]; model?: string } } | { result: ClaudeResult } | { events: RunEvent[] } | undefined {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg?.type === 'system' && msg.subtype === 'init') return { init: { tools: msg.tools ?? [], mcpServers: msg.mcp_servers ?? [], model: msg.model } };
  if (msg?.type === 'result') return { result: msg };
  if (msg?.type !== 'assistant' && msg?.type !== 'user') return;
  const events: RunEvent[] = [];
  for (const c of (Array.isArray(msg.message?.content) ? msg.message.content : []) as Content[]) {
    if (msg.type === 'assistant' && c.type === 'tool_use' && c.id && c.name !== 'StructuredOutput') {
      const target = String(c.input?.file_path ?? c.input?.path ?? c.input?.pattern ?? '');
      const shown = path.isAbsolute(target) ? path.relative(dir, target) || '.' : target;
      calls.set(c.id, { tool: String(c.name).toLowerCase(), target: shown.slice(0, 300) });
    }
    const id = msg.type === 'user' && c.type === 'tool_result' ? (c.tool_use_id ?? '') : '';
    const call = calls.get(id);
    if (call) {
      calls.delete(id);
      events.push({ kind: 'tool', data: { ...call, ok: !c.is_error } });
    }
  }
  return { events };
}

/** Runs the Refiner with Claude Code in `dir` (an export of the commit); resolves with the structured spec. */
export async function refineWithClaude(opts: { dir: string; job: Job; commitSha: string; model?: string; onEvent: (e: RunEvent) => void; signal: AbortSignal }) {
  const { dir, onEvent, signal } = opts;
  const env = {
    ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_'))),
    // Relative or empty PATH entries resolve against cwd, the untrusted export: a committed `claude` would run instead.
    PATH: (process.env.PATH ?? '').split(path.delimiter).filter((p) => path.isAbsolute(p)).join(path.delimiter),
    DISABLE_AUTOUPDATER: '1',
  };
  const args = claudeArgs({ schema: specSchema, prompt: brief(opts.job, opts.commitSha), systemPrompt: REFINER_PROMPT, model: opts.model });
  const child = spawn('claude', args, { cwd: dir, env, stdio: ['ignore', 'pipe', 'pipe'] });
  const exited = new Promise<number | string | null>((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, sig) => resolve(code ?? sig));
  });
  exited.catch(() => {}); // awaited below; until then a spawn error must not count as unhandled

  let failure: string | undefined;
  const stop = (reason: string) => {
    failure ??= reason;
    if (!child.pid || child.exitCode !== null || child.signalCode !== null) return; // never started, or gone
    child.kill('SIGTERM');
    const kill = setTimeout(() => child.kill('SIGKILL'), 5000);
    child.once('exit', () => clearTimeout(kill));
  };
  const onAbort = () => stop('cancelled');
  signal.addEventListener('abort', onAbort, { once: true });
  if (signal.aborted) onAbort();

  let stderr = '';
  child.stderr.on('data', (d) => (stderr = (stderr + d).slice(-1000)));
  let init: { tools: string[]; mcpServers: unknown[]; model?: string } | undefined;
  let result: ClaudeResult | undefined;
  const calls = new Map<string, Call>();
  try {
    for await (const line of createInterface({ input: child.stdout })) {
      const parsed = parseClaudeLine(line, dir, calls);
      if (!parsed || failure) continue;
      if ('init' in parsed) {
        // Fail closed: anything that could write, run commands or reach out (an MCP server) means our flags didn't hold.
        if ([...parsed.init.tools].sort().join() !== TOOLS.join() || parsed.init.mcpServers.length) stop(REFUSED);
        else onEvent({ kind: 'model', data: { model: (init = parsed.init).model ?? 'claude' } });
      } else if (!init) stop(REFUSED); // work before the init line: nothing was checked
      // and again per call: the init line can't show a tool (a claude.ai connector, say) that connects after it.
      else if ('events' in parsed && [...calls.values()].some((c) => !TOOLS.some((t) => t.toLowerCase() === c.tool))) stop(STRAY);
      else if ('events' in parsed) parsed.events.forEach(onEvent);
      else result = parsed.result;
    }
    const code = await exited.catch((e: NodeJS.ErrnoException) => {
      throw new Error(e.code === 'ENOENT' ? 'Claude Code (`claude`) is not on the PATH' : e.message);
    });
    if (failure) throw new Error(failure);
    if (result?.subtype === 'success' && !result.is_error && result.structured_output) {
      return {
        spec: result.structured_output as Spec,
        model: init?.model ?? 'claude',
        sessionId: result.session_id as string | undefined,
        tokenUsage: result.usage as object | undefined,
        cost: result.total_cost_usd as number | undefined,
      };
    }
    if (result) throw new Error(`Claude Code failed: ${String(result.result || (result.errors as string[] | undefined)?.join('; ') || result.subtype)}`.slice(0, 1000));
    throw new Error(`Claude Code exited (${code}) without a result${stderr.trim() ? `: ${stderr.trim()}` : ''}`);
  } finally {
    signal.removeEventListener('abort', onAbort);
    stop('finished'); // only acts if it's still running, e.g. after a throw above
  }
}
