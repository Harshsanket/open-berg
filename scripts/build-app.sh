#!/bin/bash
#
# Builds "OpenBerg.app".
#
#   1. regenerates the icons from assets/fan-asset.jpg
#   2. builds the release binary with SwiftPM
#   3. assembles the bundle and signs it ad-hoc
#
# Usage:  scripts/build-app.sh [--run]
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="OpenBerg"
BUNDLE_ID="com.openberg.AtombergFan"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> Generating icons from assets/fan-asset.jpg"
mkdir -p "$ROOT/.build/tools"
swiftc -O "$ROOT/Tools/GenerateIcons.swift" -o "$ROOT/.build/tools/generate-icons"
"$ROOT/.build/tools/generate-icons"

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

# Only what the running app reads at runtime; the debug contact sheet stays out.
for resource in AppIcon.icns \
	MenuBarIcon.png MenuBarIcon@2x.png MenuBarIcon@3x.png \
	FanHero.png FanBanner.png FanBannerDark.png; do
	if [ -f "$ROOT/Resources/$resource" ]; then
		cp "$ROOT/Resources/$resource" "$APP/Contents/Resources/$resource"
	else
		echo "error: missing Resources/$resource" >&2
		exit 1
	fi
done

plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Done: $APP ($SIZE)"

if [ "${1:-}" = "--run" ]; then
	echo "==> Launching"
	open "$APP"
fi
