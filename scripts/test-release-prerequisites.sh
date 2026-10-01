#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'release prerequisite gate: %s\n' "$1" >&2
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
command -v node >/dev/null 2>&1 || fail "node is required."
command -v git >/dev/null 2>&1 || fail "git is required."
[[ -f "$PACKAGE_DIR/Package.swift" ]] || fail "macOS Swift package not found."
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || fail "DEVELOPER_DIR is unavailable."
export DEVELOPER_DIR
/usr/bin/xcrun --find swift >/dev/null 2>&1 || fail "the Swift toolchain is unavailable through xcrun."

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
  *) fail "the selected scratch root must be absolute." ;;
esac
[[ -d "$SCRATCH_CANDIDATE" && -w "$SCRATCH_CANDIDATE" ]] \
  || fail "the selected scratch root is not a writable directory."
SCRATCH_ROOT="$(cd "$SCRATCH_CANDIDATE" && pwd -P)"
case "$SCRATCH_ROOT" in
  "$ROOT_DIR"|"$ROOT_DIR"/*) fail "the scratch root must be outside the repository." ;;
esac

RUN_ROOT="$(mktemp -d "$SCRATCH_ROOT/wherewe-release-prerequisites.XXXXXX")" \
  || fail "could not create an isolated run directory."
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
export WHEREWE_DMG_BUILD_DIR="$RUN_ROOT/native-dmg-build"
export WHEREWE_DMG_OUTPUT_DIR="$RUN_ROOT/native-dmg-dist"
export WHEREWE_CODESIGN_IDENTITY="-"
unset WHEREWE_DMG_PATH

STATUS_BEFORE="$RUN_ROOT/git-status-before"
STATUS_AFTER="$RUN_ROOT/git-status-after"
git -C "$ROOT_DIR" status --porcelain=v1 -z --untracked-files=all > "$STATUS_BEFORE"
[[ ! -s "$STATUS_BEFORE" ]] || fail "the Git worktree must be clean before release prerequisite validation."

printf '%s\n' '==> Checking JavaScript and shell syntax'
for source in \
  "$ROOT_DIR"/tests/native/*.test.js \
  "$ROOT_DIR"/tests/public/*.test.js \
  "$ROOT_DIR"/scripts/scan-public-content.js; do
  node --check "$source"
done
for script in "$ROOT_DIR"/scripts/*.sh; do
  /bin/bash -n "$script"
done

printf '%s\n' '==> Running redacted public-content scan and Node contracts'
(
  cd "$ROOT_DIR"
  node scripts/scan-public-content.js
  node --test tests/native/*.test.js tests/public/*.test.js
)

printf '%s\n' '==> Running deterministic Swift baseline'
/usr/bin/xcrun swift test \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$WHEREWE_NATIVE_BUILD_DIR"

printf '%s\n' '==> Running native service core checks'
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

printf '%s\n' '==> Building and smoke-testing ad-hoc app and DMG'
/bin/bash "$ROOT_DIR/scripts/build-macos-app.sh"
/bin/bash "$ROOT_DIR/scripts/test-macos-app-bundle.sh"
/bin/bash "$ROOT_DIR/scripts/build-macos-dmg.sh"
DMG_CANDIDATES=("$WHEREWE_DMG_OUTPUT_DIR"/Wherewe-*-arm64.dmg)
[[ "${#DMG_CANDIDATES[@]}" -eq 1 && -f "${DMG_CANDIDATES[0]}" ]] \
  || fail "the preflight must produce exactly one fresh ARM64 DMG."
WHEREWE_DMG_PATH="${DMG_CANDIDATES[0]}"
export WHEREWE_DMG_PATH
/bin/bash "$ROOT_DIR/scripts/test-macos-dmg.sh"

git -C "$ROOT_DIR" status --porcelain=v1 -z --untracked-files=all > "$STATUS_AFTER"
[[ ! -s "$STATUS_AFTER" ]] \
  || fail "release prerequisite validation changed the Git worktree."

printf 'Release prerequisite gate passed; isolated output was created under %s.\n' "$RUN_ROOT"
