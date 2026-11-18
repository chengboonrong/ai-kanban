# AI GitHub Kanban

AI-native Kanban for GitHub: Flutter client, TypeScript backend and workers, OpenCode + DeepSeek agents.

Architecture: [docs/architecture/overview.md](docs/architecture/overview.md)

## Local development

Requires Docker, Node 24+ and Flutter via fvm (`apps/flutter_app/.fvmrc` pins the version).

```sh
docker compose up -d --wait                  # Postgres on localhost:55432 (dev db `kanban`, test db `kanban_test`)

cd services/api
npm install
npm test                                     # API tests against kanban_test
npm run dev                                  # API on http://localhost:8080, migrations run on start

cd apps/flutter_app
fvm flutter run -d macos                     # or: -d chrome
fvm flutter test integration_test -d macos   # end-to-end flow against the running API
```

`npm run dev` starts the API with `AUTH_MODE=dev`: passwordless sign-in by login name, loopback only, refused when
`NODE_ENV=production`. Real sign-in via GitHub replaces it. The app reaches the API at `http://localhost:8080`; override
with `--dart-define=API_URL=...` (an Android emulator needs `http://10.0.2.2:8080`). The Flutter build contains no secrets.
