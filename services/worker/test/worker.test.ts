import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { OpencodeClient, Part } from '@opencode-ai/sdk/v2';
import { refine, toolEvent } from '../src/adapters/opencode.ts';
import { checkCheckout, escapingSymlinks, exportCommit, scrub, snapshot, verifyEvidence } from '../src/repository.ts';

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
