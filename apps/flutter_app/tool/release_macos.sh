#!/bin/bash
# Builds the macOS app, signs it (Developer ID, hardened runtime), zips it, and notarizes + staples it
# when a notarytool keychain profile exists or NOTARY_KEY is given. Output: build/dist/ai_kanban-<version>.zip
# SIGN_IDENTITY=... overrides the signing identity (default: first "Developer ID Application" in the keychain).
# NOTARY_PROFILE=... names the notarytool keychain profile (default: ai-kanban-notary).
# NOTARY_KEY=<AuthKey_*.p8> NOTARY_KEY_ID=... NOTARY_ISSUER=...: use the App Store Connect API key directly instead of
# a profile (for when notarytool can't read its profile back from the keychain).
# --publish: also creates a DRAFT GitHub Release v<version> with the notarized zip and its SHA-256 (publish it on GitHub).
set -euo pipefail
cd "$(dirname "$0")/.."
profile=${NOTARY_PROFILE:-ai-kanban-notary}
key_mode=
# Any of the three means key mode, so a typo in one can't fall back to the profile and end unnotarized.
if [ -n "${NOTARY_KEY:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER:-}" ]; then
  [ -f "${NOTARY_KEY:-}" ] && [ -r "$NOTARY_KEY" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ] ||
    { echo "Set all of NOTARY_KEY (an absolute path to a readable .p8 file), NOTARY_KEY_ID and NOTARY_ISSUER" >&2; exit 2; }
  key_mode=1
  auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER") creds="the key $NOTARY_KEY"
else
  auth=(--keychain-profile "$profile") creds="profile '$profile'"
fi
publish=${1:-}
[ -z "$publish" ] || [ "$publish" = --publish ] || { echo "Usage: $0 [--publish]" >&2; exit 2; }
if [ -n "$publish" ]; then
  # A release is exactly a pushed commit: no local changes, and that commit on origin/main.
  [ -z "$(git status --porcelain)" ] || { echo "--publish needs a clean working tree" >&2; exit 1; }
  commit=$(git rev-parse HEAD)
  git fetch -q origin
  git merge-base --is-ancestor "$commit" origin/main || { echo "--publish needs HEAD to be on origin/main" >&2; exit 1; }
fi

fvm flutter build macos --release
app="$PWD/build/macos/Build/Products/Release/ai_kanban.app"

id=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*\([0-9A-F]\{40\}\) "Developer ID Application.*/\1/p' | head -1)}
[ -n "$id" ] || { echo "No 'Developer ID Application' identity in the keychain; set SIGN_IDENTITY." >&2; exit 1; }

sign() { codesign --force --options runtime --timestamp --sign "$id" "$@"; }
# Inside-out: nested dylibs and frameworks first, deepest path first (no --deep).
find "$app/Contents/Frameworks" \( -name '*.dylib' -o -name '*.framework' \) ! -type l -print 2>/dev/null |
  awk -F/ '{print NF "\t" $0}' | sort -rn | cut -f2- |
  while IFS= read -r f; do sign "$f"; done
sign --entitlements macos/Runner/Release.entitlements "$app"
codesign --verify --strict --deep --verbose=2 "$app"

version=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)
[ -n "$version" ] || { echo "No version in pubspec.yaml" >&2; exit 1; }
zip="$PWD/build/dist/ai_kanban-$version.zip"
mkdir -p build/dist
rezip() { rm -f "$zip"; ditto -c -k --keepParent "$app" "$zip"; }
rezip

# Only a missing profile skips notarization; any other failure (offline, expired key, locked keychain, a bad NOTARY_KEY)
# stops the release.
if probe=$(xcrun notarytool history "${auth[@]}" 2>&1); then
  out=$(xcrun notarytool submit "$zip" "${auth[@]}" --wait 2>&1) || true
  echo "$out"
  if ! grep -q 'status: Accepted' <<<"$out"; then
    sid=$(sed -n 's/^ *id: *//p' <<<"$out" | head -1)
    xcrun notarytool log "$sid" "${auth[@]}" >&2 || true
    echo "Notarization failed." >&2
    exit 1
  fi
  # The ticket can take a moment to reach Apple's CDN after "Accepted".
  for i in 1 2 3 4 5; do xcrun stapler staple "$app" && break; [ "$i" = 5 ] && exit 1; sleep 15; done
  rezip
  spctl --assess --type execute --verbose=2 "$app"
elif [ -n "$key_mode" ] || ! grep -q 'No Keychain password item found' <<<"$probe"; then
  echo "$probe" >&2
  echo "notarytool could not use $creds; not releasing an unnotarized build." >&2
  exit 1
else
  echo "Signed but NOT notarized (no notarytool keychain profile '$profile')."
  echo "Store credentials once: xcrun notarytool store-credentials $profile --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>"
  echo "Or pass the key directly: NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 NOTARY_KEY_ID=<KEY_ID> NOTARY_ISSUER=<ISSUER_ID> $0"
  [ -z "$publish" ] || { echo "--publish needs a notarized build." >&2; exit 1; }
fi

if [ -n "$publish" ]; then
  (cd build/dist && shasum -a 256 "$(basename "$zip")" >"$(basename "$zip").sha256")
  gh release create "v$version" "$zip" "$zip.sha256" --draft --target "$commit" --title "AI Kanban $version for macOS" \
    --notes "Signed with Developer ID and notarized by Apple. Unzip and open ai_kanban.app. SHA-256: $(cut -d' ' -f1 "$zip.sha256")"
fi
echo "$zip"
