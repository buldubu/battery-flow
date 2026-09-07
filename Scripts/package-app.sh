#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/BatteryFlow.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/BatteryFlow" "$APP/Contents/MacOS/BatteryFlow"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
for NOTICE in LICENSE THIRD_PARTY_NOTICES.md; do
    if [[ -f "$ROOT/$NOTICE" ]]; then
        cp "$ROOT/$NOTICE" "$APP/Contents/Resources/$NOTICE"
    fi
done
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "$APP"
