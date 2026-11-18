# AI GitHub Kanban — Cross-Platform Architecture

Recommended architecture: Flutter + Hybrid Agent Workers.

An AI-native project management system that turns a short task brief into a detailed, repository-grounded spec. Flutter powers the user experience; independent agent workers do the repository analysis.

**Scope:** the product refines tasks into specs. It never writes, builds, runs or pushes code — implementation stays with people (or whatever tools they choose) on GitHub.

The most important decision is to separate **project management** from **AI reasoning**. A user can create a task on their iPhone, have an agent analyze the repository on their own computer, approve the spec, and follow the resulting GitHub issue from any device.

## 1. Product vision

| Surface | Role |
| --- | --- |
| Desktop | Full workspace + local agents |
| Web | Project management |
| Mobile | Capture + approvals |

- **Central backend & orchestrator** — authentication, boards, tasks, scheduling, synchronization.
- **Worker** (your own Mac; Windows / Linux run it by hand) — your checkouts + your installed agents (OpenCode, or Claude Code). There is no hosted worker: repository code is read only on a machine its owner paired.
- **GitHub** — repository, issues, pull requests, CI, reviews.

### Key principles

1. **One Flutter application** — shared features and logic for web, desktop and mobile, with adaptive UIs.
2. **Backend as source of truth** — tasks, agent runs, approvals and board state exist independently of any client.
3. **Pluggable agent runtime** — Claude Code, Codex, OpenCode or other adapters can do the refinement.
4. **Your machine does the reading** — each person pairs their own worker; a board's runs go to the workers of whoever connected its repository.
5. **GitHub remains authoritative** — GitHub owns issues, PRs, review decisions and CI results.
6. **Recoverable operations** — agent jobs and webhook sync survive disconnections, retries and restarts.

## 2. Technology stack

| Layer | Recommendation | Responsibility |
| --- | --- | --- |
| UI | Flutter + Material 3 customization | Adaptive cross-platform experience |
| App state | Riverpod | Reactive client state |
| Navigation | GoRouter | Deep links and platform navigation |
| Networking | Dio | API access |
| Local cache | Drift / SQLite on native; supported web storage | Offline task drafts and cached views |
| Backend | TypeScript + Fastify | Auth, tasks, workspaces, boards, API |
| Database | PostgreSQL | Canonical application data |
| Queue | PostgreSQL (`FOR UPDATE SKIP LOCKED`); BullMQ + Redis when volume needs it | Durable queued work and retries |
| AI control plane | TypeScript | Agent routing and job orchestration |
| Local worker | TypeScript first (Rust later, if justified) | Process supervision and agent execution |
| Agent interfaces | Adapter-based CLI/API integration | Codex, Claude Code, OpenCode |
| GitHub | GitHub App + REST/GraphQL + webhooks | Repo access, issues and PR sync |
| Live events | Long-polling for run progress (Dio can't stream responses on web); SSE for board-wide updates later | Job progress and board updates |
| Telemetry | OpenTelemetry | Logs, metrics and tracing |

**Worker language:** Flutter stays responsible for presentation. The worker runs headlessly so a closed Flutter window doesn't kill a user-approved job. Start the worker in **TypeScript** (OpenCode's SDK is TypeScript-native, and orchestration code can be shared); move to Rust only when native process supervision or cross-platform packaging justifies it.

## 3. Application modules

- **Workspace & board management** — multiple workspaces, boards, members, repository connections. Each board has exactly one primary repository initially; several boards may reference the same repository.
- **Task management** — quick capture, editable descriptions, Kanban columns, labels, priorities, acceptance criteria, dependencies, attachments, revision history.
- **AI refinement** — repository-aware spec generation, ambiguity detection, evidence citations, suggested implementation strategy, readiness scoring.
- **Agent orchestrator** — queueing, worker selection, capability matching, retry policies, cost tracking, human approval workflows.
- **GitHub synchronization** — issues, branches, PRs, checks, reviews, comments, merge status, direct links, sync health.
- **Notifications & activity** — clarification requests, refinement approvals, PR reviews, CI failures, completed jobs, history.

Agents are **read-only**. They read the repository and write specs; they never edit code, run commands, build, test or push.

## 4. Hybrid agent execution

### Default AI configuration

