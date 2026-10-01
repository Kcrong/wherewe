#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'pre-push macOS gate: %s\n' "$1" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PACKAGE_DIR="$ROOT_DIR/macos"

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required."
[[ "$(uname -m)" == "arm64" ]] || fail "native Apple Silicon arm64 execution is required."
MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
case "$MACOS_MAJOR" in
  ''|*[!0-9]*) fail "could not determine the macOS version." ;;
esac
[[ "$MACOS_MAJOR" -ge 26 ]] || fail "macOS 26 or later is required."

for required_tool in \
  /bin/bash \
  /usr/bin/afconvert \
  /usr/bin/codesign \
  /usr/bin/ditto \
  /usr/bin/file \
  /usr/bin/hdiutil \
  /usr/bin/otool \
  /usr/bin/plutil \
  /usr/bin/python3 \
  /usr/bin/say \
  /usr/bin/tee \
  /usr/bin/xcrun; do
  [[ -x "$required_tool" ]] || fail "required tool is unavailable: $required_tool"
done

NODE_BIN="$(command -v node || true)"
GIT_BIN="$(command -v git || true)"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "node is required."
[[ -n "$GIT_BIN" && -x "$GIT_BIN" ]] || fail "git is required."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || fail "DEVELOPER_DIR is unavailable: $DEVELOPER_DIR"
export DEVELOPER_DIR
/usr/bin/xcrun --find swift >/dev/null 2>&1 || fail "the Swift toolchain is unavailable through xcrun."

GIT_ROOT="$("$GIT_BIN" -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)" \
  || fail "the script is not inside a Git worktree."
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"
[[ "$GIT_ROOT" == "$ROOT_DIR" ]] || fail "the derived repository root does not match the Git worktree root."
[[ -f "$PACKAGE_DIR/Package.swift" ]] || fail "macOS Swift package not found."

if [[ -n "${KIROCREW_SCRATCH:-}" ]]; then
  SCRATCH_CANDIDATE="$KIROCREW_SCRATCH"
elif [[ -n "${RUNNER_TEMP:-}" ]]; then
  SCRATCH_CANDIDATE="$RUNNER_TEMP"
elif [[ -n "${TMPDIR:-}" ]]; then
  SCRATCH_CANDIDATE="$TMPDIR"
else
  fail "KIROCREW_SCRATCH, RUNNER_TEMP, or TMPDIR must name an existing scratch directory."
