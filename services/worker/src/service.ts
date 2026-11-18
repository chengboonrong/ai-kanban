// Keeps `start` running as a macOS LaunchAgent, so the worker outlives the terminal and the app.
import { execFile } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const LABEL = 'ai.kanban.worker';
const run = promisify(execFile);

/** The folder under ~ that macOS's privacy protection (TCC) keeps background processes out of, if `p` is in one. */
export function protectedFolder(p: string) {
  return ['Documents', 'Desktop', 'Downloads'].find((f) => p.startsWith(path.join(os.homedir(), f) + path.sep));
}

/** The LaunchAgent: `node cli.ts start`, restarted unless it exits cleanly (stopped on purpose). The token stays in the config file. */
export function launchdPlist(o: { node: string; cli: string; config: string; path: string; log: string }) {
  for (const p of [o.node, o.cli, o.config, o.log]) if (!path.isAbsolute(p)) throw new Error(`launchd needs absolute paths, not ${p}`);
  // launchd starts with a bare PATH; keep the installer's (where claude, opencode and git live) minus relative entries.
  const PATH = [...new Set([...o.path.split(':').filter((p) => path.isAbsolute(p)), path.dirname(o.node), '/usr/bin', '/bin', '/usr/sbin', '/sbin'])];
  const str = (s: string) => `<string>${s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</string>`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>${str(LABEL)}
  <key>ProgramArguments</key>
  <array>${str(o.node)}${str(o.cli)}${str('start')}</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AI_KANBAN_WORKER_CONFIG</key>${str(o.config)}
    <key>PATH</key>${str(PATH.join(':'))}
  </dict>
  <key>StandardOutPath</key>${str(o.log)}
  <key>StandardErrorPath</key>${str(o.log)}
</dict>
</plist>
`;
}

// ponytail: the log grows unbounded; rotate it (newsyslog or a size check at start) if it gets big.
export async function service([action]: string[], config: string) {
  if (process.platform !== 'darwin') throw new Error('service is not supported on this system yet; run `start` under your service manager');
  const plist = path.join(os.homedir(), 'Library', 'LaunchAgents', `${LABEL}.plist`);
  const log = path.join(os.homedir(), 'Library', 'Logs', 'ai-kanban-worker.log');
  const domain = `gui/${process.getuid?.()}`;
  const loaded = () => run('launchctl', ['print', `${domain}/${LABEL}`]).then(() => true, () => false);
  const bootout = () => run('launchctl', ['bootout', `${domain}/${LABEL}`]).catch(() => {}); // fails when not loaded

  if (action === 'install') {
    const cli = fileURLToPath(new URL('./cli.ts', import.meta.url));
    const folder = protectedFolder(cli);
    if (folder) throw new Error(`the worker is in ~/${folder}, which macOS keeps background services out of; move it elsewhere and install from there`);
    // Homebrew's Cellar path changes with every node upgrade; the PATH entry (a symlink) doesn't.
    const node = process.execPath.includes('/Cellar/') ? (await run('which', ['node'])).stdout.trim() : process.execPath;
    await mkdir(path.dirname(plist), { recursive: true });
    await mkdir(path.dirname(log), { recursive: true });
    await writeFile(plist, launchdPlist({ node, cli, config: path.resolve(config), path: process.env.PATH ?? '', log }));
    await bootout();
    for (const started = Date.now(); (await loaded()) && Date.now() - started < 5000; ) await sleep(200); // bootout returns before it's gone
    await run('launchctl', ['bootstrap', domain, plist]);
    console.log(`Installed; the worker now runs in the background and at login. Log: ${log}`);
  } else if (action === 'uninstall') {
    await bootout();
    await rm(plist, { force: true });
    console.log('Uninstalled; the worker no longer runs in the background.');
  } else if (action === 'status') {
    console.log((await loaded()) ? `Running as ${LABEL} (restarted if it stops)` : 'Not installed or not loaded');
    const lines = (await readFile(log, 'utf8').catch(() => '')).trimEnd().split('\n').slice(-20);
    if (lines.join('')) console.log(`Last lines of ${log}:\n${lines.join('\n')}`);
  } else {
    throw new Error('usage: service install | uninstall | status');
  }
}
