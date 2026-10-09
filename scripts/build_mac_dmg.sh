#!/usr/bin/env bash
#
# Builds the macOS release app and packages it into build/macos/<app name>.dmg.
#
# The app is signed with the local Apple Development identity, so this DMG is a
# testing artifact rather than a distributable release: shipping one needs a
# Developer ID signature and notarization. If the build fails on provisioning,
# run scripts/run_macos.sh --ensure-only first and then rerun this script.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

flutter build macos --release

RELEASE_DIR="build/macos/Build/Products/Release"
if [ ! -d "$RELEASE_DIR" ]; then
  echo "error: $RELEASE_DIR does not exist, so the release build produced nothing." >&2
  exit 1
fi

APP_PATH="$(find "$RELEASE_DIR" -maxdepth 1 -name '*.app' -print -quit)"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "error: no .app in $RELEASE_DIR; the release build did not produce one." >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"
STAGE_DIR="build/macos/dmg"
DMG_PATH="build/macos/${APP_NAME}.dmg"

rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
echo "DMG created at: $DMG_PATH"
