#!/bin/bash
# Builds the macOS app, signs it (Developer ID, hardened runtime), zips it, and notarizes + staples it
# when a notarytool keychain profile exists. Output: build/dist/ai_kanban-<version>.zip
# SIGN_IDENTITY=... overrides the signing identity (default: first "Developer ID Application" in the keychain).
# NOTARY_PROFILE=... names the notarytool keychain profile (default: ai-kanban-notary).
set -euo pipefail
cd "$(dirname "$0")/.."
profile=${NOTARY_PROFILE:-ai-kanban-notary}

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

# Only a missing profile skips notarization; any other failure (offline, expired key, locked keychain) stops the release.
if probe=$(xcrun notarytool history --keychain-profile "$profile" 2>&1); then
  out=$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait 2>&1) || true
  echo "$out"
  if ! grep -q 'status: Accepted' <<<"$out"; then
    sid=$(sed -n 's/^ *id: *//p' <<<"$out" | head -1)
    xcrun notarytool log "$sid" --keychain-profile "$profile" >&2 || true
    echo "Notarization failed." >&2
    exit 1
  fi
  # The ticket can take a moment to reach Apple's CDN after "Accepted".
  for i in 1 2 3 4 5; do xcrun stapler staple "$app" && break; [ "$i" = 5 ] && exit 1; sleep 15; done
  rezip
  spctl --assess --type execute --verbose=2 "$app"
elif ! grep -q 'No Keychain password item found' <<<"$probe"; then
  echo "$probe" >&2
  echo "notarytool could not use profile '$profile'; not releasing an unnotarized build." >&2
  exit 1
else
  echo "Signed but NOT notarized (no notarytool keychain profile '$profile')."
  echo "Store credentials once: xcrun notarytool store-credentials $profile --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>"
fi
echo "$zip"