| Setting | Value |
| --- | --- |
| Agent harness | OpenCode |
| AI provider | OpenCode Zen free models (default); DeepSeek API with the user's own key (optional) |
| Default model | `opencode/deepseek-v4.1-flash-free` |
| Free fallback | None by default: OpenCode withdrew `glm-5.3-flash-free` (November 2026); add one in the worker's `models` |
| Paid models (opt-in) | `deepseek-flash` (V4.1 Flash), `deepseek-v4-pro` via the DeepSeek API |
| Execution | The connector's own workers (no hosted worker) |
| Integration | OpenCode SDK |

Free models by default, so a new user can run refinement without buying API credits. Both free defaults come from providers that, per OpenCode's Zen docs (checked 2026-11-18), keep no data and don't train on it. Repository code goes to the model, so don't make a free model that retains data or trains on it (e.g. `big-pickle`, `iceman-free`) a default. Zen says free models are available "for a limited time": the model id is configuration, and the worker must fall back, or fail with a clear message, when a model is withdrawn. Free-tier chat models are only served through OpenCode itself, which suits this design. Whether a worker needs an OpenCode Zen sign-in for free models is still unverified (the dev machine already had a Zen credential).

DeepSeek API ids, checked against DeepSeek's pricing page on 2026-11-18: `deepseek-flash` → DeepSeek-V4.1-Flash-1017 and `deepseek-v4-pro` → DeepSeek-V4-Pro-0813.

Avoid the legacy `deepseek-chat` / `deepseek-reasoner` identifiers (scheduled for discontinuation July 2026). OpenCode's official TypeScript SDK embeds its server, creates sessions, issues prompts and subscribes to events — use it rather than scraping CLI output.

### Workers you run

There is no cloud worker (owner decision, Milestone 5): each person runs the worker on their own computer and pairs it with their account. The **orchestrator** in the API queues runs, hands each to a worker of whoever connected the board's repository, and manages leases.

- **Pairing.** The app's Workers page shows a one-time code (10 minutes, single use); `connect <code>` on the machine trades it for the worker's own token, stored in `~/.config/ai-kanban/worker.json` (mode 0600). The account's sign-in never reaches the worker.
- **Which checkouts.** `checkouts` lists the GitHub checkouts Orca knows about (`orca repo list --json`) and asks before allowing each; `allow <owner/name> <path>` names one by hand. A worker only claims runs for repositories it lists.
- **Staying up.** `service install` (macOS) registers a LaunchAgent that starts at login and restarts the worker if it crashes, so a run finishes after the Flutter window closes. While a job runs the worker holds `caffeinate -i`, because idle sleep would stop it.
- **Leases.** A claim leases the run for 90 seconds; every event batch (a heartbeat every 5 s) renews it, never past 20 minutes from the start. A sweeper in the API fails a lapsed run and queues a retry, 3 attempts in all. A worker stopping on purpose (SIGTERM) hands its run back for an immediate retry, and a worker that restarts after a crash gets its run back at its first claim. A stale worker's late events and result are refused (409), and a run can produce at most one spec. Not retried: failures the worker reports (model errors, free limits), cancels, the 20-minute cap and a board moved to another repository. A running job is never moved to another worker while it is alive.
- **Status.** The app shows each worker as online (seen in the last 30 s), busy (on a task) or offline, and a queued card says why it waits: no worker of the connector online, none of their workers lists the repository, or all are busy.

## 5. OpenCode integration contract

One adapter contract per harness (internal contract, not literal SDK methods):

```
AgentHarness
 ├── createSession()
 ├── inspectRepository()
 ├── refineTask()
 ├── streamEvents()
 ├── requestApproval()
 ├── cancelRun()
 └── getArtifacts()
```

An agent run persists:

```
agent_run
  id, task_id, execution_target, worker_id
  harness = "opencode", provider = "opencode", model = "opencode/deepseek-v4.1-flash-free"
  session_id, repository_commit_sha, state
  started_at, completed_at
  token_usage, cost, artifact_refs, error_details
```

One OpenCode agent policy, the **Refiner**: read-only repository access (read, list, search); returns structured requirements, acceptance criteria, evidence citations, ambiguities and a suggested approach. File edits, shell commands and Git writes are denied.

