// A stdio MCP server that hands the coding agent specs a person approved in AI Kanban. Hand-rolled (newline-delimited
// JSON-RPC 2.0) instead of the SDK: it is three methods and two read-only tools, and it adds no dependency to a program
// that holds the worker token. Stdout carries protocol and nothing else; logs go to stderr.
import { createInterface } from 'node:readline';

type Config = { apiUrl: string; token: string; repositories: Record<string, string> };
type Api = (config: Config, method: string, url: string) => Promise<{ status: number; body: unknown }>;
type Spec = {
  taskId: string;
  title: string;
  board: string;
  repository: string;
  version: number;
  approvedAt: string;
  issue: { number: number; url: string; state: string } | null;
  commitSha?: string;
  content?: {
    title: string;
    summary: string;
    requirements: string[];
    acceptanceCriteria: string[];
    evidence: { path: string; startLine: number; endLine: number; note: string; verified?: boolean }[];
    ambiguities: string[];
    approach: string[];
    readiness: number;
  };
};

const VERSION = '0.1.0';
const VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const TOOLS = [
  {
    name: 'list_approved_specs',
    description: "Lists specs a person approved in AI Kanban, newest first, for this machine's allowed repositories (or one of them).",
    inputSchema: { type: 'object', properties: { repository: { type: 'string', description: 'owner/name; one of the repositories this worker may read' } } },
  },
  {
    name: 'get_spec',
    description: 'Returns one approved spec as Markdown: summary, acceptance criteria, requirements, evidence, approach and open questions.',
    inputSchema: { type: 'object', properties: { taskId: { type: 'string', description: 'a task id from list_approved_specs' } }, required: ['taskId'] },
  },
];

/** Titles and notes come from a board; keep each on one line so a list entry can't pose as another. */
const line = (s: string) => s.replace(/\s+/g, ' ').trim();
const issueLink = (s: Spec) => (s.issue ? `${s.issue.url} (${s.issue.state})` : 'no issue');

function markdown(s: Spec) {
  const c = s.content!;
  const list = (heading: string, items: string[], numbered = false) =>
    items.length ? [`## ${heading}`, ...items.map((item, i) => `${numbered ? `${i + 1}.` : '-'} ${item}`), ''] : [];
  return [
    "> Written by AI Kanban's read-only Refiner from the repository, and approved by a person.",
    '',
    `# ${line(c.title)}`,
    '',
    '## Summary',
    c.summary,
    '',
    ...list('Acceptance criteria', c.acceptanceCriteria),
    ...list('Requirements', c.requirements),
    ...list(
      'Evidence',
      c.evidence.map((e) => `\`${e.path}:${e.startLine}-${e.endLine}\` ${line(e.note)}${e.verified ? '' : ' (not verified against the commit)'}`),
    ),
    ...list('Suggested approach', c.approach, true),
    ...list('Open questions', c.ambiguities),
    `Readiness: ${c.readiness}/100`,
    `Commit: ${s.commitSha} (${s.repository}, spec version ${s.version})`,
    `Issue: ${issueLink(s)}`,
  ].join('\n');
}

class ToolError extends Error {}

