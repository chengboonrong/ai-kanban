#!/bin/sh
# Local acceptance run (not in CI): drives the real macOS app through the board and refinement flows
# against a real API and Postgres. Reuses an API already on :8080 (it must be `npm run dev`),
# otherwise starts one and stops it after.
set -e
cd "$(dirname "$0")/../../.."
docker compose up -d --wait
if ! curl -sf -m 2 http://localhost:8080/health >/dev/null; then
  [ -d services/api/node_modules ] || (cd services/api && npm ci)
  (cd services/api && AUTH_MODE=dev exec node src/server.ts) >"${TMPDIR:-/tmp}/ai-kanban-acceptance-api.log" 2>&1 &
  api=$!
  trap 'kill $api 2>/dev/null' EXIT
  trap "exit 130" INT TERM
  i=0
  until curl -sf -m 2 http://localhost:8080/health >/dev/null; do
    i=$((i + 1))
    kill -0 $api 2>/dev/null && [ $i -le 60 ] || { echo "API didn't start; see ${TMPDIR:-/tmp}/ai-kanban-acceptance-api.log" >&2; exit 1; }
    sleep 1
  done
fi
cd apps/flutter_app
# One app launch per run: a second launch in the same `flutter test` can't attach on macOS.
for t in board_flow refinement_flow; do
  fvm flutter test "integration_test/${t}_test.dart" -d macos
done
