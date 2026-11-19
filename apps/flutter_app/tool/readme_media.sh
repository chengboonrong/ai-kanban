#!/bin/sh
# Regenerates docs/media (README screenshots and demo video) from the running app.
# Needs Postgres and the API running (docker compose up -d; cd services/api && npm run dev). Uses the "demo" account.
# API_URL=... points the app at another API (default http://localhost:8080).
set -e
cd "$(dirname "$0")/.."
defines="--dart-define=CAPTURE_MEDIA=true ${API_URL:+--dart-define=API_URL=$API_URL}"
log=$(mktemp)
fvm flutter test integration_test/readme_media_test.dart -d macos $defines | tee "$log"
src=$(sed -n 's/.*MEDIA_DIR=//p' "$log" | head -1)
grep -q "All tests passed" "$log" && [ -d "$src/video" ] || { echo "capture failed, docs/media left unchanged" >&2; exit 1; }
# The refinement screenshots: a test worker posts sample runs and specs.
rlog=$(mktemp)
fvm flutter test integration_test/readme_refine_media_test.dart -d macos $defines | tee "$rlog"
rsrc=$(sed -n 's/.*MEDIA_DIR=//p' "$rlog" | head -1)
grep -q "All tests passed" "$rlog" && [ -f "$rsrc/refine-spec.png" ] || { echo "capture failed, docs/media left unchanged" >&2; exit 1; }
out=../../docs/media
mkdir -p "$out"
cp "$src"/*.png "$rsrc"/*.png "$out"/
ffmpeg -loglevel error -y -framerate 15 -i "$src/video/%05d.png" -c:v libx264 -pix_fmt yuv420p -crf 22 -movflags +faststart "$out/demo.mp4"
ffmpeg -loglevel error -y -framerate 15 -i "$src/video/%05d.png" \
  -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  "$out/demo.gif"
ls -lh "$out"
