# AI GitHub Kanban — Cross-Platform Architecture

Recommended architecture: Flutter + Hybrid Agent Workers.

An AI-native project management system that turns a short task brief into a detailed, repository-grounded spec. Flutter powers the user experience; independent agent workers do the repository analysis.

**Scope:** the product refines tasks into specs. It never writes, builds, runs or pushes code — implementation stays with people (or whatever tools they choose) on GitHub.

The most important decision is to separate **project management** from **AI reasoning**. A user can create a task on their iPhone, have an agent analyze the repository on their Mac or a cloud server, approve the spec, and follow the resulting GitHub issue from any device.

## 1. Product vision

| Surface | Role |
| --- | --- |
| Desktop | Full workspace + local agents |
| Web | Project management |
| Mobile | Capture + approvals |

- **Central backend & orchestrator** — authentication, boards, tasks, scheduling, synchronization.
- **Local worker** (Mac / Windows / Linux) — local repos + installed agents.
- **Remote worker** (VPS / Docker / cloud) — isolated repository workspaces.
- **GitHub** — repository, issues, pull requests, CI, reviews.

### Key principles

1. **One Flutter application** — shared features and logic for web, desktop and mobile, with adaptive UIs.
2. **Backend as source of truth** — tasks, agent runs, approvals and board state exist independently of any client.
3. **Pluggable agent runtime** — Claude Code, Codex, OpenCode or other adapters can do the refinement.
4. **Hybrid execution** — jobs run locally or remotely depending on user preference and worker capability.
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
| Queue | BullMQ + Redis | Durable queued work and retries |
| AI control plane | TypeScript | Agent routing and job orchestration |
| Local worker | TypeScript first (Rust later, if justified) | Process supervision and agent execution |
| Remote worker | Containerized runtime | Remote repository analysis and agent jobs |
| Agent interfaces | Adapter-based CLI/API integration | Codex, Claude Code, OpenCode |
| GitHub | GitHub App + REST/GraphQL + webhooks | Repo access, issues and PR sync |
| Live events | SSE initially | Job progress and board updates |
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
| Free fallback | `opencode/glm-5.3-flash-free` |
| Paid models (opt-in) | `deepseek-flash` (V4.1 Flash), `deepseek-v4-pro` via the DeepSeek API |
| Execution | Local / Remote / Auto |
| Integration | OpenCode SDK |

Free models by default, so a new user can run refinement without buying API credits. Both free defaults come from providers that, per OpenCode's Zen docs (checked 2026-11-18), keep no data and don't train on it. Repository code goes to the model, so don't make a free model that retains data or trains on it (e.g. `big-pickle`, `iceman-free`) a default. Zen says free models are available "for a limited time": the model id is configuration, and the worker must fall back, or fail with a clear message, when a model is withdrawn. Free-tier chat models are only served through OpenCode itself, which suits this design. Whether a worker needs an OpenCode Zen sign-in for free models is still unverified (the dev machine already had a Zen credential).

DeepSeek API ids, checked against DeepSeek's pricing page on 2026-11-18: `deepseek-flash` → DeepSeek-V4.1-Flash-1017 and `deepseek-v4-pro` → DeepSeek-V4-Pro-0813.

Avoid the legacy `deepseek-chat` / `deepseek-reasoner` identifiers (scheduled for discontinuation July 2026). OpenCode's official TypeScript SDK embeds its server, creates sessions, issues prompts and subscribes to events — use it rather than scraping CLI output.

### Worker topology

The **agent orchestrator** assigns jobs, enforces policy and manages leases. Both the **local worker** (desktop, local checkout) and **cloud worker** (container, isolated clone) run the OpenCode SDK against **OpenCode's free models** by default, or the **DeepSeek API** with per-workspace credentials and budgets.

### Local vs remote

| Capability | Local worker | Remote worker |
| --- | --- | --- |
| OpenCode harness | Yes | Yes |
| Default model | Yes | Yes |
| Analyze repository (read-only) | Local checkout | Isolated clone |
| Survive Flutter UI closing | Yes, if daemon keeps running | Yes |
| Work while computer is off | No | Yes |
| Authentication | Device registration + short-lived job credentials | Workload identity + GitHub App tokens |

Use explicit **worker leases**: a disconnected worker must not cause the same refinement to run twice or produce duplicate spec versions.

`Auto` execution picks a compatible, healthy local worker first and falls back to cloud only if the task's data-access and cost policies allow. A running refinement job is never silently migrated between workers.

## 5. OpenCode integration contract

One adapter, reused by local and cloud workers (internal contract, not literal SDK methods):

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

### Repository security

Read-only access throughout: GitHub App permissions limited to contents read plus issues write, and an isolated clone per cloud job. Repository content is data, not instructions — the refiner never executes repository instructions, installs dependencies or runs scripts. Cloud: short-lived containers with network and resource limits. Local: a visible permission policy listing which repositories a worker may read.

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
5. **Hybrid workers** — persistent local worker, remote container worker, leases, cancellation, retry rules, execution target selection.
6. **Hardening & release** — permissions, read-only enforcement, failure recovery, reconciliation, package signing, tests, end-to-end validation.

First usable release: **macOS desktop + web**, with iOS/Android targets kept in the project from day one. Mobile MVP = task capture, spec approval, agent monitoring, PR notifications.

### MVP acceptance tests

- A user can connect a GitHub repository and create a board.
- A five-word task can trigger an OpenCode + DeepSeek refinement run.
- The agent produces a repository-grounded spec with traceable evidence.
- The user can approve it and create exactly one GitHub issue.
- A linked PR appears automatically with its current reviews and CI state.
- A remote worker can process a job while the user's laptop is offline.
- A local worker can finish a job after the Flutter window closes, provided its service keeps running.
- Duplicate webhooks and failed retries don't corrupt task state or create duplicate issues.

## 9. Default application configuration

Application-level config (not an OpenCode-native file). Free models need no DeepSeek setup. To opt into paid DeepSeek models, configure DeepSeek in OpenCode via its auth flow, per DeepSeek's OpenCode integration guide: https://api-docs.deepseek.com/quick_start/agent_integrations/opencode/

```yaml
agent:
  default_harness: opencode
  provider: opencode
  model: opencode/deepseek-v4.1-flash-free
  fallback_models: [opencode/glm-5.3-flash-free]

execution:
  default_target: auto
  preferred_target: local
  cloud_fallback: true
  parallel_jobs_per_worker: 1

refinement:
  auto_start: true
  github_issue_requires_approval: true
  repository_access: read_only
```

**Decision:** Flutter client, TypeScript backend and worker services, OpenCode as the sole default harness, OpenCode's free DeepSeek V4.1 Flash as the default model (paid DeepSeek API optional). Local and cloud workers run the same read-only agent contract.
