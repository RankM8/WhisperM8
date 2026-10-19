#!/usr/bin/env bash
# Isolierte Test-Instanz von WhisperM8 — läuft NEBEN der Produktiv-App, ohne
# sie zu berühren (Doku: docs/features/ui-testing.md § Test-Instanz).
#
#   scripts/test-instance.sh build     # inkrementeller Release-Build → .build-test/WhisperM8Test.app
#   scripts/test-instance.sh start     # starten (im Hintergrund, kein Fokus, Fenster geparkt)
#   scripts/test-instance.sh stop      # nur die Test-Instanz beenden (SIGTERM)
#   scripts/test-instance.sh restart   # stop + start
#   scripts/test-instance.sh cli …     # whisperm8-CLI gegen die Test-Instanz, z. B. `cli debug state`
#   scripts/test-instance.sh status    # läuft sie? PID, Wurzel, Socket
#   scripts/test-instance.sh reset     # stop + Test-Daten, Test-Defaults und Test-Keychain löschen
#   scripts/test-instance.sh log       # Log der Test-Instanz (stdout/stderr)
#
# Isolation (AppInstance.swift): eigene Bundle-ID com.whisperm8.app.test (eigene
# Defaults-Domain), Home = $ROOT/home (darunter ~/.claude, ~/.codex, Application
# Support, Logs), eigener Control-Socket, eigener Keychain-Dienst, keine globalen
# Hotkeys, kein Dock-Icon, nie Fokus. Sicher aus einem WhisperM8-Chat: kein
# `make kill`, nie ein Prozess außerhalb von $APP.
#
# WHISPERM8_TEST_ROOT überschreibt die Wurzel, WHISPERM8_TEST_VISIBLE=1 zeigt die Fenster
# (=front: schwebend vor allen, ohne Fokus — für kurze Sichttests),
# WHISPERM8_TEST_LANG=en|de setzt die Sprache.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$REPO/.build-test"
APP="$SCRATCH/WhisperM8Test.app"
BIN="$APP/Contents/MacOS/WhisperM8"
ROOT="${WHISPERM8_TEST_ROOT:-$HOME/.whisperm8-test-instance}"
LOG="$ROOT/instance.log"
BUNDLE_ID="com.whisperm8.app.test"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

pids() {
    # Jede laufende Test-Instanz, auch aus einem anderen Worktree — es gibt nur
    # eine Wurzel, zwei Instanzen würden sich die Daten teilen. Nie die
    # Produktiv-App (anderer Bundle-Name).
    ps -axo pid=,comm= | awk '$2 ~ /\/WhisperM8Test\.app\/Contents\/MacOS\/WhisperM8$/ {print $1}'
}

cmd_build() {
    cd "$REPO"
    make --no-print-directory _build_dev DEV_SCRATCH=.build-test APP_BUNDLE="$APP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName WhisperM8 Test" "$APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleName string 'WhisperM8 Test'" "$APP/Contents/Info.plist"
    # Ohne CFBundleExecutable leitet LaunchServices das Binary aus dem Namen ab („WhisperM8 Test“ fehlt).
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string WhisperM8" "$APP/Contents/Info.plist" 2>/dev/null || true
    # Die UTIs gehören der Produktiv-App — ein zweiter Exporteur brächte LaunchServices durcheinander.
    /usr/libexec/PlistBuddy -c "Delete :UTExportedTypeDeclarations" "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 'WhisperM8 Test'" "$APP/Contents/Info.plist"
    local id
    id=$(security find-identity -p codesigning -v 2>/dev/null | grep "WhisperM8 Local Dev" | awk -F'"' '{print $2}' | head -1)
    codesign --force --deep --sign "${id:--}" --entitlements "WhisperM8/WhisperM8.entitlements" --timestamp=none "$APP" >/dev/null
    echo "✅ Test-Bundle: $APP"
}

