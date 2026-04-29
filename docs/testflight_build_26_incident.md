# TestFlight Build 26 Incident

## What Happened

Build 26 did not appear in App Store Connect because the GitHub Actions
TestFlight upload did not complete.

## Timeline

- App fixes were committed in `f20d74a` and `pubspec.yaml` was bumped to
  `1.0.0+26`.
- Tag `ios-v1.0.0-26` triggered GitHub Actions run `25086958749`.
- That run failed in `Verify Mac runner` before the IPA build started.
- The job log showed `ERROR: flutter is required on the Mac runner`.
- The same log also showed the App Store Connect and Gemini release secrets
  were empty for that run, meaning the workflow was using the wrong environment
  for the expected secrets.
- The workflow was changed to use environment `x` and to install Flutter with
  `subosito/flutter-action@v2`.
- A tag rerun was attempted with `ios-v1.0.0-rerun-26`, but GitHub rejected it:
  `Tag "ios-v1.0.0-rerun-26" is not allowed to deploy to x due to environment protection rules.`
- The release flow was changed to trigger from branches named
  `release/testflight-build-<number>` instead of tags.
- Branch `release/testflight-build-26` was pushed to trigger the corrected
  release workflow for build number `26`.
- That run passed Flutter setup and loaded the `x` secrets, then failed in
  `Verify Mac runner` because a stale untracked root `Gemfile.lock` on the
  self-hosted Mac required Bundler `4.0.3`.
- The release scripts now remove an untracked root `Gemfile.lock` before
  running Bundler, because this repo does not track that file.

## Root Causes

- The self-hosted Mac runner did not expose `flutter` on `PATH`.
- The TestFlight workflow used environment `testflight`, while the intended
  release environment was `x`.
- Environment `x` blocks tag deployments, so tag-triggered releases cannot
  deploy there.
- The self-hosted Mac workspace preserved a stale untracked `Gemfile.lock`
  because checkout used `clean: false`.

## Fixes Applied

- `.github/workflows/ios_testflight.yml`
  - Uses GitHub environment `x`.
  - Installs Flutter before running Mac setup checks.
  - Triggers on `release/testflight-build-*` branch pushes.
- `scripts/macos_release.sh`
  - Accepts `release/testflight-build-26` and extracts build number `26`.
  - Removes a stale untracked root `Gemfile.lock` before Bundler runs.
- `scripts/release_testflight.ps1`
  - Pushes release branches instead of release tags.
- `scripts/macos_setup.sh`
  - Removes a stale untracked root `Gemfile.lock` before Bundler runs.
- `docs/release_pipeline.md`
  - Documents branch-based TestFlight release triggering.

## Current Build 26 State

The app code for build 26 is fixed and pushed. The corrected release trigger is
`release/testflight-build-26`.

Check the latest workflow run for whether Fastlane uploaded the IPA to
TestFlight. App Store Connect will show build 26 only after that workflow
reaches the upload step and Apple finishes processing the build.
