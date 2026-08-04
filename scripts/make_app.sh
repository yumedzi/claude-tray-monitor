#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claude Tray Monitor"
BIN_NAME="ClaudeTrayMonitor"
CONFIG="${CONFIG:-release}"
APP_DIR="build/$APP_NAME.app"

swift build -c "$CONFIG" --product ClaudeTrayMonitor

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/$CONFIG/ClaudeTrayMonitor" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
echo "Built: $APP_DIR"