As built (Milestone 3): the Refiner's permissions deny everything except `read`, `list`, `glob` and `grep`, and `external_directory` is denied, so it can't read outside the folder it is given; nothing is set to `ask`, which would hang a headless run. The worker starts OpenCode with `OPENCODE_DISABLE_PROJECT_CONFIG`, `OPENCODE_DISABLE_CLAUDE_CODE`, `OPENCODE_DISABLE_EXTERNAL_SKILLS` and `OPENCODE_PURE`, so the repository's own `opencode.json`, `AGENTS.md`, `CLAUDE.md`, skills and plugins never load, and with a private `XDG_CONFIG_HOME`, so the machine owner's personal OpenCode setup (MCP servers, plugins, instructions) doesn't reach the Refiner either. Provider sign-ins still come from OpenCode's data directory. What the Refiner can see: the worker extracts the checkout's current commit (`git archive` from a shared clone, with no filter drivers configured) into a temporary folder and runs the agent there, so it reads committed files only, as on GitHub: git-crypt files stay encrypted and LFS files stay pointers. Untracked and ignored files (`.env`, `.npmrc`, build output), `.git` and uncommitted changes are never in that folder; the run reports the commit and whether uncommitted changes were left out. The worker refuses a commit containing symlinks that point outside it. Connecting a repository to a board shares your checkout of it with that board: runs there are claimed only by workers of whoever connected it, so another member can't point a board at your repository and have your worker read it for them. If that person leaves the workspace, the board's runs wait until someone connects the repository again. The structured output schema is `packages/contracts/refined-spec.schema.json`; the API validates every spec against it again, and the worker marks each evidence citation verified only if those lines exist in the exported commit.

**Claude Code as the Refiner** (optional per worker, `"refiner": "claude"` in `worker.json`; Milestone 5). The worker runs `claude -p --restricted --strict-mcp-config --tools Read,Glob,Grep --disable-slash-commands --no-session-persistence --settings '{"disableAllHooks":true}' --json-schema <schema>` in the same exported folder. Checked with Claude Code 2.1.325 and a normal sign-in (no API key needed): only Read, Glob and Grep are available, reads outside the folder are refused, and neither the folder's nor the user's `CLAUDE.md`, `AGENTS.md`, settings, skills, hooks or MCP servers load. The worker refuses to run if Claude Code starts with any other tool or an MCP server, so a future version that changes this fails closed. It runs on the machine owner's Claude plan, and repository content goes to Anthropic under that account's terms. It is not run through Orca: Orca can't pass these flags, so an Orca-launched agent would load the user's own MCP servers, skills and plugins, and Codex can't be pinned read-only from a project folder at all.

Keep provider credentials (OpenCode Zen, DeepSeek) on the executing worker or behind a controlled inference gateway. **Never embed API secrets in Flutter builds.**

## 6. Repository and GitHub synchronization

Clear ownership rather than trying to make GitHub and the Kanban DB identical:

| Data | Authoritative source |
| --- | --- |
| Original task brief | Kanban DB |
| AI-generated specification | Kanban DB |
| Agent execution logs | Kanban DB |
| Issue title, body and status | GitHub |
| PRs, reviews, comments and CI | GitHub |
| Custom workflow columns | Kanban DB |
| Board activity history | Kanban DB |

### Sync lifecycle

1. **Task creation** — save locally in Flutter, submit to backend, enqueue a refinement job. Idempotency key prevents duplicate cards.
2. **Repository analysis** — OpenCode inspects an immutable commit and produces a versioned spec. Later repo changes can mark the spec stale.
3. **GitHub issue creation** — after approval, the backend creates the issue with a GitHub App installation token and stores the immutable node ID and issue number.
4. **PR association** — PRs that people open against the issue are tracked via explicit references, GitHub issue-linking and branch metadata. A task may have several PRs.
5. **Webhook processing** — verify signatures, dedupe deliveries, queue reconciliation jobs; handle out-of-order events by fetching current GitHub state.
6. **Board update** — publish normalized events to clients over SSE. Keep GitHub's review/CI/merge status separate from the user's chosen column.

The webhook receiver runs in the central backend, never only in a local desktop worker.

