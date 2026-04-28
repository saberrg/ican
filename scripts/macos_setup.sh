#!/usr/bin/env bash
# Idempotent setup/check script for the iCan macOS release runner.

set -euo pipefail

CI_MODE=0
if [[ "${1:-}" == "--ci" ]]; then
  CI_MODE=1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

log() {
  printf '\n==> %s\n' "$1"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

ensure_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required on the Mac runner"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This script must run on macOS"
fi

log "Xcode"
ensure_command xcodebuild
ensure_command xcrun
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path >/dev/null

log "Ruby and Bundler"
ensure_command ruby
ensure_command gem
if ! command -v bundle >/dev/null 2>&1; then
  if [[ "${ICAN_ALLOW_BOOTSTRAP:-0}" == "1" ]]; then
    gem install bundler --no-document
  else
    fail "Bundler is missing. Install it or set ICAN_ALLOW_BOOTSTRAP=1."
  fi
fi

log "Flutter"
if [[ -n "${FLUTTER_BIN:-}" ]]; then
  [[ -x "$FLUTTER_BIN" ]] || fail "FLUTTER_BIN is set but not executable"
else
  ensure_command flutter
  FLUTTER_BIN="$(command -v flutter)"
fi
"$FLUTTER_BIN" --version
"$FLUTTER_BIN" doctor -v

log "Ruby gems"
bundle config set path vendor/bundle
bundle check || bundle install
bundle exec fastlane --version
bundle exec pod --version

log "iOS model artifacts"
missing_models=0
for path in \
  "ios/Runner/EyePipeline/Models/YOLOv3Tiny.mlmodel" \
  "ios/Runner/EyePipeline/Models/DepthAnythingV2SmallF16P6.mlpackage"; do
  if [[ ! -e "$path" ]]; then
    printf 'Missing model artifact: %s\n' "$path" >&2
    missing_models=1
  fi
done

if [[ "$missing_models" == "1" ]]; then
  if [[ "${ICAN_DOWNLOAD_COREML:-0}" == "1" ]]; then
    bash scripts/download_coreml_models.sh
  else
    fail "CoreML artifacts are missing. Run ICAN_DOWNLOAD_COREML=1 ./scripts/macos_setup.sh once on the Mac."
  fi
fi

log "Signing identity"
if ! security find-identity -v -p codesigning | grep -Eq "(Apple|iPhone) Distribution"; then
  fail "No Apple/iPhone Distribution signing identity is visible to this user/keychain"
fi

log "Fastlane syntax"
(cd ios && bundle exec fastlane ios lanes >/dev/null)

if [[ "$CI_MODE" == "1" ]]; then
  log "CI runner check complete"
else
  log "Mac setup check complete"
fi
