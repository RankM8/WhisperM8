#!/usr/bin/env bash
#
# UI-Snapshots: rendert die Galerie (Tests/WhisperM8Tests/UISnapshotGallery.swift)
# als PNG — jede Ansicht in festen Zuständen, hell und dunkel. Kein App-Start,
# keine Berechtigungen, die laufende App bleibt unberührt (sicher auch aus einem
# Agent-Chat heraus).
#
#   scripts/ui-snapshots.sh                 # alle → .build/ui-snapshots/<zeit>/
#   scripts/ui-snapshots.sh chatgpt         # nur Fixtures, deren Name „chatgpt" enthält
#   UI_SNAPSHOT_DIR=/pfad scripts/ui-snapshots.sh
#
# Jeder Lauf schreibt in einen eigenen Zeitstempel-Ordner (nichts wird gelöscht);
# die letzte Zeile der Ausgabe nennt ihn.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONLY="${1:-}"
OUT="${UI_SNAPSHOT_DIR:-$REPO_ROOT/.build/ui-snapshots/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$REPO_ROOT"

LOG="$(mktemp "${TMPDIR:-/tmp}/whisperm8-ui-snapshots.XXXXXX")"
if ! WHISPERM8_SNAPSHOT_DIR="$OUT" WHISPERM8_SNAPSHOT_ONLY="$ONLY" \
    swift test --filter UISnapshotGallery >"$LOG" 2>&1; then
    grep -E "error:|failed" "$LOG" | sort -u | head -20 >&2 || true
    echo "UI-Snapshots fehlgeschlagen — volles Log: $LOG" >&2
    exit 1
fi
rm -f "$LOG"

ls -1 "$OUT"/*.png
echo "→ $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') Bilder in $OUT"
