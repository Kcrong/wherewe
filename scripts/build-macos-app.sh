#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_ROOT="${WHEREWE_NATIVE_BUILD_DIR:-${TMPDIR:-/tmp}/wherewe-native-build}"
DIST_DIR="${WHEREWE_NATIVE_DIST_DIR:-$ROOT_DIR/dist/macos}"
APP_PATH="$DIST_DIR/Wherewe.app"
CONTENTS="$APP_PATH/Contents"
IDENTITY="${WHEREWE_CODESIGN_IDENTITY:--}"

sign_item() {
  if [[ "$IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$@"
  else
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$@"
  fi
}

[[ "$(uname -s)" == "Darwin" ]] || {
  printf 'This build script requires macOS.\n' >&2
  exit 1
}
[[ "$(uname -m)" == "arm64" ]] || {
  printf 'This build script targets Apple Silicon arm64.\n' >&2
  exit 1
}
[[ ! -e "$APP_PATH" ]] || {
  printf 'Refusing to overwrite an existing app bundle: %s\n' "$APP_PATH" >&2
  printf 'Set WHEREWE_NATIVE_DIST_DIR to a new output directory.\n' >&2
  exit 1
}

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
/usr/bin/xcrun swift build \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$BUILD_ROOT" \
  --configuration "$CONFIGURATION" \
  --product Wherewe

BIN_DIR="$(
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  /usr/bin/xcrun swift build \
    --package-path "$PACKAGE_DIR" \
    --scratch-path "$BUILD_ROOT" \
    --configuration "$CONFIGURATION" \
    --show-bin-path
)"

/usr/bin/ditto "$BIN_DIR/Wherewe" "$CONTENTS/MacOS/Wherewe"
/usr/bin/ditto "$PACKAGE_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/bin/plutil -lint "$CONTENTS/Info.plist"

APP_BINARY="$CONTENTS/MacOS/Wherewe"
/usr/bin/file "$APP_BINARY" | /usr/bin/grep -q 'arm64'

for forbidden_directory in Frameworks Agents Models; do
  [[ ! -e "$CONTENTS/$forbidden_directory" ]] || {
    printf 'Native app unexpectedly contains %s.\n' "$forbidden_directory" >&2
    exit 1
  }
done
if /usr/bin/find "$CONTENTS" \
  \( -iname '*.framework' -o -iname '*.xcframework' -o -iname '*.mlmodel' \
     -o -iname '*.mlmodelc' -o -iname '*.bin' \) \
  -print -quit | /usr/bin/grep -q .; then
  printf 'Native app unexpectedly contains an embedded framework or model asset.\n' >&2
  exit 1
fi

LOAD_COMMANDS="$BUILD_ROOT/wherewe-load-commands.txt"
/usr/bin/otool -l "$APP_BINARY" > "$LOAD_COMMANDS"
if /usr/bin/grep -Fq '@executable_path/../Frameworks' "$LOAD_COMMANDS"; then
  printf 'Native app contains an external-framework runtime search path.\n' >&2
  exit 1
fi

APP_ENTITLEMENTS="$PACKAGE_DIR/Resources/MeetingTranscriber.entitlements"
sign_item --options runtime --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

SIGNED_ENTITLEMENTS="$BUILD_ROOT/signed-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$APP_PATH" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
/usr/bin/grep -Fq 'com.apple.security.device.audio-input' "$SIGNED_ENTITLEMENTS" || {
  printf 'Signed app is missing the audio-input entitlement.\n' >&2
  exit 1
}

printf '%s\n' "$APP_PATH"
