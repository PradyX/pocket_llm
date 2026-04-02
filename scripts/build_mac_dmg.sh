flutter build macos --release

APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
APP_NAME="$(basename "$APP_PATH" .app)"
STAGE_DIR="build/macos/dmg"
DMG_PATH="build/macos/${APP_NAME}.dmg"

rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
echo "DMG created at: $DMG_PATH"
