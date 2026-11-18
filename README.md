# AI GitHub Kanban

AI-native Kanban for GitHub: Flutter client, TypeScript backend and workers, OpenCode + DeepSeek agents.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/architecture/structure-dark.png">
  <img alt="Product structure: Flutter app, central backend, local and cloud workers, GitHub and DeepSeek" src="docs/architecture/structure.png">
</picture>

## What it is

A project board where AI agents do the engineering legwork. Capture a five-word task on your phone; an agent reads
your repository on your Mac or a cloud worker, turns it into a grounded spec, and, once you approve, opens exactly one
GitHub issue. Linked PRs, reviews and CI status flow back onto the card.

The core design choice is keeping three things apart:

- **Project management**: boards, tasks, approvals. Lives in the central backend, independent of any client.
- **AI reasoning**: refining a task into a spec. Runs on a worker with read-only repository access.
- **Code execution**: implementing a task. Runs on a worker in an isolated worktree, only when you authorize it.

## Surfaces

| Surface | Role |
| --- | --- |
| Desktop (macOS, Windows, Linux) | Full workspace, plus the local worker |
| Web | Project management |
| Mobile (iOS, Android) | Task capture, spec approval, agent monitoring, PR notifications |

All three are one Flutter app with adaptive layouts.

## How a task flows

1. **Capture**: the app saves the task and submits it with an idempotency key, so retries never duplicate a card.
2. **Refine**: the orchestrator leases a refinement job to a healthy worker (local first, cloud if policy allows).
   OpenCode with DeepSeek reads a pinned commit and returns a versioned spec with evidence and open questions.
3. **Approve**: you review the spec; approval creates one GitHub issue through the GitHub App.
4. **Implement** (opt-in): an implementer agent works in an isolated worktree and pushes a branch and PR. It never
   pushes to protected branches.
5. **Track**: GitHub webhooks are verified, deduplicated and reconciled; reviews and CI land on the card over SSE.
   Your column choice stays yours, separate from GitHub's status.

## Principles

- **The backend is the source of truth** for tasks, specs, agent runs and board history.
- **GitHub stays authoritative** for issues, PRs, reviews and CI.
- **Refining and implementing are separate permissions.** An agent that can read code can't automatically change it.
- **Jobs are recoverable.** Worker leases mean a dropped connection never runs the same push or issue creation twice,
  and a running job is never silently moved between workers.
- **No secrets in clients.** Model and GitHub credentials stay on workers or the backend.

## Stack

| Part | Choice |
| --- | --- |
| Client | Flutter, Riverpod, GoRouter, Dio, Drift |
| Backend | TypeScript, Fastify, PostgreSQL, BullMQ on Redis |
| Workers | TypeScript daemon (local) and containers (cloud), same agent contract |
| Agents | OpenCode SDK; DeepSeek Flash by default |
| GitHub | GitHub App, REST/GraphQL, webhooks |
| Telemetry | OpenTelemetry |

## Status

Early build. Milestones: foundation → Kanban core → OpenCode + DeepSeek refinement → GitHub sync → hybrid execution →
hardening. The first release targets macOS desktop and web.

Architecture: [docs/architecture/overview.md](docs/architecture/overview.md)
