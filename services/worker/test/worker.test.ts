import assert from 'node:assert/strict';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { promisify } from 'node:util';
import type { OpencodeClient, Part } from '@opencode-ai/sdk/v2';
import { claudeArgs, parseClaudeLine, refineWithClaude } from '../src/adapters/claude.ts';
import { refine, toolEvent } from '../src/adapters/opencode.ts';
import { checkCheckout, escapingSymlinks, exportCommit, githubCheckouts, scrub, snapshot, verifyEvidence } from '../src/repository.ts';
import { launchdPlist } from '../src/service.ts';

function repo(remote?: string) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'worker-test-'));
  const git = (...args: string[]) => execFileSync('git', ['-C', dir, ...args]);
  git('init', '-q');
  writeFileSync(path.join(dir, 'app.ts'), 'one\ntwo\nthree\n');
  git('add', '-A');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init');
  if (remote) git('remote', 'add', 'origin', remote);
  return dir;
}

const cite = (p: string, startLine = 1, endLine = 3) => ({ path: p, startLine, endLine, note: 'n' });

test('evidence is verified only for real lines inside the checkout', async () => {
  const dir = repo();
  writeFileSync(path.join(os.tmpdir(), 'outside.ts'), 'x\n');
  symlinkSync(path.join(os.tmpdir(), 'outside.ts'), path.join(dir, 'link.ts'));
  const out = await verifyEvidence(dir, [
    cite('app.ts'),
    cite(path.join(dir, 'app.ts')), // absolute, as models sometimes cite
    cite('app.ts', 2, 4), // one past the last line
    cite('app.ts', 3, 2),
    cite('missing.ts'),
    cite('../outside.ts', 1, 1),
    cite('link.ts', 1, 1), // a symlink out of the checkout
  ]);
  assert.deepEqual(out.map((e) => e.verified), [true, true, false, false, false, false, false]);
  assert.equal(out[1].path, 'app.ts', 'absolute paths are made relative');
});

test('checkouts must match the repository they are allowed as', async () => {
  const dir = repo('git@github.com:acme/web.app.git');
  assert.equal(await checkCheckout(dir, 'acme/web.app'), realpathSync(dir));
  await assert.rejects(checkCheckout(dir, 'acme/webxapp'), /no remote/);
  await assert.rejects(checkCheckout(dir, 'acme/other'), /no remote/);
  await assert.rejects(checkCheckout(os.tmpdir(), 'acme/web.app'));
  const local = repo(); // no remotes: nothing to contradict the name
  assert.equal(await checkCheckout(local, 'acme/anything'), realpathSync(local));
});

test('snapshot reports the commit and whether the tree is dirty', async () => {
  const dir = repo();
  const clean = await snapshot(dir);
  assert.match(clean.commitSha, /^[0-9a-f]{40}$/);
  assert.equal(clean.dirty, false);
  writeFileSync(path.join(dir, 'app.ts'), 'changed\n');
  assert.equal((await snapshot(dir)).dirty, true);
});

test('tool events carry relative paths and skip unfinished calls', () => {
  const part = (status: string, input: object) => ({ type: 'tool', tool: 'read', state: { status, input } }) as unknown as Part;
  assert.deepEqual(toolEvent(part('completed', { filePath: '/home/me/repo/src/a.ts' }), '/home/me/repo'), {
    kind: 'tool',
    data: { tool: 'read', target: 'src/a.ts', ok: true },
  });
  assert.equal(toolEvent(part('running', { filePath: '/home/me/repo/a.ts' }), '/home/me/repo'), undefined);
  assert.deepEqual(toolEvent(part('error', { pattern: 'login' }), '/home/me/repo')?.data, { tool: 'read', target: 'login', ok: false });
});