seed_defaults() {
    # Frische Domain: Debug-Kanal an, GPT-Ports weg von den Produktiv-Ports.
    defaults write "$BUNDLE_ID" debugControlEnabled -bool YES
    defaults read "$BUNDLE_ID" claudeGPTBackendPort >/dev/null 2>&1 || defaults write "$BUNDLE_ID" claudeGPTBackendPort -int 28765
    defaults read "$BUNDLE_ID" claudeGPTRouterPort >/dev/null 2>&1 || defaults write "$BUNDLE_ID" claudeGPTRouterPort -int 28766
    # Sprache der Test-Instanz (en/de), sonst Systemsprache.
    if [[ -n "${WHISPERM8_TEST_LANG:-}" ]]; then
        defaults write "$BUNDLE_ID" AppleLanguages -array "$WHISPERM8_TEST_LANG"
    else
        defaults delete "$BUNDLE_ID" AppleLanguages >/dev/null 2>&1 || true
    fi
}

cmd_start() {
    [[ -x "$BIN" ]] || { echo "Kein Test-Bundle — erst: $0 build" >&2; exit 1; }
    if [[ -n "$(pids)" ]]; then
        echo "läuft bereits (PID $(pids | tr '\n' ' ')) — ggf. aus einem anderen Worktree; erst stoppen" >&2
        return 1
    fi
    mkdir -p "$ROOT/home"
    seed_defaults
    local env_args=(--env "WHISPERM8_INSTANCE_ROOT=$ROOT")
    [[ -n "${WHISPERM8_TEST_VISIBLE:-}" ]] && env_args+=(--env "WHISPERM8_TEST_VISIBLE=$WHISPERM8_TEST_VISIBLE")
    # Versteckt starten (-j), außer die Fenster sollen sichtbar sein.
    local hide=(-j)
    [[ -n "${WHISPERM8_TEST_VISIBLE:-}" ]] && hide=()
    open -n -g ${hide[@]+"${hide[@]}"} "${env_args[@]}" --stdout "$LOG" --stderr "$LOG" "$APP"
    for _ in $(seq 1 50); do
        if cmd_cli debug state >/dev/null 2>&1; then echo "✅ Test-Instanz läuft (PID $(pids | tr '\n' ' '))"; return 0; fi
        sleep 0.2
    done
    echo "⚠️  gestartet, Control-Socket antwortet noch nicht — $0 log" >&2
}

cmd_stop() {
    local p
    p=$(pids)
    [[ -z "$p" ]] && { echo "läuft nicht"; return 0; }
    kill -TERM $p
    for _ in $(seq 1 50); do [[ -z "$(pids)" ]] && { echo "beendet"; return 0; }; sleep 0.2; done
    echo "⚠️  reagiert nicht auf SIGTERM (PID $p)" >&2; exit 1
}

cmd_cli() {
    # Ohne die Session-Identität des aufrufenden Produktiv-Chats: die
    # Test-Instanz kennt dessen Token nicht und lehnt mutierende Befehle sonst ab.
    env -u WHISPERM8_SESSION_ID -u WHISPERM8_SESSION_TOKEN WHISPERM8_INSTANCE_ROOT="$ROOT" "$BIN" "$@"
}

cmd_status() {
    echo "Bundle:  $APP"
    echo "Wurzel:  $ROOT"
    echo "PID:     $(pids | tr '\n' ' ')"
    cat "$ROOT/home/Library/Application Support/WhisperM8/control/socket-path" 2>/dev/null | sed 's/^/Socket:  /' || true
}

cmd_reset() {
    cmd_stop
    rm -rf "$ROOT"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    while security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; do :; done
    echo "zurückgesetzt"
}

case "${1:-}" in
    build) cmd_build ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    cli) shift; cmd_cli "$@" ;;
    status) cmd_status ;;
    reset) cmd_reset ;;
    log) tail -n "${2:-80}" "$LOG" ;;
    *) sed -n '2,13p' "$0"; exit 64 ;;
esac
