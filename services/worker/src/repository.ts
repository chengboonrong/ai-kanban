import { execFile } from 'node:child_process';
import { mkdtemp, readdir, readFile, realpath, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const git = async (dir: string, ...args: string[]) => (await promisify(execFile)('git', ['-C', dir, ...args])).stdout.trim();

/** The commit the agent reads, and whether the working tree has uncommitted changes (which the agent doesn't see). */
export async function snapshot(dir: string) {
  return { commitSha: await git(dir, 'rev-parse', 'HEAD'), dirty: (await git(dir, 'status', '--porcelain')) !== '' };
}

/** Checks that `dir` is the top of a git checkout and, when it has remotes, that one of them is `owner/name` on GitHub. */
export async function checkCheckout(dir: string, repository: string) {
  const top = await realpath(await git(dir, 'rev-parse', '--show-toplevel'));
  if (top !== (await realpath(dir))) throw new Error(`${dir} is inside a checkout; use its top folder ${top}`);
  const remotes = (await git(dir, 'remote', '-v')).split('\n').filter(Boolean);
  const matches = remotes.some((r) => new RegExp(`github\\.com[:/]${repository.replaceAll('.', '\\.')}(\\.git)?\\s`, 'i').test(r));
  if (remotes.length && !matches) throw new Error(`no remote of ${dir} points at github.com/${repository}`);
  return top;
}

type Evidence = { path: string; startLine: number; endLine: number; note: string; verified?: boolean };

/** Marks each citation verified only if the file is inside the checkout and has the cited lines. */
export async function verifyEvidence(dir: string, evidence: Evidence[]): Promise<Evidence[]> {
  const root = await realpath(dir);
  return Promise.all(
    evidence.map(async (e) => {
      // Models sometimes cite absolute paths, via the folder as given or its real path.
      const relative = path.isAbsolute(e.path) ? path.relative(e.path.startsWith(root) ? root : path.resolve(dir), e.path) : e.path;
      const cited = { ...e, path: relative };
      try {
        const file = await realpath(path.join(root, relative));
        if (!file.startsWith(root + path.sep) || e.startLine > e.endLine) return { ...cited, verified: false };
        const text = await readFile(file, 'utf8');
        const lines = text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
        return { ...cited, verified: e.endLine <= lines };
      } catch {
        return { ...cited, verified: false };
      }
    }),
  );
}

/**
 * Extracts `commitSha` into a fresh folder for the agent: the committed blobs only, so untracked or ignored files
 * (.env, .npmrc, build output), .git and local changes never reach it. No smudge filter runs either, so git-crypt files
 * stay encrypted and LFS files stay pointers, as on GitHub. Delete it with `rm(folder, { recursive: true })`.
 * ponytail: copies the whole tree per run; a cached export per commit if large repos make this slow.
 */
export async function exportCommit(dir: string, commitSha: string) {
  // Its real path: OpenCode reports paths that way (macOS's /var is /private/var), and events are made relative to it.
  const folder = await realpath(await mkdtemp(path.join(os.tmpdir(), 'ai-kanban-run-')));
  const staging = await mkdtemp(path.join(os.tmpdir(), 'ai-kanban-export-')); // private (0700), unlike a bare temp file
  // A shared clone has only its own config: no filter drivers from the checkout, the user's or the system's config,
  // nor from GIT_* variables the worker inherited (GIT_CONFIG_PARAMETERS, GIT_DIR from a hook).
  const inherited = Object.entries(process.env).filter(([k]) => !k.startsWith('GIT_'));
  const env = { ...Object.fromEntries(inherited), GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
  const run = (cmd: string, args: string[]) => promisify(execFile)(cmd, args, { env });
  try {
    await run('git', ['clone', '-q', '--shared', '--no-checkout', dir, path.join(staging, 'repo')]);
    await run('git', ['-C', path.join(staging, 'repo'), 'archive', '--format=tar', '-o', path.join(staging, 'tree.tar'), commitSha]);
    await run('tar', ['-xf', path.join(staging, 'tree.tar'), '-C', folder]);
    // OpenCode treats the nearest enclosing git checkout as the project it may read; there must be none.
    if (await git(folder, 'rev-parse', '--show-toplevel').then(() => true, () => false)) {
      throw new Error('the temporary folder is inside a git checkout; set TMPDIR to a folder outside any repository');
    }
    return folder;
  } catch (e) {
    await rm(folder, { recursive: true, force: true });
    const message = (e as Error).message.replaceAll(staging, '.').replaceAll(folder, '.');
    // eslint-disable-next-line preserve-caught-error -- the cause carries the unscrubbed paths
    throw new Error(`could not export ${commitSha}: ${message}`.slice(0, 1000));
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

/**
 * Symlinks under `dir` that resolve outside it. OpenCode's external_directory check compares path strings, so a
 * committed link like docs/setup.md -> ~/.ssh/id_ed25519 would otherwise hand the agent a file outside the repo.
 */
export async function escapingSymlinks(dir: string) {
  const root = await realpath(dir);
  const escaping: string[] = [];
  for (const entry of await readdir(root, { recursive: true, withFileTypes: true })) {
    if (!entry.isSymbolicLink()) continue;
    const link = path.join(entry.parentPath, entry.name);
    const target = await realpath(link).catch(() => undefined); // dangling links can't be read
    if (target && target !== root && !target.startsWith(root + path.sep)) escaping.push(path.relative(root, link));
  }
  return escaping;
}

/** Removes this machine's paths from text that leaves the worker (errors, model output). */
export async function scrub(dir: string, text: string) {
  const roots = [...new Set([await realpath(dir).catch(() => dir), path.resolve(dir)])];
  for (const root of roots) text = text.replaceAll(root + path.sep, '').replaceAll(root, '.');
  return text.replaceAll(os.homedir(), '~');
}

type OrcaRepos = { result?: { repos?: { kind?: string; path?: string; gitRemoteIdentity?: { canonicalKey?: string } | null }[] } };

/** The GitHub checkouts in `orca repo list --json` output, as `[{repository: 'owner/name', path}]`. */
export function githubCheckouts(json: OrcaRepos) {
  return (json.result?.repos ?? []).flatMap((r) => {
    const name = /^github\.com\/([A-Za-z0-9-]+\/[A-Za-z0-9._-]+)$/i.exec(r.gitRemoteIdentity?.canonicalKey ?? '')?.[1];
    return r.kind === 'git' && name && r.path ? [{ repository: name, path: r.path }] : [];
  });
}

/** The checkouts Orca knows about on this machine. */
export async function orcaCheckouts() {
  for (const orca of ['orca', '/Applications/Orca.app/Contents/Resources/bin/orca']) {
    try {
      return githubCheckouts(JSON.parse((await promisify(execFile)(orca, ['repo', 'list', '--json'])).stdout));
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e;
    }
  }
  throw new Error('Orca not found; use allow <owner/name> <path-to-checkout>');
}
