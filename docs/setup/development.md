# Local development

Requires Docker, Node 24+ and Flutter via fvm (`apps/flutter_app/.fvmrc` pins the version).

```sh
docker compose up -d --wait                  # Postgres on localhost:55432 (dev db `kanban`, test db `kanban_test`)

cd services/api
npm install
npm test                                     # API tests against kanban_test
npm run dev                                  # API on http://localhost:8080, migrations run on start

cd apps/flutter_app
fvm flutter run -d macos                     # or: -d chrome
fvm flutter test integration_test/board_flow_test.dart -d macos        # end-to-end flow against the running API
fvm flutter test integration_test/refinement_flow_test.dart -d macos   # refinement UI, with the test playing the worker
```

`apps/flutter_app/tool/acceptance.sh` runs both end-to-end flows in one go (macOS): it starts Postgres, reuses an API
already on `:8080` (started with `npm run dev`) or starts one for the run, then drives the app. It's local only; CI
runs lint (`npm run lint` at the repo root), `dart format`, the analyzer, and the unit and API tests.

To regenerate the screenshots and demo in `docs/media`, keep the API running and run
`apps/flutter_app/tool/readme_media.sh` (macOS; drives the app with a `demo` account and needs ffmpeg).

## Sign-in and configuration

`npm run dev` starts the API with `AUTH_MODE=dev`: passwordless sign-in by login name, loopback only, refused when
`NODE_ENV=production`. `AUTH_MODE=github` signs in with GitHub instead (Device Flow: the app shows a code to enter at
github.com/login/device) and needs the GitHub App configured. Dev accounts don't carry over: their sessions and
workers stop working, and a GitHub account with the same login starts fresh. No GitHub token is kept: it is used once
to learn who you are.

- `GITHUB_ALLOWED_LOGINS` (comma-separated logins or numeric ids, pinned to GitHub ids at start, so a restart applies
  changes) limits who can sign in; unset, anyone can.
- `CORS_ORIGINS` (comma-separated): origins allowed to serve the web build from elsewhere.
- `RESEND_API_KEY` and `MAIL_FROM`: email team invites, with links to `APP_URL` (default `http://localhost:3000`);
  see [github-app.md](github-app.md).
- The app reaches the API at `http://localhost:8080`; override with `--dart-define=API_URL=...` (an Android emulator
  needs `http://10.0.2.2:8080`). The Flutter build contains no secrets.

## Refining tasks with a local worker

The worker reads repositories already checked out on your machine and needs the `opencode` CLI installed (or Claude
Code, if you choose it as the refiner). It uses OpenCode's free `opencode/deepseek-v4.1-flash-free` (add fallbacks to
`models` in `worker.json`; `opencode models opencode` lists what's available); repository code is sent to that
provider. The free tier has a usage limit: once it's used up, runs fail with "Free limit reached" until it resets, or
you set paid models in `worker.json`.

```sh
cd services/worker
npm install
npm test
npm run setup -- <code>                         # the code from the app's Workers page: connect, pick checkouts, install the service
```

Then connect the board to the same `owner/name` (the link icon on the board). Every new card on that board is refined
by your worker, including cards teammates add (connecting a repository shares your checkout of it with that board).
Pairing, the background service, the Claude Code and Orca options, the read-only sandbox and troubleshooting:
[worker.md](worker.md).

## GitHub issues and pull requests

Approving a spec queues one GitHub issue, filed by a GitHub App from the spec. PRs that close that issue ("Closes #12",
or linked in the PR's Development sidebar, which shows with the PR's next update) or whose branch in the repository
starts with `12-` show on the card and the task page with GitHub's review decision and CI status. Register a
development app and a webhook tunnel with [github-app.md](github-app.md); without it the API logs `GitHub sync off`
and issues stay queued. Webhooks arrive on a separate port (8081) so the tunnel exposes nothing else. With
`AUTH_MODE=github`, pointing a board at a repository, listing or importing its issues, approving a spec into it and
retrying a filing all need write access to that repository on GitHub. In `AUTH_MODE=dev` none of that is checked, so
keep a dev API on localhost.

**Import GitHub issue** (the board's repository menu) lists the repository's open issues and makes a card from the one
you pick; each issue can be a card on one board only. The card is refined like any other, and approving its spec posts
the spec as one comment on the issue (approving a later version edits that comment). GitHub keeps owning the issue's
title and body. Mind that an imported issue's text becomes the Refiner's brief, so anyone who can open issues on the
repository writes briefs for it; the Refiner stays read-only either way.
