#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/build/BatteryFlow.app"
DESTINATION="/Applications/BatteryFlow.app"
HISTORY_FILE="$HOME/Library/Application Support/BatteryFlow/power-history.jsonl"

"$ROOT/Scripts/package-app.sh"
codesign --verify --deep --strict "$SOURCE"
ROLLBACK_DIR="$(mktemp -d "$ROOT/build/rollback-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
if [[ -d "$DESTINATION" ]]; then ditto "$DESTINATION" "$ROLLBACK_DIR/BatteryFlow.app"; fi

# Stop the old writer before taking the history snapshot.
pkill -x BatteryFlow 2>/dev/null || true
for attempt in {1..50}; do
    pgrep -x BatteryFlow >/dev/null || break
    sleep 0.1
done
if pgrep -x BatteryFlow >/dev/null; then
    echo "Battery Flow did not exit; installation stopped before replacing it." >&2
    exit 1
fi
if [[ -f "$HISTORY_FILE" ]]; then cp "$HISTORY_FILE" "$ROLLBACK_DIR/power-history.jsonl"; fi
defaults export local.buldubu.BatteryFlow "$ROLLBACK_DIR/preferences.plist" 2>/dev/null || true

rm -rf "$DESTINATION"
if ! ditto "$SOURCE" "$DESTINATION" || ! codesign --verify --deep --strict "$DESTINATION"; then
    rm -rf "$DESTINATION"
    if [[ -d "$ROLLBACK_DIR/BatteryFlow.app" ]]; then
        ditto "$ROLLBACK_DIR/BatteryFlow.app" "$DESTINATION"
        open "$DESTINATION"
    fi
    echo "Installation failed; the previous application was restored." >&2
    exit 1
fi
open "$DESTINATION"
echo "Installed: $DESTINATION"
echo "Rollback backup: $ROLLBACK_DIR"
