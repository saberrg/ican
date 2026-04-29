#!/usr/bin/env bash
# Build and upload iCan to TestFlight from a prepared macOS runner.

set -euo pipefail

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

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
  MACOS_KEYCHAIN_PASSWORD
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

configure_ruby() {
  local brew_bin=""
  if command -v brew >/dev/null 2>&1; then
    brew_bin="$(command -v brew)"
  elif [[ -x "/opt/homebrew/bin/brew" ]]; then
    brew_bin="/opt/homebrew/bin/brew"
  elif [[ -x "/usr/local/bin/brew" ]]; then
    brew_bin="/usr/local/bin/brew"
  fi

  if [[ -x "/opt/homebrew/opt/ruby/bin/ruby" ]]; then
    export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
  elif [[ -x "/usr/local/opt/ruby/bin/ruby" ]]; then
    export PATH="/usr/local/opt/ruby/bin:$PATH"
  fi

  if ! ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0") ? 0 : 1' >/dev/null 2>&1; then
    if [[ "${ICAN_ALLOW_BOOTSTRAP:-0}" == "1" && -n "$brew_bin" ]]; then
      "$brew_bin" install ruby
      if [[ -x "/opt/homebrew/opt/ruby/bin/ruby" ]]; then
        export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
      elif [[ -x "/usr/local/opt/ruby/bin/ruby" ]]; then
        export PATH="/usr/local/opt/ruby/bin:$PATH"
      fi
    fi
  fi

  ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0") ? 0 : 1' >/dev/null 2>&1 || {
    printf 'ERROR: Ruby 3.0 or newer is required for Fastlane/CocoaPods gems\n' >&2
    exit 1
  }

  local gem_user_dir
  gem_user_dir="$(ruby -e 'require "rubygems"; print Gem.user_dir')"
  export GEM_HOME="$gem_user_dir"
  export PATH="$gem_user_dir/bin:$(ruby -e 'require "rubygems"; print Gem.bindir'):$PATH"
}

unlock_signing_keychain() {
  local keychain="${MACOS_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
  if [[ ! -f "$keychain" ]]; then
    keychain="${MACOS_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain}"
  fi
  if [[ ! -f "$keychain" ]]; then
    printf 'ERROR: signing keychain not found. Set MACOS_KEYCHAIN_PATH if it is not the login keychain.\n' >&2
    exit 1
  fi

  printf '==> Unlocking signing keychain\n'
  security unlock-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security list-keychains -d user -s "$keychain"
  security default-keychain -d user -s "$keychain"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_KEYCHAIN_PASSWORD" "$keychain" >/dev/null
}

find_flutter() {
  if [[ -n "${FLUTTER_BIN:-}" ]]; then
    [[ -x "$FLUTTER_BIN" ]] || {
      printf 'ERROR: FLUTTER_BIN is set but not executable\n' >&2
      exit 1
    }
    return
  fi

  if command -v flutter >/dev/null 2>&1; then
    export FLUTTER_BIN="$(command -v flutter)"
    return
  fi

  local candidate
  for candidate in \
    "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    "$HOME/tools/flutter/bin/flutter" \
    "/opt/homebrew/bin/flutter" \
    "/usr/local/bin/flutter"; do
    if [[ -x "$candidate" ]]; then
      export FLUTTER_BIN="$candidate"
      export PATH="$(dirname "$candidate"):$PATH"
      return
    fi
  done

  printf 'ERROR: flutter is not on PATH and FLUTTER_BIN is not set\n' >&2
  exit 1
}

find_flutter
configure_ruby
unlock_signing_keychain

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
