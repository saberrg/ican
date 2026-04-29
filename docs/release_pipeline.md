# iCan Release Pipeline

This repo uses a project-specific iOS release flow for the Flutter iCan app.
The goal is repeatable Codex development on Windows plus TestFlight builds on a
Mac without committing secrets or Apple signing material.

## Project Findings

- Framework: Flutter app, Dart SDK `^3.11.1`.
- Verified local toolchain during setup: Flutter `3.41.3`, Dart `3.11.1`.
- iOS app name: `iCan`.
- Bundle ID: `com.icannavigation.app`.
- Apple team ID in Xcode and export options: `YP6X8QPR44`.
- Deployment target: iOS `16.0`.
- Current app version at inspection: `1.0.0+25`.
- GitHub remote: `https://github.com/saberrg/ican.git`.
- Existing CI: `.github/workflows/verify.yml` runs format, analyze, tests, and optional firmware on Ubuntu.
- Existing signing: automatic Xcode signing plus a Distribution identity/profile on the remote Mac.
- Existing external API config:
  - Gemini key is injected at build time as `--dart-define=API_KEY=...`.
  - iOS bundle header is injected/defaulted as `IOS_BUNDLE_IDENTIFIER=com.icannavigation.app`.
  - ElevenLabs is optional and uses `ELEVENLABS_TTS_WORKER_URL`; never put an ElevenLabs API key in the app.

## Pipeline

Primary release path:

1. Codex edits locally, runs the iCan verification gates, commits, and pushes.
2. Codex pushes a release tag like `ios-v1.0.0-26`, or the workflow is triggered manually.
3. The job runs on a self-hosted macOS runner labeled `macOS` and `ican-ios`.
4. The Mac runs `scripts/macos_setup.sh --ci`.
5. The Mac runs `scripts/macos_release.sh <build_number>`.
6. Fastlane validates, builds `build/ios/ipa/iCan.ipa`, and uploads to TestFlight with App Store Connect API-key auth.

The upload path deliberately uses App Store Connect API keys, not an Apple ID
password. The first automated version uses the existing signing material already
proven on the Mac. Fastlane Match can be added later if signing needs to move to
new Macs frequently.

## Required Secrets

Add these to GitHub Actions secrets for the `testflight` environment or the repo:

- `ICAN_API_KEY`
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_KEY_CONTENT_BASE64`
- Optional: `ELEVENLABS_TTS_WORKER_URL`

Do not commit `.env`, `.p8`, `.p12`, `.cer`, provisioning profiles, private
keys, passwords, raw Apple account output, or API key values.

For fully hands-free TestFlight uploads, leave `Required reviewers` disabled on
the `testflight` environment. If reviewers are enabled, GitHub will pause every
release until a human approves the deployment.

For local development, keep the Gemini key in the shell or an untracked `.env`:

```powershell
$env:ICAN_API_KEY = "<local Gemini key>"
flutter run --dart-define=API_KEY="$env:ICAN_API_KEY" --dart-define=IOS_BUNDLE_IDENTIFIER=com.icannavigation.app
```

## One-Time Mac Setup

On GitHub, register the Mac as a self-hosted runner for this repo with labels:

```text
macOS
ican-ios
```

On the Mac:

```bash
cd ~/ican
git pull --ff-only
chmod +x scripts/macos_setup.sh scripts/macos_release.sh
ICAN_DOWNLOAD_COREML=1 ./scripts/macos_setup.sh
```

Confirm signing is visible to the runner user:

```bash
security find-identity -v -p codesigning
```

The output must include an Apple Distribution or iPhone Distribution identity for team `YP6X8QPR44`.
Do not paste private key, certificate, or Apple account details into repo docs.

## Release Trigger

Preferred hands-free trigger:

```powershell
.\scripts\release_testflight.ps1 -BuildNumber 26 -Watch
```

The helper creates and pushes tag `ios-v1.0.0-26`; the workflow extracts build
number `26` from the tag suffix. `-Watch` uses GitHub CLI when authenticated.
Without GitHub CLI auth, pushing the tag still triggers the release.

Manual UI trigger:

1. Open Actions.
2. Select `iOS TestFlight Release`.
3. Click `Run workflow`.
4. Enter a build number greater than the latest TestFlight build.
5. Optionally enter release notes.

The workflow injects secrets into Fastlane and Flutter as environment variables.
Secret values must not appear in logs.

Manual Mac fallback:

```bash
export ICAN_API_KEY="<Gemini key>"
export ASC_KEY_ID="<App Store Connect key ID>"
export ASC_ISSUER_ID="<App Store Connect issuer ID>"
export ASC_KEY_CONTENT_BASE64="<base64 p8 content>"
export IOS_BUNDLE_IDENTIFIER="com.icannavigation.app"
./scripts/macos_release.sh 26
```

## Validation Gates

Before committing app changes:

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-fatal-infos --fatal-warnings
flutter test --no-pub
.\scripts\agent_verify.ps1 -SkipPubGet
.\scripts\agent_verify.ps1 -SkipPubGet -OfflineVision
.\scripts\agent_preflight.ps1 -SkipPubGet -OfflineVision
```

Before TestFlight upload, the Mac release lane repeats format, analyze, tests,
and the release build. Hardware validation still requires the real iPhone plus
iCan Eye smoke in `docs/regression_matrix.md`.

## Future Codex Operating Prompt

Use this prompt for release-capable Codex sessions:

```text
Use the documented iCan release pipeline. Make the requested app change, preserve unrelated dirty work, run the required iCan gates, credential-scan tracked files, commit only relevant changes, push to origin, then run .\scripts\release_testflight.ps1 -BuildNumber <next_build_number> -Watch. Do not print or commit secrets.
```

## Known Limits

- TestFlight upload does not prove BLE hardware behavior. Run the real Eye smoke after the build installs.
- The Gemini key is still app-embedded at compile time. iOS/API restrictions reduce abuse risk, but production should use a backend proxy or app-attestation-backed service.
- CoreML model artifacts are ignored because they are large. The Mac setup script checks for them and can download the public Apple models with `ICAN_DOWNLOAD_COREML=1`.
- Existing analyzer info-level issues are non-fatal by project policy; warnings remain fatal.