export function serveMcp({ load, call }: { load: () => Promise<Config>; call: Api }) {
  const configured = () =>
    load().catch(() => {
      throw new ToolError('This worker is not set up; run `setup <code>` (or `connect <code>`) in services/worker first.');
    });
  const get = async <T>(config: Config, url: string) => {
    const res = await call(config, 'GET', url).catch((e: Error) => {
      throw new ToolError(`Could not reach the AI Kanban API: ${e.message}`);
    });
    if (res.status !== 200) throw new ToolError(`AI Kanban answered ${res.status}: ${(res.body as { message?: string } | undefined)?.message ?? JSON.stringify(res.body)}`);
    return res.body as T;
  };

  const tools: Record<string, (args: Record<string, unknown>) => Promise<string>> = {
    async list_approved_specs({ repository }) {
      if (repository !== undefined && typeof repository !== 'string') throw new ToolError('repository must be a string like owner/name');
      // The list endpoint treats "none given" as every board of the owner, so the worker's own list is always sent.
      const config = await configured();
      const allowed = Object.keys(config.repositories);
      const wanted = repository ? allowed.filter((r) => r.toLowerCase() === repository.toLowerCase()) : allowed;
      if (repository && !wanted.length) throw new ToolError(`${repository} is not allowed on this worker (allowed: ${allowed.join(', ') || 'none'})`);
      if (!wanted.length) throw new ToolError('No repositories are allowed on this worker yet; run `checkouts` or `allow <owner/name> <path>`.');
      const specs = await get<Spec[]>(config, `/worker/specs?${wanted.map((r) => `repository=${encodeURIComponent(r)}`).join('&')}`);
      if (!specs.length) return 'No approved specs.';
      return specs.map((s) => `- ${s.taskId}  ${line(s.title)}  (${s.repository}, v${s.version}, ${issueLink(s)})`).join('\n');
    },
    async get_spec({ taskId }) {
      if (typeof taskId !== 'string' || !UUID.test(taskId)) throw new ToolError('taskId must be a task id from list_approved_specs');
      return markdown(await get<Spec>(await configured(), `/worker/specs/${taskId}`));
    },
  };

  type Params = { protocolVersion?: string; name?: string; arguments?: Record<string, unknown> } | undefined;
  const handlers: Record<string, (params: Params) => Promise<object> | object> = {
    initialize: (p) => ({
      protocolVersion: p?.protocolVersion && VERSIONS.includes(p.protocolVersion) ? p.protocolVersion : '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'ai-kanban', version: VERSION },
    }),
    ping: () => ({}),
    'tools/list': () => ({ tools: TOOLS }),
    'tools/call': async (p) => {
      const tool = typeof p?.name === 'string' && Object.hasOwn(tools, p.name) ? tools[p.name] : undefined;
      if (!tool) throw Object.assign(new Error(`unknown tool ${JSON.stringify(p?.name)}`), { code: -32602 });
      try {
        return { content: [{ type: 'text', text: await tool(p?.arguments ?? {}) }] };
      } catch (e) {
        if (!(e instanceof ToolError)) console.error(e); // a bug here, not the caller's problem; still not a crash
        return { content: [{ type: 'text', text: e instanceof ToolError ? e.message : 'Internal error reading AI Kanban' }], isError: true };
      }
    },
  };

  const send = (message: object) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
  const pending = new Set<Promise<void>>();

  async function handle(raw: string) {
    let msg: { id?: unknown; method?: unknown; params?: Params };
    try {
      msg = JSON.parse(raw);
    } catch {
      return send({ id: null, error: { code: -32700, message: 'Parse error' } });
    }
    if (typeof msg !== 'object' || msg === null || Array.isArray(msg)) return send({ id: null, error: { code: -32600, message: 'Invalid Request' } });
    if (msg.id === undefined) return; // a notification: never answered, whatever it says
    if (typeof msg.method !== 'string') return; // a response to something we never asked
    const handler = Object.hasOwn(handlers, msg.method) ? handlers[msg.method] : undefined;
    if (!handler) return send({ id: msg.id, error: { code: -32601, message: `Method not found: ${msg.method}` } });
    try {
      send({ id: msg.id, result: await handler(msg.params) });
    } catch (e) {
      send({ id: msg.id, error: { code: (e as { code?: number }).code ?? -32603, message: (e as Error).message } });
    }
  }

  // One message per line; each is answered when ready, so a slow API call doesn't hold up a ping.
  const rl = createInterface({ input: process.stdin });
  rl.on('line', (text) => {
    if (!text.trim()) return;
    const p: Promise<void> = handle(text).then(() => {}).finally(() => pending.delete(p));
    pending.add(p);
  });
  return new Promise<void>((resolve) => rl.on('close', () => Promise.allSettled(pending).then(() => resolve())));
}