test('symlinks out of the folder are found, tracked or not; links inside it are fine', async () => {
  const dir = repo();
  const outside = path.join(mkdtempSync(path.join(os.tmpdir(), 'outside-')), 'id_ed25519');
  writeFileSync(outside, 'secret\n');
  symlinkSync(outside, path.join(dir, 'setup.md'));
  mkdirSync(path.join(dir, 'node_modules'));
  symlinkSync(path.dirname(outside), path.join(dir, 'node_modules', 'linked'));
  symlinkSync('app.ts', path.join(dir, 'alias.ts'));
  symlinkSync('/nonexistent/x', path.join(dir, 'dangling.md'));
  assert.deepEqual((await escapingSymlinks(dir)).sort(), ['node_modules/linked', 'setup.md']);
});

test('the export runs no smudge filter, so encrypted files stay encrypted', async () => {
  const dir = repo();
  const git = (...args: string[]) => execFileSync('git', ['-C', dir, ...args]);
  writeFileSync(path.join(dir, '.gitattributes'), 'secret.txt filter=crypt\n');
  writeFileSync(path.join(dir, 'secret.txt'), 'ciphertext\n');
  git('add', '-A');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'secret');
  git('config', 'filter.crypt.smudge', 'tr a-z A-Z'); // stands in for git-crypt's decrypting smudge
  git('config', 'filter.crypt.clean', 'cat');
  const work = await exportCommit(dir, (await snapshot(dir)).commitSha);
  try {
    assert.equal(readFileSync(path.join(work, 'secret.txt'), 'utf8'), 'ciphertext\n');
  } finally {
    rmSync(work, { recursive: true });
  }
});

