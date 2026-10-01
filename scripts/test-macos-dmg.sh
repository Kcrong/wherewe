#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="${WHEREWE_DMG_PATH:-}"
MOUNT_POINT=""

if [[ -z "$DMG_PATH" ]]; then
  shopt -s nullglob
  candidates=("${WHEREWE_DMG_OUTPUT_DIR:-$ROOT_DIR/dist/macos}"/Wherewe-*-arm64.dmg)
  shopt -u nullglob
  [[ "${#candidates[@]}" -eq 1 ]] || {
    printf 'Set WHEREWE_DMG_PATH to exactly one DMG to verify.\n' >&2
    exit 1
  }
  DMG_PATH="${candidates[0]}"
fi
[[ -f "$DMG_PATH" ]] || { printf 'DMG not found: %s\n' "$DMG_PATH" >&2; exit 1; }

teardown() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
}
trap teardown EXIT INT TERM

/usr/bin/hdiutil verify "$DMG_PATH" >/dev/null
ATTACH_PLIST="$(/usr/bin/hdiutil attach "$DMG_PATH" -readonly -nobrowse -plist)"
MOUNT_POINT="$(printf '%s' "$ATTACH_PLIST" | /usr/bin/python3 -c '
import plistlib, sys
payload = plistlib.loads(sys.stdin.buffer.read())
mounts = [entity.get("mount-point") for entity in payload.get("system-entities", []) if entity.get("mount-point")]
if len(mounts) != 1:
    raise SystemExit(f"expected one mount point, got {mounts}")
print(mounts[0])
')"

APP_PATH="$MOUNT_POINT/Wherewe.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Wherewe"
[[ -d "$APP_PATH" ]] || { printf 'Mounted DMG does not contain Wherewe.app.\n' >&2; exit 1; }
[[ -L "$MOUNT_POINT/Applications" ]] || { printf 'Mounted DMG has no Applications link.\n' >&2; exit 1; }
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]]
[[ -f "$APP_BINARY" ]] || { printf 'Mounted DMG is missing the app binary.\n' >&2; exit 1; }
/usr/bin/file "$APP_BINARY" | /usr/bin/grep -q 'arm64'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$APP_PATH/Contents/Info.plist")" == "26.0" ]]

for forbidden_directory in Frameworks Agents Models Sidecar Helpers; do
  [[ ! -e "$APP_PATH/Contents/$forbidden_directory" ]] || {
    printf 'Mounted app unexpectedly contains %s.\n' "$forbidden_directory" >&2
    exit 1
  }
done
if /usr/bin/find "$APP_PATH/Contents" \
  \( -iname '*.framework' -o -iname '*.xcframework' -o -iname '*.mlmodel' \
     -o -iname '*.mlmodelc' -o -iname '*.bin' -o -name node_modules \) \
  -print -quit | /usr/bin/grep -q .; then
  printf 'Mounted app contains an unexpected framework, model, or helper payload.\n' >&2
  exit 1
fi

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""
printf 'Native DMG smoke passed (version %s, macOS 26 ARM64 app, Apple system frameworks only, Applications link).\n' "$VERSION"
