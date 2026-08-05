#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claude Tray Monitor"
DMG_NAME="ClaudeTrayMonitor-macos"
STAGING="build/dmg-staging"

./scripts/make_app.sh

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "build/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Claude Tray Monitor" -srcfolder "$STAGING" -ov -format UDZO "build/$DMG_NAME.dmg"
rm -rf "$STAGING"
echo "DMG: build/$DMG_NAME.dmg"