test('the export holds only the committed files', async () => {
  const dir = repo();
  writeFileSync(path.join(dir, '.gitignore'), '.env\n');
  execFileSync('git', ['-C', dir, 'add', '-A']);
  execFileSync('git', ['-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'ignore']);
  writeFileSync(path.join(dir, '.env'), 'SECRET=1\n');
  writeFileSync(path.join(dir, 'notes.txt'), 'untracked\n');
  writeFileSync(path.join(dir, 'app.ts'), 'uncommitted\n');
  const work = await exportCommit(dir, (await snapshot(dir)).commitSha);
  try {
    assert.equal(work, realpathSync(work));
    assert.deepEqual(readdirSync(work).sort(), ['.gitignore', 'app.ts']);
    assert.equal(readFileSync(path.join(work, 'app.ts'), 'utf8'), 'one\ntwo\nthree\n');
  } finally {
    rmSync(work, { recursive: true });
  }
});

test('machine paths are scrubbed from text that leaves the worker', async () => {
  const dir = repo();
  const text = `Command failed: git -C ${dir} status; see ${path.join(realpathSync(dir), 'src/a.ts')} and ${os.homedir()}/notes`;
  assert.equal(await scrub(dir, text), 'Command failed: git -C . status; see src/a.ts and ~/notes');
});

test('refine takes the answer to its own prompt, however many agent steps it took', async () => {
  const spec = { title: 'Spec', evidence: [] };
  // An earlier prompt and its answer, then this prompt: 12 steps, each its own assistant message, the last with the spec.
  // Like OpenCode 1.19.3, a read that includes a prompt sent with a format fails, and `limit` keeps the newest.
  const msgs: { info: Record<string, unknown> }[] = [
    { info: { role: 'user', id: 'msg_00' } },
    { info: { role: 'assistant', id: 'msg_01', parentID: 'msg_00' } },
  ];
  let polls = 0;
  const client = {
    session: {
      create: async () => ({ data: { id: 's1' } }),
      abort: async () => ({}),
      promptAsync: async () => {
        msgs.push({ info: { role: 'user', id: 'msg_02' } });
        for (let i = 1; i <= 12; i++) {
          const id = `msg_${String(i + 2).padStart(2, '0')}`;
          msgs.push({ info: { role: 'assistant', id, parentID: 'msg_02', ...(i === 12 ? { structured: spec } : {}) } });
        }
        return {};
      },
      status: async () => ({ data: ++polls === 1 ? { s1: { type: 'busy' } } : {} }),
      messages: async ({ limit }: { limit?: number }) => {
        const page = limit ? msgs.slice(-limit) : msgs;
        return page.some((m) => m.info.role === 'user') ? { error: { name: 'BadRequest' } } : { data: page };
      },
    },
    event: { subscribe: async () => ({ stream: (async function* () {})() }) },
    instance: { dispose: async () => ({}) },
  } as unknown as OpencodeClient;
  const job = { id: 'r1', repository: 'acme/web', task: { title: 'Add login', description: '' } };
  const result = await refine({ client, dir: '/x', job, commitSha: 'abc', models: ['opencode/m'], onEvent: () => {}, signal: new AbortController().signal });
  assert.equal(result.spec, spec);
  assert.equal(polls, 2, 'waited while the session was busy');
});

const fixture = (name: string) => path.join(import.meta.dirname, 'fixtures', name);
const CLI = path.join(import.meta.dirname, '..', 'src', 'cli.ts');
const tmp = () => realpathSync(mkdtempSync(path.join(os.tmpdir(), 'worker-test-')));
const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

// A fake `claude` on the PATH. It records how it was started, then plays the mode in FAKE_CLAUDE: the captured
// stream (success), an init line with an extra tool, an error result, or a hang that honours or ignores SIGTERM.
const bin = tmp();
writeFileSync(
  path.join(bin, 'claude'),
  `#!/usr/bin/env node
const fs = require('node:fs');
fs.writeFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ argv: process.argv.slice(2), cwd: process.cwd(), env: process.env, pid: process.pid }));
const out = (o) => process.stdout.write(JSON.stringify(o) + '\\n');
const init = { type: 'system', subtype: 'init', tools: ['Glob', 'Grep', 'Read', 'StructuredOutput'], mcp_servers: [], model: 'm' };
const mode = process.env.FAKE_CLAUDE;
if (mode === 'success') process.stdout.write(fs.readFileSync(${JSON.stringify(fixture('claude-stream.jsonl'))}, 'utf8').replaceAll('/private/tmp/ai-kanban-run-x', process.cwd()));
else if (mode === 'tools' || mode === 'mcp')
  out(mode === 'tools' ? { ...init, tools: [...init.tools, 'Bash'] } : { ...init, mcp_servers: [{ name: 'mail', status: 'connected' }] }),
    setTimeout(() => out({ type: 'result', subtype: 'success', structured_output: {} }), 1000);
else if (mode === 'error') out(init), out({ type: 'result', subtype: 'success', is_error: true, result: 'API Error: 401 Invalid authentication credentials' });
else out(init);
if (mode === 'stubborn') process.on('SIGTERM', () => {});
if (mode === 'hang' || mode === 'stubborn') setInterval(() => {}, 1000);
if (mode === 'stubborn') setTimeout(() => process.exit(), 8000); // so a missing SIGKILL fails the test instead of hanging it
`,
);
chmodSync(path.join(bin, 'claude'), 0o755);
process.env.PATH = `${bin}${path.delimiter}${process.env.PATH}`;

const job = { id: 'r1', repository: 'acme/web', task: { title: 'Document hello.txt', description: '' } };
async function claude(mode: string, signal = new AbortController().signal) {
  const dir = tmp();
  const log = path.join(tmp(), 'claude.json');
  process.env.FAKE_CLAUDE = mode;
  process.env.FAKE_CLAUDE_LOG = log;
  const events: unknown[] = [];
  const result = refineWithClaude({ dir, job, commitSha: 'abc', signal, onEvent: (e) => events.push(e) });
  const started = () => JSON.parse(readFileSync(log, 'utf8'));
  return { dir, result, events, started };
}

test('claudeArgs allows only reading tools and puts the brief last', () => {
  const args = claudeArgs({ schema: { type: 'object' }, prompt: 'Task brief', systemPrompt: 'You are the Refiner.' });
  assert.deepEqual(args, [
    '-p',
    '--restricted',
    '--strict-mcp-config',
    '--tools',
    'Read,Glob,Grep',
    '--disable-slash-commands',
    '--no-session-persistence',
    '--settings',
    '{"disableAllHooks":true}',
    '--output-format',
    'stream-json',
    '--verbose',
    '--json-schema',
    '{"type":"object"}',
    '--append-system-prompt',
    'You are the Refiner.',
    'Task brief',
  ]);
  const withModel = claudeArgs({ schema: {}, prompt: 'p', systemPrompt: 's', model: 'sonnet' });
  assert.deepEqual(withModel.slice(-3), ['--model', 'sonnet', 'p']);
});

test('parseClaudeLine turns a captured stream into init, one event per finished tool call, and the result', () => {
  const calls = new Map();
  const parsed = readFileSync(fixture('claude-stream.jsonl'), 'utf8')
    .split('\n')
    .map((line) => parseClaudeLine(line, '/private/tmp/ai-kanban-run-x', calls));
  const init = parsed.find((p) => p && 'init' in p);
  assert.deepEqual(init, { init: { tools: ['Glob', 'Grep', 'Read', 'StructuredOutput'], mcpServers: [], model: 'claude-fable-5-2' } });
  const events = parsed.flatMap((p) => (p && 'events' in p ? p.events : []));
  assert.deepEqual(events, [
    { kind: 'tool', data: { tool: 'read', target: 'hello.txt', ok: true } },
    { kind: 'tool', data: { tool: 'read', target: 'missing.txt', ok: false } }, // StructuredOutput isn't one
  ]);
  const result = parsed.find((p) => p && 'result' in p);
  assert.ok(result && 'result' in result);
  assert.equal(result.result.subtype, 'success');
  assert.equal((result.result.structured_output as { title: string }).title, 'Document hello.txt');
  assert.equal(calls.size, 0, 'every call got its result');
  assert.equal(parseClaudeLine('not json', '/x', calls), undefined);
  assert.equal(parseClaudeLine('{"type":"system","subtype":"session_state_changed"}', '/x', calls), undefined);
});

test('refineWithClaude runs claude in the export with a clean environment and returns the spec', async () => {
  process.env.GIT_DIR = '/somewhere/.git'; // as when the worker is started from a git hook
  try {
    const { dir, result, events, started } = await claude('success');
    const out = await result;
    assert.equal((out.spec as { title?: string }).title, 'Document hello.txt');
    assert.equal(out.model, 'claude-fable-5-2');
    assert.equal(out.cost, 0.1490187);
    assert.equal(out.sessionId, '00000000-0000-0000-0000-000000000000');
    assert.equal((out.tokenUsage as { output_tokens: number }).output_tokens, 576);
    assert.deepEqual(events, [
      { kind: 'model', data: { model: 'claude-fable-5-2' } },
      { kind: 'tool', data: { tool: 'read', target: 'hello.txt', ok: true } },
      { kind: 'tool', data: { tool: 'read', target: 'missing.txt', ok: false } },
    ]);
    const run = started();
    assert.equal(run.cwd, dir);
    assert.equal(run.env.GIT_DIR, undefined);
    assert.equal(run.env.DISABLE_AUTOUPDATER, '1');
    assert.deepEqual(run.argv.slice(0, 3), ['-p', '--restricted', '--strict-mcp-config']);
    assert.match(run.argv.at(-1), /^Task brief\nTitle: Document hello.txt\n/);
  } finally {
    delete process.env.GIT_DIR;
  }
});

test('refineWithClaude refuses a claude that starts with more tools or an MCP server, and kills it', async () => {
  for (const mode of ['tools', 'mcp']) {
    const { result, started } = await claude(mode);
    await assert.rejects(result, /tools beyond Read\/Glob\/Grep; refusing to run/);
    assert.equal(alive(started().pid), false);
  }
});

test('refineWithClaude fails with the error claude reports', async () => {
  await assert.rejects((await claude('error')).result, /Claude Code failed: API Error: 401/);
});

test('refineWithClaude kills a claude that ignores SIGTERM once aborted', async () => {
  const ac = new AbortController();
  const { result, started } = await claude('stubborn', ac.signal);
  while (!existsSync(process.env.FAKE_CLAUDE_LOG!)) await sleep(20);
  await sleep(200); // let it install its SIGTERM handler
  const t0 = Date.now();
  ac.abort();
  await assert.rejects(result, /cancelled/);
  const waited = Date.now() - t0;
  assert.ok(waited >= 4900 && waited < 7000, `SIGKILL comes 5 s after SIGTERM (took ${waited} ms)`);
  assert.equal(alive(started().pid), false);
});

test('launchdPlist runs start with absolute paths, a usable PATH and no token', () => {
  const o = {
    node: '/opt/homebrew/bin/node',
    cli: '/Users/me/code/ai-kanban/services/worker/src/cli.ts',
    config: '/Users/me/.config/ai-kanban/worker.json',
    path: '/Users/me/.local/bin:node_modules/.bin::/opt/homebrew/bin:/usr/bin',
    log: '/Users/me/Library/Logs/ai-kanban-worker.log',
  };
  const plist = launchdPlist(o);
  assert.match(plist, /<key>Label<\/key><string>ai\.kanban\.worker<\/string>/);
  assert.match(plist, new RegExp(`<array><string>${o.node}</string><string>${o.cli}</string><string>start</string></array>`));
  assert.match(plist, /<key>RunAtLoad<\/key><true\/>/);
  assert.match(plist, /<key>KeepAlive<\/key>\s*<dict><key>SuccessfulExit<\/key><false\/><\/dict>/);
  assert.match(plist, new RegExp(`<key>AI_KANBAN_WORKER_CONFIG</key><string>${o.config}</string>`));
  assert.match(plist, /<key>PATH<\/key><string>\/Users\/me\/\.local\/bin:\/opt\/homebrew\/bin:\/usr\/bin:\/bin:\/usr\/sbin:\/sbin<\/string>/);
  assert.equal(plist.match(new RegExp(`<string>${o.log}</string>`, 'g'))?.length, 2, 'stdout and stderr');
  assert.doesNotMatch(plist, /wkr_|token/i);
  assert.throws(() => launchdPlist({ ...o, config: 'worker.json' }), /absolute/);
  if (process.platform === 'darwin') {
    const file = path.join(tmp(), 'worker.plist');
    writeFileSync(file, plist);
    execFileSync('plutil', ['-lint', file]);
  }
});

test('githubCheckouts keeps the git checkouts whose remote is on GitHub', () => {
  assert.deepEqual(githubCheckouts(JSON.parse(readFileSync(fixture('orca-repo-list.json'), 'utf8'))), [
    { repository: 'acme/web', path: '/Users/someone/code/web' },
    { repository: 'acme/api.v2', path: '/Users/someone/code/api' },
  ]);
  assert.deepEqual(githubCheckouts({}), []);
});

type Route = (body: Record<string, unknown>) => [number, object?] | Promise<[number, object?]>;
async function fakeApi(routes: Record<string, Route>) {
  const requests: { route: string; body: Record<string, unknown> }[] = [];
  const server = createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const route = `${req.method} ${req.url}`;
    const body = raw ? JSON.parse(raw) : {};
    requests.push({ route, body });
    const [status, out] = (await routes[route]?.(body)) ?? [404, { message: 'not found' }];
    res.writeHead(status, out ? { 'content-type': 'application/json' } : {}).end(out ? JSON.stringify(out) : undefined);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, requests, close: () => server.close() };
}

test('connect pairs with a code and keeps the checkouts only for the same API and account', async () => {
  const api = await fakeApi({
    'POST /workers/pair': (b) =>
      b.code === 'BAD' ? [400, { message: 'invalid or expired code' }] : [201, { id: 'w1', name: b.name, ownerId: b.code === 'THEIRS' ? 'u2' : 'u1', token: 'wkr_new' }],
  });
  const config = path.join(tmp(), 'worker.json');
  const cli = (...args: string[]) => promisify(execFile)(process.execPath, [CLI, ...args], { env: { ...process.env, AI_KANBAN_WORKER_CONFIG: config } });
  const read = () => JSON.parse(readFileSync(config, 'utf8'));
  const cleared = /Cleared the allowed repositories: the account or API changed/;
  const previous = { apiUrl: api.url, token: 'wkr_old', name: 'old', ownerId: 'u1', repositories: { 'acme/web': '/x' }, models: ['m'], refiner: 'claude' };
  try {
    writeFileSync(config, JSON.stringify(previous));
    const { stdout } = await cli('connect', 'abcde-fghjk', '--name', 'My Mac');
    assert.deepEqual(api.requests.at(-1), { route: 'POST /workers/pair', body: { code: 'abcde-fghjk', name: 'My Mac' } });
    assert.deepEqual(read(), { ...previous, token: 'wkr_new', name: 'My Mac' });
    assert.doesNotMatch(stdout, cleared);
    assert.equal(statSync(config).mode & 0o777, 0o600);

    writeFileSync(config, JSON.stringify(previous));
    assert.match((await cli('connect', 'THEIRS')).stdout, cleared);
    assert.deepEqual([read().repositories, read().ownerId], [{}, 'u2'], "someone else's code starts with no checkouts");

    const { ownerId, ...unowned } = previous;
    writeFileSync(config, JSON.stringify(unowned));
    assert.match((await cli('connect', 'CODE')).stdout, cleared);
    assert.deepEqual([read().repositories, read().ownerId], [{}, ownerId], 'a config from before owners were recorded starts with no checkouts');

    writeFileSync(config, JSON.stringify({ ...previous, apiUrl: 'http://elsewhere.example' }));
    await cli('connect', 'CODE', '--api', api.url, '--name', 'My Mac');
    assert.deepEqual(read().repositories, {}, 'a different API starts with no checkouts');
    assert.equal(read().apiUrl, api.url);

    await assert.rejects(cli('connect', 'BAD'), /pairing failed \(400\): invalid or expired code/);
  } finally {
    api.close();
  }
});

test('SIGTERM during a job releases the run, stops the agent and exits 0', async () => {
  const RUN = '00000000-0000-0000-0000-0000000000aa';
  let claims = 0;
  const api = await fakeApi({
    'GET /worker/me': () => [200, { id: 'w1', name: 'My Mac' }],
    'POST /worker/claim': () => (claims++ ? [204] : [200, { ...job, id: RUN }]),
    [`POST /worker/runs/${RUN}/events`]: () => [204],
    [`POST /worker/runs/${RUN}/release`]: () => [204],
  });
  const config = path.join(tmp(), 'worker.json');
  const log = path.join(tmp(), 'claude.json');
  writeFileSync(config, JSON.stringify({ apiUrl: api.url, token: 'wkr_t', name: 'My Mac', repositories: { 'acme/web': repo() }, models: [], refiner: 'claude' }));
  const child = spawn(process.execPath, [CLI, 'start'], {
    env: { ...process.env, AI_KANBAN_WORKER_CONFIG: config, FAKE_CLAUDE: 'hang', FAKE_CLAUDE_LOG: log },
    stdio: 'ignore',
  });
  try {
    for (const t0 = Date.now(); !existsSync(log); await sleep(50)) assert.ok(Date.now() - t0 < 15_000, 'the agent started');
    await sleep(200);
    child.kill('SIGTERM');
    const [code] = await once(child, 'exit');
    assert.equal(code, 0);
    const routes = api.requests.map((r) => r.route);
    assert.ok(routes.includes(`POST /worker/runs/${RUN}/release`));
    assert.ok(!routes.some((r) => r.endsWith('/fail') || r.endsWith('/complete')));
    assert.equal(alive(JSON.parse(readFileSync(log, 'utf8')).pid), false);
  } finally {
    child.kill('SIGKILL');
    api.close();
  }
});

const RUN = '00000000-0000-0000-0000-0000000000aa';
const me: Route = () => [200, { id: 'w1', name: 'My Mac', ownerId: 'u1' }];
/** A config and `start` against `api`, with the fake claude in `mode` (its log tells when it started). */
function worker(api: { url: string }, mode: string, overrides: object = {}) {
  const dir = tmp();
  const config = path.join(dir, 'worker.json');
  const log = path.join(dir, 'claude.json');
  writeFileSync(config, JSON.stringify({ apiUrl: api.url, token: 'wkr_t', name: 'My Mac', repositories: { 'acme/web': repo() }, refiner: 'claude', ...overrides }));
  const env = { ...process.env, AI_KANBAN_WORKER_CONFIG: config, FAKE_CLAUDE: mode, FAKE_CLAUDE_LOG: log };
  const start = () => spawn(process.execPath, [CLI, 'start'], { env, stdio: ['ignore', 'pipe', 'inherit'] });
  return { config, log, lock: path.join(dir, 'worker.lock'), start };
}
const until = async (what: string, ok: () => boolean, ms = 15_000) => {
  for (const t0 = Date.now(); !ok(); await sleep(50)) assert.ok(Date.now() - t0 < ms, what);
};

test('a second start on the same config waits for the first instead of claiming; a stale lock is taken over', async () => {
  let claims = 0;
  const api = await fakeApi({
    'GET /worker/me': me,
    'POST /worker/claim': () => (claims++ ? [204] : [200, { ...job, id: RUN }]),
    [`POST /worker/runs/${RUN}/events`]: () => [204],
    [`POST /worker/runs/${RUN}/release`]: () => [204],
  });
  const w = worker(api, 'hang');
  const gone = spawn(process.execPath, ['-e', '']);
  await once(gone, 'exit');
  writeFileSync(w.lock, String(gone.pid)); // left by a worker that was killed
  const first = w.start();
  let second: ReturnType<typeof w.start> | undefined;
  try {
    await until('the first worker took the stale lock and started the agent', () => existsSync(w.log));
    assert.equal(readFileSync(w.lock, 'utf8'), String(first.pid));
    second = w.start();
    let out = '';
    second.stdout!.on('data', (d) => (out += d));
    await until('the second worker says it waits', () => out.includes(`Another worker process (pid ${first.pid}) is using ${w.config}; waiting`));
    await sleep(1000);
    assert.equal(claims, 1, 'only the first worker claimed');
    second.kill('SIGKILL');
    first.kill('SIGTERM');
    assert.deepEqual(await once(first, 'exit'), [0, null]);
    assert.equal(existsSync(w.lock), false, 'the lock goes with the worker');
  } finally {
    first.kill('SIGKILL');
    second?.kill('SIGKILL');
    api.close();
  }
});

test('SIGTERM while a claim is in flight hands the claimed run back without starting it', async () => {
  const api = await fakeApi({
    'GET /worker/me': me,
    'POST /worker/claim': async () => (await sleep(1500), [200, { ...job, id: RUN }]),
    [`POST /worker/runs/${RUN}/release`]: () => [204],
  });
  const w = worker(api, 'hang', { refiner: undefined }); // OpenCode, and no models: the built-in ones are used
  const child = w.start();
  try {
    await until('the worker claimed', () => api.requests.some((r) => r.route === 'POST /worker/claim'));
    child.kill('SIGTERM');
    assert.deepEqual(await once(child, 'exit'), [0, null]);
    assert.deepEqual(api.requests.map((r) => r.route).slice(-2), ['POST /worker/claim', `POST /worker/runs/${RUN}/release`]);
  } finally {
    child.kill('SIGKILL');
    api.close();
  }
});

test('a spec the API failed to take (503) is handed in again, not failed', async () => {
  let claims = 0;
  let completes = 0;
  const api = await fakeApi({
    'GET /worker/me': me,
    'POST /worker/claim': () => (claims++ ? [204] : [200, { ...job, id: RUN }]),
    [`POST /worker/runs/${RUN}/events`]: () => [204],
    [`POST /worker/runs/${RUN}/complete`]: () => (completes++ ? [200, { version: 1 }] : [503, { message: 'unavailable' }]),
    [`POST /worker/runs/${RUN}/fail`]: () => [204],
  });
  const child = worker(api, 'success').start();
  try {
    await until('the spec was handed in twice', () => completes === 2);
    await sleep(200);
    assert.equal(completes, 2);
    assert.ok(!api.requests.some((r) => r.route.endsWith('/fail')));
  } finally {
    child.kill('SIGKILL');
    api.close();
  }
});
