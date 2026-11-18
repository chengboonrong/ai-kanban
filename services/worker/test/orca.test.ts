import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { refineWithOrca } from '../src/adapters/orca.ts';

// Stand-ins for the Orca CLI and Claude Code: `terminal create` runs --command in the background, `terminal wait`
// reports whether it is still running, `terminal close` kills it. `claude` records how it was started and prints a
// canned stream-json transcript.
const state = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'orca-fake-')));
const bin = path.join(state, 'bin');
mkdirSync(bin);
const script = (name: string, body: string) => {
  writeFileSync(path.join(bin, name), `#!/bin/sh\nS='${state}'\n${body}`);
  chmodSync(path.join(bin, name), 0o755);
};
script(
  'orca',
  `case "$1 $2" in
  "terminal create")
    shift 2
    while [ $# -gt 0 ]; do case "$1" in --command) cmd="$2"; shift;; --worktree) echo "$2" > "$S/worktree"; shift;; --title) shift;; esac; shift; done
    sh -c "$cmd" > /dev/null 2>&1 &
    echo $! > "$S/pid"
    echo '{"ok":true,"result":{"terminal":{"handle":"term_1"}}}';;
  "terminal wait")
    if [ -f "$S/stale" ] && ! kill -0 "$(cat "$S/pid")" 2>/dev/null; then echo '{"ok":false,"error":{"code":"terminal_handle_stale","message":"stale"}}'; exit 1; fi
    if kill -0 "$(cat "$S/pid")" 2>/dev/null; then sleep 0.2; echo '{"ok":false,"error":{"code":"timeout","message":"timeout"}}'; exit 1; fi
    echo '{"ok":true,"result":{"wait":{"satisfied":true}}}';;
  "terminal close")
    pkill -P "$(cat "$S/pid")" 2>/dev/null; kill "$(cat "$S/pid")" 2>/dev/null; touch "$S/closed"
    echo '{"ok":true,"result":{}}';;
esac`,
);
script(
  'claude',
  `pwd > "$S/cwd"; printf '%s\\n' "$@" > "$S/args"; cat > "$S/stdin"
[ -f "$S/slow" ] && sleep 30
cat "$S/stream.jsonl"`,
);
// "." first: a repository can't get its own `claude` run that way (run.sh finds Claude Code before it enters the export).
process.env.PATH = `.:${bin}:${process.env.PATH}`;
const temp = [state];
const exportDir = () => {
  const dir = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'orca-export-')));
  temp.push(dir);
  return dir;
};
after(() => temp.forEach((d) => rmSync(d, { recursive: true, force: true })));

const job = { id: 'r1', repository: 'acme/app', task: { title: "Add Bob's login", description: 'Use GitHub' } };
const line = (o: object) => JSON.stringify(o);

test('runs read-only Claude Code in an Orca terminal and returns its spec and tool events', async () => {
  const dir = exportDir();
  writeFileSync(path.join(dir, 'claude'), `#!/bin/sh\ntouch '${state}/planted'\n`, { mode: 0o755 }); // committed to the repo
  const spec = { title: 'Add login', evidence: [] };
  writeFileSync(
    path.join(state, 'stream.jsonl'),
    [
      line({ type: 'system', subtype: 'init', model: 'claude-sonnet-5-5' }),
      line({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: path.join(dir, 'src/app.ts') } }] } }),
      line({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't1', is_error: false }] } }),
      line({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 't2', name: 'Read', input: { file_path: '/etc/passwd' } }] } }),
      line({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't2', is_error: true }] } }),
      line({ type: 'result', subtype: 'success', is_error: false, structured_output: spec, session_id: 's1', total_cost_usd: 0.01, usage: { output_tokens: 5 }, modelUsage: { 'claude-haiku-5-5': {}, 'claude-sonnet-5-5': {} } }),
    ].join('\n') + '\n',
  );
  const events: object[] = [];
  const result = await refineWithOrca({
    checkout: '/repos/app',
    dir,
    job,
    commitSha: 'a'.repeat(40),
    model: "it's-a-model",
    onEvent: (e) => events.push(e),
    signal: new AbortController().signal,
  });

  assert.deepEqual(result, { spec, model: 'claude/claude-sonnet-5-5', sessionId: 's1', tokenUsage: { output_tokens: 5 }, cost: 0.01 });
  assert.deepEqual(events.slice(1), [
    { kind: 'tool', data: { tool: 'read', target: 'src/app.ts', ok: true } },
    { kind: 'tool', data: { tool: 'read', target: path.relative(dir, '/etc/passwd'), ok: false } },
  ]);
  assert.equal(readFileSync(path.join(state, 'worktree'), 'utf8').trim(), 'path:/repos/app', 'the terminal opens in the checkout');
  assert.equal(readFileSync(path.join(state, 'cwd'), 'utf8').trim(), dir, 'Claude Code runs in the export');
  const args = readFileSync(path.join(state, 'args'), 'utf8').split('\n');
  for (const flag of ['--restricted', '--safe-mode', '--strict-mcp-config']) assert.ok(args.includes(flag), flag);
  assert.equal(args[args.indexOf('--tools') + 1], 'Read,Glob,Grep');
  assert.equal(args[args.indexOf('--permission-mode') + 1], 'dontAsk');
  assert.equal(args[args.indexOf('--model') + 1], "it's-a-model", 'quoting survives the shell');
  assert.ok(JSON.parse(args[args.indexOf('--json-schema') + 1]).properties, 'the spec schema is passed');
  for (const flag of ['--allowedTools', '--no-session-persistence', '--append-system-prompt']) assert.ok(args.includes(flag), flag);
  assert.match(readFileSync(path.join(state, 'stdin'), 'utf8'), /Title: Add Bob's login\nDescription:\nUse GitHub/);
  assert.ok(!existsSync(path.join(state, 'planted')), "the repository's own claude never runs");

  // A result already written counts even if Orca then loses track of the terminal.
  writeFileSync(path.join(state, 'stale'), '');
  try {
    const again = await refineWithOrca({ checkout: '/repos/app', dir, job, commitSha: 'a'.repeat(40), onEvent: () => {}, signal: new AbortController().signal });
    assert.deepEqual(again.spec, spec);
  } finally {
    rmSync(path.join(state, 'stale'));
  }
});

test('cancelling closes the Orca terminal; a run without a result fails', async () => {
  const dir = exportDir();
  writeFileSync(path.join(state, 'slow'), '');
  const ac = new AbortController();
  setTimeout(() => ac.abort(new Error('cancelled')), 500);
  const opts = { checkout: '/repos/app', dir, job, commitSha: 'a'.repeat(40), onEvent: () => {}, signal: ac.signal };
  await assert.rejects(refineWithOrca(opts), /cancelled/);
  assert.ok(existsSync(path.join(state, 'closed')));

  rmSync(path.join(state, 'slow'));
  writeFileSync(path.join(state, 'stream.jsonl'), line({ type: 'system', subtype: 'init' }) + '\n');
  await assert.rejects(refineWithOrca({ ...opts, signal: new AbortController().signal }), /ended without a result/);
});
