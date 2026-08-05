#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claude Tray Monitor"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "Resources/Info.plist")
COMMIT_URL="https://github.com/yumedzi/claude-tray-monitor/commit/$(git rev-parse HEAD)"
TAG="v$VERSION"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: 'gh' CLI is required. Install via 'brew install gh' and run 'gh auth login'." >&2
  exit 1
fi

make dmg
make release

NOTES="Install: open the DMG and drag **Claude Tray Monitor.app** into your Applications folder.
On first launch, right-click the app and choose **Open** (ad-hoc signed).

Built from \`$COMMIT_URL\`"

if gh release view "$TAG" --repo yumedzi/claude-tray-monitor >/dev/null 2>&1; then
  echo "Release $TAG already exists; deleting and recreating." >&2
  gh release delete "$TAG" --repo yumedzi/claude-tray-monitor --yes --cleanup-tag
fi

gh release create "$TAG" \
  "build/ClaudeTrayMonitor-macos.dmg" \
  "build/ClaudeTrayMonitor-macos.zip" \
  --repo yumedzi/claude-tray-monitor \
  --title "Claude Tray Monitor $VERSION" \
  --notes "$NOTES"

echo "Published: $TAG"