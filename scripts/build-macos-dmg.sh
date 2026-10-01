#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${WHEREWE_NATIVE_APP_PATH:-${WHEREWE_NATIVE_DIST_DIR:-$ROOT_DIR/dist/macos}/Wherewe.app}"
OUTPUT_DIR="${WHEREWE_DMG_OUTPUT_DIR:-$ROOT_DIR/dist/macos}"
BUILD_ROOT="${WHEREWE_DMG_BUILD_DIR:-${TMPDIR%/}/wherewe-dmg-build}"
IDENTITY="${WHEREWE_CODESIGN_IDENTITY:-}"
VOLUME_NAME="Wherewe"

[[ -d "$APP_PATH" ]] || { printf 'Native app bundle not found: %s\n' "$APP_PATH" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  printf 'Invalid app version for DMG: %s\n' "$VERSION" >&2
  exit 1
}
DMG_NAME="Wherewe-${VERSION}-arm64.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
STAGING_DIR="$BUILD_ROOT/staging"

if [[ -e "$DMG_PATH" ]]; then
  printf 'Refusing to overwrite an existing DMG: %s\n' "$DMG_PATH" >&2
  exit 1
fi
if [[ -e "$STAGING_DIR" ]]; then
  printf 'Refusing to reuse an existing DMG staging directory: %s\n' "$STAGING_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Wherewe.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
  /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
fi
/usr/bin/hdiutil verify "$DMG_PATH"

printf '%s\n' "$DMG_PATH"
