#!/usr/bin/env bash
# Build and upload iCan to TestFlight from a prepared macOS runner.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_NUMBER="${1:-${BUILD_NUMBER:-}}"
if [[ -z "$BUILD_NUMBER" ]]; then
  printf 'ERROR: build number is required. Usage: ./scripts/macos_release.sh <build_number>\n' >&2
  exit 1
fi

if [[ "$BUILD_NUMBER" =~ ^ios-v.*-([0-9]+)$ ]]; then
  BUILD_NUMBER="${BASH_REMATCH[1]}"
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  printf 'ERROR: build number must be numeric or use tag format ios-v<version>-<build_number>\n' >&2
  exit 1
fi

required_env=(
  ICAN_API_KEY
  ASC_KEY_ID
  ASC_ISSUER_ID
  ASC_KEY_CONTENT_BASE64
)

for name in "${required_env[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'ERROR: required environment variable %s is missing\n' "$name" >&2
    exit 1
  fi
done

if [[ -z "${IOS_BUNDLE_IDENTIFIER:-}" ]]; then
  export IOS_BUNDLE_IDENTIFIER="com.icannavigation.app"
fi

if [[ -n "${FLUTTER_BIN:-}" ]]; then
  [[ -x "$FLUTTER_BIN" ]] || {
    printf 'ERROR: FLUTTER_BIN is set but not executable\n' >&2
    exit 1
  }
elif command -v flutter >/dev/null 2>&1; then
  export FLUTTER_BIN="$(command -v flutter)"
else
  printf 'ERROR: flutter is not on PATH and FLUTTER_BIN is not set\n' >&2
  exit 1
fi

printf '==> Scanning tracked files for credential material\n'
set +e
git grep -n -I -E "AIza[0-9A-Za-z_-]{20,}|sk-[0-9A-Za-z_-]{20,}|BEGIN (RSA|OPENSSH|PRIVATE) KEY" -- . ":(exclude).env" ":(exclude)SECRETS.md"
scan_status=$?
set -e
if [[ "$scan_status" -eq 0 ]]; then
  printf 'ERROR: potential credential material found in tracked files\n' >&2
  exit 1
fi
if [[ "$scan_status" -ne 1 ]]; then
  printf 'ERROR: credential scan failed\n' >&2
  exit 1
fi

printf '==> Preparing Ruby bundle\n'
bundle config set path vendor/bundle
bundle check || bundle install

printf '==> Running iCan TestFlight lane for build %s\n' "$BUILD_NUMBER"
(cd ios && bundle exec fastlane ios testflight build_number:"$BUILD_NUMBER")
