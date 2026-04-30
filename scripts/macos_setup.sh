#!/usr/bin/env bash
# Idempotent setup/check script for the iCan macOS release runner.

set -euo pipefail

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

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

remove_stale_untracked_file() {
  local path="$1"
  if [[ -e "$path" ]] && ! git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    rm -f "$path"
  fi
}

find_brew() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
  elif [[ -x "/opt/homebrew/bin/brew" ]]; then
    printf '/opt/homebrew/bin/brew'
  elif [[ -x "/usr/local/bin/brew" ]]; then
    printf '/usr/local/bin/brew'
  fi
}

ensure_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required on the Mac runner"
}

configure_ruby() {
  local brew_bin=""
  brew_bin="$(find_brew || true)"

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

  ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0") ? 0 : 1' >/dev/null 2>&1 ||
    fail "Ruby 3.0 or newer is required for Fastlane/CocoaPods gems"

  local gem_user_dir
  gem_user_dir="$(ruby -e 'require "rubygems"; print Gem.user_dir')"
  export GEM_HOME="$gem_user_dir"
  export PATH="$gem_user_dir/bin:$(ruby -e 'require "rubygems"; print Gem.bindir'):$PATH"
}

find_flutter() {
  if [[ -n "${FLUTTER_BIN:-}" ]]; then
    [[ -x "$FLUTTER_BIN" ]] || fail "FLUTTER_BIN is set but not executable"
    return
  fi

  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
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
      FLUTTER_BIN="$candidate"
      export PATH="$(dirname "$candidate"):$PATH"
      return
    fi
  done

  fail "flutter is required on the Mac runner. Set FLUTTER_BIN or install Flutter at ~/flutter/bin/flutter."
}

ensure_cmake() {
  if command -v cmake >/dev/null 2>&1; then
    return
  fi

  local brew_bin=""
  brew_bin="$(find_brew || true)"
  if [[ "${ICAN_ALLOW_BOOTSTRAP:-0}" == "1" && -n "$brew_bin" ]]; then
    "$brew_bin" install cmake || true
  fi

  if ! command -v cmake >/dev/null 2>&1 && [[ "${ICAN_ALLOW_BOOTSTRAP:-0}" == "1" ]]; then
    ensure_command python3
    python3 -m pip install --user cmake
    local python_user_base
    python_user_base="$(python3 -m site --user-base)"
    export PATH="$python_user_base/bin:$PATH"
  fi

  ensure_command cmake
}
if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This script must run on macOS"
fi

remove_stale_untracked_file Gemfile.lock

log "Xcode"
ensure_command xcodebuild
ensure_command xcrun
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path >/dev/null

log "Ruby and Bundler"
configure_ruby
ensure_command ruby
ensure_command gem
ruby -v
if ! command -v bundle >/dev/null 2>&1; then
  if [[ "${ICAN_ALLOW_BOOTSTRAP:-0}" == "1" ]]; then
    gem install bundler --no-document
  else
    fail "Bundler is missing. Install it or set ICAN_ALLOW_BOOTSTRAP=1."
  fi
fi
if ! command -v pod >/dev/null 2>&1; then
  if [[ "${ICAN_ALLOW_BOOTSTRAP:-0}" == "1" ]]; then
    gem install cocoapods --no-document
  else
    fail "CocoaPods is missing. Install it or set ICAN_ALLOW_BOOTSTRAP=1."
  fi
fi

log "Flutter"
find_flutter
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

log "Gemma LiteRT-LM"
printf 'Gemma local inference uses Google AI Edge LiteRT-LM; link the iOS runtime in Xcode before device validation.\n'

if [[ "${ICAN_SKIP_SIGNING_CHECK:-0}" == "1" ]]; then
  log "Signing identity"
  printf 'Skipping signing identity check for non-upload compile validation\n'
else
  log "Signing identity"
  if ! security find-identity -v -p codesigning | grep -Eq "(Apple|iPhone) Distribution"; then
    fail "No Apple/iPhone Distribution signing identity is visible to this user/keychain"
  fi
fi

log "Fastlane syntax"
(cd ios && bundle exec fastlane lanes >/dev/null)

if [[ "$CI_MODE" == "1" ]]; then
  log "CI runner check complete"
else
  log "Mac setup check complete"
fi
