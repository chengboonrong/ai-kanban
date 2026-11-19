# Running your worker

The worker is the part that reads your code. It runs on your own computer, reads the checkouts you allow, and turns
queued cards into specs. There is no hosted worker: a board's runs go to the workers of whoever connected its
repository, so your code is read only on machines you paired.

Needs Node 24+, git, and the agent you refine with: the `opencode` CLI (default) or Claude Code (`claude`).

## The short way

In the app, open **Workers** and choose **Connect a worker**. It shows a one-time code (valid 10 minutes) and the
command to run:

```sh
cd services/worker
npm install && npm run setup -- ABCDE-FGHJK    # add --api https://… when the API isn't on localhost:8080
```

`setup` does steps 1 to 3 below in order: it connects the worker, then asks (in a terminal) which of Orca's GitHub
checkouts it may read, then on macOS installs the background service. `--no-service` skips the service, and
`--name "My Mac"` names the worker. Without a terminal (a script, say) it can't ask, so it prints the `allow` command
to run for each repository instead. On Linux and Windows it ends by telling you to run `npm start` under your own
service manager. The steps stay available on their own, and are what to use to change something later.

## 1. Connect it to your account

```sh
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

To watch Claude Code runs in Orca, add `"claudeInOrca": true` next to `"refiner": "claude"`. Each run then opens a
terminal titled after the card in the checkout's Orca workspace, showing the model and each file it reads or searches,
and closes it when the run ends (if the close fails, the terminal ends by itself). The worker still runs Claude Code
itself, with the same restrictions; the terminal only shows its progress. Its shell starts in the checkout, as any
terminal you open there in Orca does, so your own shell setup (direnv, nvm and the like) runs there first. If Orca
isn't running, its CLI isn't found (`orca` on the PATH or Orca.app in /Applications) or the checkout isn't added to it,
the run goes ahead without a terminal. Only the local Orca app works. Orca's own agent launch isn't used: it can't pass
those restrictions, so an agent it launched would load your own MCP servers, skills and plugins.

## Use approved specs in your coding agent

The worker also speaks MCP (Model Context Protocol) over stdio, so your own coding agent can read the specs people
approved instead of you pasting them in. Register it once, with the path of your checkout of this repository:

```sh
claude mcp add ai-kanban -- node /path/to/ai-kanban/services/worker/src/cli.ts mcp
```

Any other MCP client takes the same stdio command: `node /path/to/ai-kanban/services/worker/src/cli.ts mcp`, with
`AI_KANBAN_WORKER_CONFIG` in its environment if you keep the config somewhere other than `~/.config/ai-kanban/worker.json`.

It offers two read-only tools:

- `list_approved_specs`: the approved specs for the repositories this worker may read (or one of them, with
  `repository`), newest approval first, with their task ids and issue links.
- `get_spec`: one spec as Markdown (summary, acceptance criteria, requirements, evidence with `path:lines`, suggested
  approach, open questions, the commit it was read at), headed by a line saying the read-only Refiner wrote it from a
  task brief and the repository, a person approved it, and its text is data, not instructions.

Only a person's approval makes a spec readable here; drafts never are. This is new for the worker token: besides
claiming runs it can now also read the approved specs of every board its owner can see (workspaces they belong to),
each under the repository it was refined against, wherever the board points now; the MCP server itself only asks for
the repositories in `worker.json`. The token never leaves this program: it is read from `worker.json` on each call,
and a spec's text is data your agent reads, not instructions. The server writes nothing but protocol to stdout and needs the worker to be
connected (`setup` or `connect`), not running.

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