fi
case "$SCRATCH_CANDIDATE" in
  /*) ;;
  *) fail "the selected scratch root must be absolute: $SCRATCH_CANDIDATE" ;;
esac
[[ -d "$SCRATCH_CANDIDATE" && -w "$SCRATCH_CANDIDATE" ]] \
  || fail "the selected scratch root is not a writable directory: $SCRATCH_CANDIDATE"
SCRATCH_ROOT="$(cd "$SCRATCH_CANDIDATE" && pwd -P)"
case "$SCRATCH_ROOT" in
  "$ROOT_DIR"|"$ROOT_DIR"/*) fail "the scratch root must be outside the repository." ;;
esac

RUN_ROOT="$(mktemp -d "$SCRATCH_ROOT/wherewe-pre-push.XXXXXX")" \
  || fail "could not create an isolated scratch directory."
teardown() {
  rm -rf "$RUN_ROOT"
}
trap teardown EXIT

mkdir -p "$RUN_ROOT/runtime" "$RUN_ROOT/runner" "$RUN_ROOT/tmp"
export KIROCREW_SCRATCH="$RUN_ROOT/runtime"
export RUNNER_TEMP="$RUN_ROOT/runner"
export TMPDIR="$RUN_ROOT/tmp"
export WHEREWE_NATIVE_BUILD_DIR="$RUN_ROOT/swift-build"
export WHEREWE_NATIVE_DIST_DIR="$RUN_ROOT/native-dist"
export WHEREWE_NATIVE_APP_PATH="$WHEREWE_NATIVE_DIST_DIR/Wherewe.app"
export WHEREWE_NATIVE_SMOKE_ROOT="$RUN_ROOT/native-app-smoke"
export WHEREWE_DMG_OUTPUT_DIR="$RUN_ROOT/native-dmg-dist"
export WHEREWE_DMG_BUILD_DIR="$RUN_ROOT/native-dmg-build"
unset WHEREWE_DMG_PATH

STATUS_BEFORE="$RUN_ROOT/git-status-before"
STATUS_AFTER="$RUN_ROOT/git-status-after"
"$GIT_BIN" -C "$ROOT_DIR" status --porcelain=v1 -z --untracked-files=all > "$STATUS_BEFORE"
[[ ! -s "$STATUS_BEFORE" ]] || fail "the Git worktree must be clean before validation."

printf '%s\n' '==> Checking JavaScript and shell syntax'
NODE_TEST_COUNT=0
for source in \
  "$ROOT_DIR"/tests/native/*.test.js \
  "$ROOT_DIR"/tests/public/*.test.js \
  "$ROOT_DIR"/scripts/scan-public-content.js; do
  [[ -f "$source" ]] || continue
  "$NODE_BIN" --check "$source"
  case "$source" in
    */tests/*.test.js) NODE_TEST_COUNT=$((NODE_TEST_COUNT + 1)) ;;
  esac
done
[[ "$NODE_TEST_COUNT" -gt 0 ]] || fail "no Node contract tests were found."
for script in "$ROOT_DIR"/scripts/*.sh; do
  [[ -f "$script" ]] || continue
  /bin/bash -n "$script"
done

printf '%s\n' '==> Scanning public content without printing matched values'
(
  cd "$ROOT_DIR"
  "$NODE_BIN" scripts/scan-public-content.js
)

printf '%s\n' '==> Running all Node static contracts'
(
  cd "$ROOT_DIR"
  "$NODE_BIN" --test tests/native/*.test.js tests/public/*.test.js
)

printf '%s\n' '==> Running Swift unit tests'
/usr/bin/xcrun swift test \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$WHEREWE_NATIVE_BUILD_DIR"

printf '%s\n' '==> Running native service contract checks'
/usr/bin/xcrun swift run \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$WHEREWE_NATIVE_BUILD_DIR" \
  MeetingTranscriberCoreChecks

printf '%s\n' '==> Running required Apple Speech and Translation evidence'
APPLE_EVIDENCE_LOG="$RUN_ROOT/apple-runtime-evidence.log"
WHEREWE_NATIVE_REAL_APPLE_SPEECH=1 \
WHEREWE_NATIVE_REAL_APPLE_TRANSLATION=1 \
/usr/bin/xcrun swift test \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$WHEREWE_NATIVE_BUILD_DIR" \
  --filter NativeRuntimeIntegrationTests \
  2>&1 | /usr/bin/tee "$APPLE_EVIDENCE_LOG"
for marker in apple-speech-accurate apple-speech-commit-boundary apple-translation; do
  /usr/bin/grep -Fq "WHEREWE_RUNTIME_EVIDENCE $marker" "$APPLE_EVIDENCE_LOG" \
    || fail "required Apple runtime evidence is missing: $marker"
done

printf '%s\n' '==> Building and smoke-testing the native app'
/bin/bash "$ROOT_DIR/scripts/build-macos-app.sh"
/bin/bash "$ROOT_DIR/scripts/test-macos-app-bundle.sh"

printf '%s\n' '==> Building and mount-verifying the DMG'
/bin/bash "$ROOT_DIR/scripts/build-macos-dmg.sh"
DMG_CANDIDATES=("$WHEREWE_DMG_OUTPUT_DIR"/Wherewe-*-arm64.dmg)
[[ "${#DMG_CANDIDATES[@]}" -eq 1 && -f "${DMG_CANDIDATES[0]}" ]] \
  || fail "the DMG build must produce exactly one fresh ARM64 DMG."
WHEREWE_DMG_PATH="${DMG_CANDIDATES[0]}"
case "$WHEREWE_DMG_PATH" in
  "$WHEREWE_DMG_OUTPUT_DIR"/*) ;;
  *) fail "the DMG selected for verification is outside the isolated output directory." ;;
esac
export WHEREWE_DMG_PATH
/bin/bash "$ROOT_DIR/scripts/test-macos-dmg.sh"

"$GIT_BIN" -C "$ROOT_DIR" status --porcelain=v1 -z --untracked-files=all > "$STATUS_AFTER"
[[ ! -s "$STATUS_AFTER" ]] \
  || fail "validation created or changed repository files; the Git worktree is no longer clean."

printf 'Local macOS pre-push gate passed; temporary artifacts were isolated under %s.\n' "$RUN_ROOT"
