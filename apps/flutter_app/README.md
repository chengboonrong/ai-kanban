# ai_kanban

A new Flutter project.

## Release build (macOS)

`tool/release_macos.sh` builds the release app, signs it inside-out with the Developer ID
certificate in the keychain (hardened runtime, timestamp, `Release.entitlements`), verifies the
signature and zips it to `build/dist/ai_kanban-<version>.zip`. If a notarytool keychain profile
exists it also notarizes, staples, re-zips and runs `spctl`; otherwise it says the zip is signed
but not notarized and exits 0.

- `SIGN_IDENTITY`: certificate SHA or name (default: first "Developer ID Application" identity).
- `NOTARY_PROFILE`: notarytool keychain profile (default `ai-kanban-notary`).
- One-time credentials: `xcrun notarytool store-credentials ai-kanban-notary --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>`.
  The App Store Connect API key needs the Developer role or higher.
- `--publish`: after a notarized build, creates a **draft** GitHub Release `v<version>` with the zip and its SHA-256,
  tagged at the current commit. It refuses unless the working tree is clean and HEAD is on `origin/main`. Bump
  `version:` in `pubspec.yaml` first; publish the draft on GitHub after checking it. Signing stays on this Mac: the
  certificate and notary credentials never go to CI.
