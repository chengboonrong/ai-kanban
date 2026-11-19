# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

One Flutter app ships to desktop (macOS, Windows, Linux), web, iOS and Android with one shared design language. Native behaviours (keyboard shortcuts, back gestures, text selection, drag) are honoured per platform; the look is not re-skinned per OS.

## Users

Built for a solo developer first: one person with their own GitHub repositories and their own Mac paired as a worker, using the board as a personal pipeline from idea to spec to issue. Shared workspaces for a small team (a lead who triages and approves specs; teammates who implement on GitHub) are the next audience.

They capture five-word tasks wherever they are (often on a phone), and come back at a desk to review what the agent found.

## Product Purpose

AI Kanban turns a short task brief into a detailed, repository-grounded spec: requirements, acceptance criteria, the files and code it is grounded in, open questions and a suggested approach. Once the person approves the spec, it opens exactly one GitHub issue, and the pull requests linked to that issue (with reviews and CI) flow back onto the card.

The job that matters most is **reviewing and approving specs**: reading what the agent found, checking its evidence against the repository, and approving. Success is a person trusting a spec enough to approve it without re-reading the code themselves.

## Positioning

The agent reads the repository on the user's own machine, read-only, and never writes, builds, runs or pushes code. There is no hosted worker. Implementation stays with people on GitHub. Project management (boards, tasks, approvals) lives in the central backend; AI reasoning (brief to spec) runs on a worker the user paired.

## Operating Context

- Capture: quick task entry in a column, often from a phone.
- Refinement: a run is queued, claimed by the board owner's worker (OpenCode or Claude Code), streams progress (commits read, files searched, tools used), and writes a versioned spec tied to a commit.
- Review: the spec shows evidence lines (path and line range, verified or unverified), open questions, a readiness figure, and an Approve action.
- GitHub: a connected repository per board; one issue per approved spec; linked PRs with review state and CI.
- Workers: the user pairs a machine with a one-time code and a CLI command; workers show online, busy or offline.
- Offline: tasks captured offline wait in an outbox and send when the server is reachable.

## Capabilities and Constraints

- Routes: sign-in, workspaces, board, task, workers.
- Terminology: workspace, board, column, task (card), brief, refinement / run, spec (versioned), evidence, worker, repository, issue, PR.
- Strings, routes, handlers and test finders in `apps/flutter_app` are relied on by unit and integration tests.
- Team roles: per workspace, `owner` (the creator; sets roles, removes members, can't leave), `admin` (also invites by email and sees pending invites) and `member` (works on the boards). Per-board membership is out of scope.
- Undecided: mobile-specific capture flow; notifications.

## Brand Commitments

- Name: AI Kanban (README title: AI GitHub Kanban).
- Voice in the app is plain and literal ("Waiting for a worker", "Spec ready for review", "Approve spec").
- No logo or brand assets exist yet.

## Evidence on Hand

- README screenshots and demo in `docs/media/` (sample data from a test worker, not real model output).
- No customers, testimonials, metrics or pricing exist. Do not fabricate any.

## Product Principles

1. The spec is the product: every screen serves getting a trustworthy spec approved.
2. Show the evidence: what the agent read, and where, is always one step away from any claim it makes.
3. Read-only and local, visibly: the UI never implies the agent changes code or runs in the cloud.
4. Capture is instant; review is careful.
5. GitHub stays authoritative for issues, PRs, reviews and CI.
