#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${WHEREWE_NATIVE_APP_PATH:-${WHEREWE_NATIVE_DIST_DIR:-$ROOT_DIR/dist/macos}/Wherewe.app}"
APP_BINARY="$APP_PATH/Contents/MacOS/Wherewe"
SMOKE_ROOT="${WHEREWE_NATIVE_SMOKE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/wherewe-native-smoke.XXXXXX")}"
APP_PID=""
LAUNCH_PID=""
LAUNCH_MODE="${WHEREWE_NATIVE_LAUNCH_MODE:-direct}"

case "$LAUNCH_MODE" in
  direct|launchservices) ;;
  *)
    printf 'Unsupported native app launch mode: %s\n' "$LAUNCH_MODE" >&2
    exit 1
    ;;
esac

running_app_pids() {
  /bin/ps -axo pid=,command= \
    | /usr/bin/awk -v binary="$APP_BINARY" '$2 == binary { print $1 }'
}

teardown() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$LAUNCH_PID" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    kill -TERM "$LAUNCH_PID" 2>/dev/null || true
  fi
}
trap teardown EXIT INT TERM

[[ -x "$APP_BINARY" ]] || {
  printf 'Native app binary not found: %s\n' "$APP_BINARY" >&2
  exit 1
}
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$APP_PATH/Contents/Info.plist")" == "26.0" ]]
/usr/bin/file "$APP_BINARY" | /usr/bin/grep -q 'arm64'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

for forbidden_directory in Frameworks Agents Models Sidecar Helpers; do
  [[ ! -e "$APP_PATH/Contents/$forbidden_directory" ]] || {
    printf 'Native app unexpectedly contains %s.\n' "$forbidden_directory" >&2
    exit 1
  }
done
if /usr/bin/find "$APP_PATH/Contents" \
  \( -iname '*.framework' -o -iname '*.xcframework' -o -iname '*.mlmodel' \
     -o -iname '*.mlmodelc' -o -iname '*.bin' -o -name node_modules \) \
  -print -quit | /usr/bin/grep -q .; then
  printf 'Native app contains an unexpected framework, model, or helper payload.\n' >&2
  exit 1
fi
LOAD_COMMANDS="$SMOKE_ROOT/load-commands.txt"
mkdir -p "$SMOKE_ROOT"
/usr/bin/otool -l "$APP_BINARY" > "$LOAD_COMMANDS"
if /usr/bin/grep -Fq '@executable_path/../Frameworks' "$LOAD_COMMANDS"; then
  printf 'Native app contains an external-framework runtime search path.\n' >&2
  exit 1
fi

SIGNED_ENTITLEMENTS="$SMOKE_ROOT/signed-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$APP_PATH" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
/usr/bin/grep -Fq 'com.apple.security.device.audio-input' "$SIGNED_ENTITLEMENTS" || {
  printf 'Native app is missing the hardened-runtime audio-input entitlement.\n' >&2
  exit 1
}

SUPPORT="$SMOKE_ROOT/support"
CONFIG="$SMOKE_ROOT/config.json"
mkdir -p "$SUPPORT/data/files" "$SMOKE_ROOT/runtime-tmp"
chmod 700 "$SUPPORT" "$SUPPORT/data" "$SUPPORT/data/files" "$SMOKE_ROOT/runtime-tmp"
cat > "$CONFIG" <<JSON
{
  "version": 1,
  "transcription": {
    "engine": "apple",
    "local": {
      "provider": "apple",
      "model": "system",
      "apple": {"mode": "live", "showDetails": false}
    }
  },
  "translation": {"provider": "apple"},
  "user": {
    "name": "Native Bundle User",
    "role": "",
    "organization": "",
    "profile": "Validates the local application bundle."
  },
  "paths": {
    "database": "$SUPPORT/data/meetings.db",
    "files": "$SUPPORT/data/files"
  }
}
JSON
chmod 600 "$CONFIG"

launch_app() {
  local pids
  : > "$SMOKE_ROOT/app.log"
  if [[ "$LAUNCH_MODE" == "launchservices" ]]; then
    WHEREWE_CONFIG_PATH="$CONFIG" \
    WHEREWE_DEFAULT_DATA_ROOT="$SUPPORT" \
    WHEREWE_SUPPRESS_OPEN=1 \
    TMPDIR="$SMOKE_ROOT/runtime-tmp" \
    /usr/bin/open -n -W "$APP_PATH" >"$SMOKE_ROOT/app.log" 2>&1 &
    LAUNCH_PID=$!
  else
    WHEREWE_CONFIG_PATH="$CONFIG" \
    WHEREWE_DEFAULT_DATA_ROOT="$SUPPORT" \
    WHEREWE_SUPPRESS_OPEN=1 \
    TMPDIR="$SMOKE_ROOT/runtime-tmp" \
    "$APP_BINARY" >"$SMOKE_ROOT/app.log" 2>&1 &
    APP_PID=$!
  fi

  for _ in $(seq 1 200); do
    if [[ "$LAUNCH_MODE" == "launchservices" ]]; then
      pids="$(running_app_pids)"
      if [[ -n "$pids" ]]; then
        if [[ "$pids" == *$'\n'* ]]; then
          printf 'LaunchServices started multiple native app processes: %s\n' "$pids" >&2
          return 1
        fi
        APP_PID="$pids"
      fi
      kill -0 "$LAUNCH_PID" 2>/dev/null || {
        cat "$SMOKE_ROOT/app.log" >&2
        return 1
      }
    fi
    if [[ -n "$APP_PID" && -f "$SUPPORT/data/meetings.db" ]] \
      && kill -0 "$APP_PID" 2>/dev/null; then
      return 0
    fi
    if [[ "$LAUNCH_MODE" == "direct" ]] && ! kill -0 "$APP_PID" 2>/dev/null; then
      cat "$SMOKE_ROOT/app.log" >&2
      return 1
    fi
    sleep 0.05
  done
  cat "$SMOKE_ROOT/app.log" >&2
  return 1
}

stop_app() {
  local children
  children="$(pgrep -P "$APP_PID" || true)"
  [[ -z "$children" ]] || {
    printf 'Native app unexpectedly spawned child processes: %s\n' "$children" >&2
    return 1
  }
  kill -TERM "$APP_PID"
  if [[ "$LAUNCH_MODE" == "launchservices" ]]; then
    for _ in $(seq 1 200); do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
      printf 'LaunchServices app did not terminate within 10 seconds.\n' >&2
      return 1
    fi
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""
  else
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}

launch_app
[[ "$(stat -f '%Lp' "$CONFIG")" == "600" ]]
[[ "$(stat -f '%Lp' "$SUPPORT")" == "700" ]]
[[ "$(stat -f '%Lp' "$SUPPORT/data/meetings.db")" == "600" ]]
stop_app
launch_app
stop_app

printf 'Native app smoke passed (macOS 26 ARM64, Apple system frameworks, no embedded framework/model/helper payload, no child process, %s launch).\n' "$LAUNCH_MODE"