As built (Milestone 4): approval checks the board still points at the repository the spec was refined against and
queues one `github_issues` row in the same transaction. A loop in the API claims due rows with a lease committed on its
own, so no transaction is open across a call to GitHub; it files the issue as the app's installation (title from the
spec, body built from it with `@` mentions neutralised, capped at 60,000 characters, starting with a hidden
`ai-kanban:task` marker). Every attempt after the first lists the repository's recent issues and adopts one the app
created with that marker; the lease is renewed just before each create and outlasts it, and the attempt count fences
every write, so a lost response or a crash mid-request never creates a second issue. After a rate limit the client
sends nothing until GitHub's reset. Webhooks arrive on a
separate listener (port 8081) that verifies the HMAC signature on the raw body and records the delivery id and its
effects in one transaction, so redeliveries are no-ops and a failed delivery can be redelivered by hand (GitHub doesn't retry). Events only mark PRs
dirty (a sequence number); the loop then reads each dirty PR's current state with one GraphQL query (state, review
decision, CI rollup, closing issue references) and relinks it, which makes out-of-order and duplicate events harmless; issue open/closed events apply only when newer
than the last one applied.
A PR links to a task when it closes the task's issue in the same repository or its branch (not a fork's) starts with
`<number>-`; plain mentions don't link. The app refreshes the task page every 15 s and the board every 30 s while issues are queued
or open; SSE comes later. Deferred: recovering webhooks missed while the receiver was unreachable (Milestone 6
reconciliation), updating the issue when a later spec version is approved, and checking the app is installed when a
repository is connected. Until sign-in with GitHub verifies who may use a repository, the API must stay on localhost.

### Repository security

Read-only access throughout: GitHub App permissions limited to issues write plus read access to contents (commit data on linked PRs), pull requests, checks and statuses; nothing clones repositories. Repository content is data, not instructions — the refiner never executes repository instructions, installs dependencies or runs scripts. Workers: a visible list of which repositories each may read, confirmed per repository.

## 7. Monorepo structure

```
ai-kanban/
├── apps/flutter_app/          # lib/{core,features/{auth,boards,tasks,agents,github,notifications,settings}}, all platform dirs
├── services/
│   ├── api/
│   ├── orchestrator/
│   ├── github-sync/
│   └── worker/{adapters/opencode,repository}
├── packages/{contracts,agent-policies,shared-types}
├── infrastructure/{docker,migrations}
└── docs/{architecture,security,adr}
```

The desktop Flutter app registers and talks to the worker over loopback or authenticated local IPC.

## 8. MVP roadmap

1. **Foundation** — Flutter desktop/web/mobile shell, auth, PostgreSQL backend, workspace and board creation.
2. **Kanban core** — create/edit tasks, configurable columns, activity history, local task caching, adaptive layouts.
3. **OpenCode + DeepSeek** — worker registration, repo inspection of a local checkout, AI refinement, structured outputs, streaming run events, approval screen.
4. **GitHub sync** — GitHub App installation, issue creation, idempotency, webhook ingestion, PR tracking, review and CI status.
5. **Your own workers** — pairing from the app, persistent local worker (launchd), leases, retry rules, worker status, Orca checkout discovery, Claude Code as an optional Refiner. (A remote/cloud worker was dropped: users bind their own machine.)
6. **Hardening & release** — permissions, read-only enforcement, failure recovery, reconciliation, package signing, tests, end-to-end validation.

First usable release: **macOS desktop + web**, with iOS/Android targets kept in the project from day one. Mobile MVP = task capture, spec approval, agent monitoring, PR notifications.

### MVP acceptance tests

- A user can connect a GitHub repository and create a board.
- A five-word task can trigger an OpenCode + DeepSeek refinement run.
- The agent produces a repository-grounded spec with traceable evidence.
- The user can approve it and create exactly one GitHub issue.
- A linked PR appears automatically with its current reviews and CI state.
- A run whose worker vanishes is failed within about two minutes and retried, never producing two specs.
- A local worker can finish a job after the Flutter window closes, provided its service keeps running.
- Duplicate webhooks and failed retries don't corrupt task state or create duplicate issues.

## 9. Default application configuration

Application-level config (not an OpenCode-native file). Free models need no DeepSeek setup. To opt into paid DeepSeek models, configure DeepSeek in OpenCode via its auth flow, per DeepSeek's OpenCode integration guide: https://api-docs.deepseek.com/quick_start/agent_integrations/opencode/

```yaml
agent:
  default_harness: opencode
  provider: opencode
  model: opencode/deepseek-v4.1-flash-free
  fallback_models: []

execution:
  target: own_workers   # no hosted worker
  parallel_jobs_per_worker: 1
  lease_seconds: 90
  max_run_minutes: 20
  attempts: 3

refinement:
  auto_start: true
  github_issue_requires_approval: true
  repository_access: read_only
```

**Decision:** Flutter client, TypeScript backend and worker services, OpenCode as the sole default harness, OpenCode's free DeepSeek V4.1 Flash as the default model (paid DeepSeek API optional). Workers run on their owners' machines under the same read-only agent contract, with Claude Code as an optional Refiner.
