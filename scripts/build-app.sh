#!/bin/bash
#
# Builds "OpenBerg.app".
#
#   1. builds the release binary with SwiftPM
#   2. assembles the bundle and signs it (OpenBerg Dev, ad-hoc fallback)
#
# Usage:  scripts/build-app.sh [--run]
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="OpenBerg"
BUNDLE_ID="com.openberg.AtombergFan"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release

BINARY="$ROOT/.build/release/OpenBerg"
if [ ! -x "$BINARY" ]; then
	echo "error: expected binary at $BINARY" >&2
	exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/OpenBerg"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# The icon is drawn from code rather than committed as art, so the bundle's
# only image is generated from Tools/GenerateAppIcon.swift on every build.
ICON="$ROOT/.build/AppIcon.icns"
swift "$ROOT/Tools/GenerateAppIcon.swift" "$ICON" >/dev/null
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# A stable signing identity keeps the keychain ACL happy: the keychain
# records *which signature* may read the credentials item, and ad-hoc
# signatures change every build, which is what used to re-trigger the
# permission dialog. Fall back to ad-hoc if the cert is missing.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"OpenBerg Dev"'; then
	echo "==> Signing (OpenBerg Dev)"
	codesign --force --sign "OpenBerg Dev" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
	echo "==> Signing (ad-hoc)"
	codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Done: $APP ($SIZE)"

if [ "${1:-}" = "--run" ]; then
	echo "==> Launching"
	open "$APP"
fi
