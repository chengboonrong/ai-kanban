# Running your worker

The worker is the part that reads your code. It runs on your own computer, reads the checkouts you allow, and turns
queued cards into specs. There is no hosted worker: a board's runs go to the workers of whoever connected its
repository, so your code is read only on machines you paired.

Needs Node 24+, git, and the agent you refine with: the `opencode` CLI (default) or Claude Code (`claude`).

## 1. Connect it to your account

In the app, open **Workers** and choose **Connect a worker**. It shows a one-time code (valid 10 minutes) and the
command to run:

```sh
cd services/worker
npm install
npm run connect -- ABCDE-FGHJK                 # add --api https://… when the API isn't on localhost:8080
```

This saves the worker's own token to `~/.config/ai-kanban/worker.json` (readable only by you). Your sign-in never
reaches the worker. Run `connect` again with a new code to re-pair; connecting to a different API, or with a code from a
different account, clears the allowed repositories.

## 2. Choose what it may read

```sh
npm run checkouts                              # lists the GitHub checkouts Orca knows about; asks before each
npm run allow -- owner/name ~/code/name        # or name one by hand
```

Both check that the folder is the top of a git checkout whose remote (if it has any) is that GitHub repository. `checkouts` needs Orca
(`orca` on the PATH or Orca.app in /Applications) and a terminal, since it asks per repository.

The agent never reads your checkout directly: each run extracts the current commit into a temporary folder, so
untracked files (`.env`, build output), `.git` and uncommitted changes never reach it.

## 3. Keep it running

```sh
npm start                                      # in a terminal, or:
npm run service -- install                     # macOS: starts at login, restarts after a crash
npm run service -- status                      # loaded or not, and the last log lines
npm run service -- uninstall
```

The service is a LaunchAgent (`~/Library/LaunchAgents/ai.kanban.worker.plist`) that runs `node src/cli.ts start` with
the PATH you installed it from, logging to `~/Library/Logs/ai-kanban-worker.log`. Re-run `service install` after moving
the repository, changing node versions or installing `claude`/`opencode` somewhere new.

Changes to `worker.json` (`connect`, `checkouts`, `allow`, the refiner) apply from the next job, without a restart.
Only one worker process runs per config: a second `start` waits until the first one stops. While a job runs the worker
keeps the Mac awake (`caffeinate -i`); stopping it hands the run back so another worker, or this one when it's back,
picks it up straight away, and a worker that crashed takes its run back when it restarts. If a worker vanishes
mid-run, the API fails the run after about 90 seconds without a heartbeat and retries it, 3 attempts in all. The
worker stops a run after 15 minutes; the API gives up on it at 20.

Linux and Windows: run `npm start` under your own service manager.

## 4. Choose the agent

`worker.json`:

```json
{ "refiner": "opencode", "models": ["opencode/deepseek-v4.1-flash-free"] }
```

- **OpenCode** (default). Free model by default; repository code goes to that model's provider. OpenCode runs with
  only read/list/glob/grep and none of the repository's or your own OpenCode configuration.
- **Claude Code**: `"refiner": "claude"`, optionally `"claudeModel": "<model id>"`. Uses your Claude sign-in and plan;
  repository code goes to Anthropic under your account's terms. The worker runs
  `claude -p --restricted --strict-mcp-config --tools Read,Glob,Grep …` in the exported folder: no shell, no edits, no
  web tools, no MCP servers, no hooks or skills, and reads outside the folder are refused. It refuses to run if Claude
  Code ever starts with more than that, and stops it if it calls any other tool. A short test run used about $0.13 of plan usage; a real refinement uses more.

Orca isn't used to run the agent: it can't pass those restrictions, so an agent it launched would load your own MCP
servers, skills and plugins.

## Troubleshooting

- **"macOS won't let … read ~/Documents/…"**: background services can't read ~/Documents, ~/Desktop or ~/Downloads
  without permission. Move the checkout, or give the node binary named in the message Full Disk Access (System
  Settings › Privacy & Security); a node upgrade needs the grant again. `service install` refuses to run the worker
  itself from those folders.
- **"Claude Code (`claude`) is not on the PATH" / OpenCode won't start under the service**: re-run `service install` from a terminal
  where `which claude` (or `which opencode`) works.
- **The app says your worker is offline**: `service status`, then the log. "The API rejected this worker" means it was
  removed: connect again with a new code.
- **"No repositories allowed yet"**: run `checkouts` or `allow`; the running worker picks it up within 10 seconds.
