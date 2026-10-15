#!/bin/bash
#
# Builds the two release artifacts in "dist/":
#
#   OpenBerg-<version>.dmg   the drag-to-Applications installer
#   OpenBerg-<version>.zip   the signed app bundle as a zip
#
#   1. scripts/build-app.sh builds and signs the app (one source of truth
#      for the bundle)
#   2. the DMG is staged with the app, an /Applications symlink and a
#      read-me, then compressed with diskutil (hdiutil create is deprecated
#      on macOS 27)
#   3. the ZIP is made with ditto, which preserves the bundle metadata the
#      signature covers
#
# The app carries the local "OpenBerg Dev" signature, not an Apple
# Developer ID, so a copy that was downloaded is blocked by Gatekeeper on
# first launch until the user allows it; "Read Me.txt" in the DMG shows the
# one-time steps. Notarized distribution would need a Developer ID and
# notarytool and is deliberately out of scope for now.
#
# Usage:  scripts/build-release.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

scripts/build-app.sh

APP="$ROOT/dist/OpenBerg.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
DMG="$ROOT/dist/OpenBerg-$VERSION.dmg"
ZIP="$ROOT/dist/OpenBerg-$VERSION.zip"

echo "==> Staging DMG contents"
STAGE="$ROOT/.build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# ditto, not cp: it preserves the bundle metadata the signature covers.
ditto "$APP" "$STAGE/OpenBerg.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/dmg-readme.txt" "$STAGE/Read Me.txt"

# The mounted volume shows the app icon too. The custom-icon flag is a BSD
# attribute rather than content, so it is set on the staged folder before
# the image is built; without SetFile the DMG still works, just with the
# generic disk icon.
cp "$ROOT/.build/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
	SetFile -a C "$STAGE"
fi

echo "==> Creating $DMG"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName "OpenBerg" "$STAGE" "$DMG" >/dev/null
rm -rf "$STAGE"
echo "==> Done: $DMG ($(du -sh "$DMG" | cut -f1))"

echo "==> Creating $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> Done: $ZIP ($(du -sh "$ZIP" | cut -f1))"
