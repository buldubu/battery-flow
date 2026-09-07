#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_ROOT="$ROOT/build/ui-review"
PACKAGE="$REVIEW_ROOT/package"
SOURCE_DIR="$PACKAGE/Sources/BatteryFlowUIReview"
APP="$REVIEW_ROOT/BatteryFlowUIReview.app"
REVIEW_DATA="$(mktemp -d "${TMPDIR:-/tmp/}BatteryFlowUIReview.XXXXXX")"

mkdir -p "$REVIEW_ROOT"
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
for source in "$ROOT/Sources/BatteryFlow/"*.swift; do
    if [[ "$(basename "$source")" != "BatteryFlowApp.swift" ]]; then cp "$source" "$SOURCE_DIR/"; fi
done
cp "$ROOT/Scripts/UIReview.swift" "$SOURCE_DIR/"
cat > "$PACKAGE/Package.swift" <<'PACKAGE_FILE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BatteryFlowUIReview", platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "BatteryFlowUIReview")])
PACKAGE_FILE

swift build --package-path "$PACKAGE" -c release
pkill -x BatteryFlowUIReview 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PACKAGE/.build/release/BatteryFlowUIReview" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string BatteryFlowUIReview "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.buldubu.BatteryFlow.UIReview "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Battery Flow UI Review" "$APP/Contents/Info.plist"
plutil -replace LSUIElement -bool NO "$APP/Contents/Info.plist"
plutil -insert BFReviewHistoryPath -string "$REVIEW_DATA/history.jsonl" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [[ -f "$HOME/Library/Application Support/BatteryFlow/power-history.jsonl" ]]; then
    cp "$HOME/Library/Application Support/BatteryFlow/power-history.jsonl" "$REVIEW_DATA/history.jsonl"
fi
open "$APP"
printf 'Review app: %s\nHistory copy: %s\n' "$APP" "$REVIEW_DATA/history.jsonl"
