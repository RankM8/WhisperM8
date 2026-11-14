#!/usr/bin/env bash
# Prüft an einer echten Claude-Code-CLI, worauf das Diktat in eine offene Frage
# baut (WM8-66, docs/features/controller.md, Schutzregeln). Bei jeder neuen
# Claude-Code-Version einmal fahren:
#
#   scripts/claude-question-paste-check.sh
#
# Läuft außerhalb der App in zwei Wegwerf-Sitzungen (tmux, eigener leerer
# Ordner), kostet zwei kurze Anfragen an das aktive Claude-Konto und fasst
# keinen echten Chat an. Geprüft wird:
#   1. Frage (AskUserQuestion): Ein Einfüge-Block mit Ziffern landet im freien
#      Textfeld und wählt keine Option aus; die Hinweiszeile lautet
#      „Enter to select · … to navigate“; Claudes Registry meldet `input needed`.
#   2. Freigabe (Bash rm mit ask-Regel): Derselbe Einfüge-Block bewirkt nichts,
#      die Datei bleibt; die Registry meldet `permission prompt`.
# Ergebnis: OK/FEHLER je Punkt, Rückgabe 1 bei einem Fehler.
set -uo pipefail

command -v tmux >/dev/null || { echo "tmux fehlt (brew install tmux)" >&2; exit 2; }
command -v claude >/dev/null || { echo "claude fehlt im PATH" >&2; exit 2; }

DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-question-check.XXXXXX")"
SESSION="wm8-question-check-$$"
FAILED=0
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

screen() { tmux capture-pane -t "$SESSION" -p; }

# Wartet, bis der Bildschirm das Muster zeigt (höchstens $2 Sekunden).
wait_for() {
    local pattern="$1" seconds="${2:-60}"
    for _ in $(seq 1 "$seconds"); do
        screen | grep -q -- "$pattern" && return 0
        sleep 1
    done
    return 1
}

check() {
    if [[ "$2" == ok ]]; then echo "OK      $1"; else echo "FEHLER  $1"; FAILED=1; fi
}

registry_waiting_for() {
    local pid
    pid="$(tmux list-panes -t "$SESSION" -F '#{pane_pid}')"
    python3 - "$CONFIG_DIR/sessions/$pid.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("waitingFor") or "")
except Exception:
    print("")
PY
}

start_claude() {
    tmux kill-session -t "$SESSION" 2>/dev/null
    # `exec`, damit die Pane-PID die von Claude ist (Registry-Datei <pid>.json).
    tmux new-session -d -s "$SESSION" -x 120 -y 40 -c "$DIR" \
        "exec env -u WHISPERM8_SESSION_ID claude --model sonnet --permission-mode default --settings '{\"permissions\":{\"ask\":[\"Bash(rm:*)\"]}}' $(printf %q "$1")"
    # Neuer Ordner: Vertrauens-Dialog bestätigen.
    if wait_for "trust this folder" 20; then
        tmux send-keys -t "$SESSION" Down; sleep 0.3; tmux send-keys -t "$SESSION" Enter
    fi
}

paste_block() {
    tmux set-buffer -b wm8check "$1"
    tmux paste-buffer -p -b wm8check -t "$SESSION"
    sleep 1.5
}

claude --version 2>/dev/null | head -1

# 1. Frage
start_claude 'Nutze sofort das Tool AskUserQuestion mit genau einer Frage "Welche Farbe?" und den Optionen Rot, Gruen, Blau. Sonst nichts.'
if wait_for "Enter to select" 90; then
    check "Frage: Hinweiszeile „Enter to select · … to navigate“" "$(screen | grep -q 'to navigate' && echo ok)"
    check "Frage: Option „Chat about this“ vorhanden" "$(screen | grep -q 'Chat about this' && echo ok)"
    check "Frage: Registry meldet input needed" "$([[ "$(registry_waiting_for)" == "input needed" ]] && echo ok)"
    paste_block "Lila, 2 Minuten"
    check "Frage: Einfüge-Block steht im Textfeld" "$(screen | grep -q 'Lila, 2 Minuten' && echo ok)"
    check "Frage: keine Option gewählt (Dialog noch offen)" "$(screen | grep -q 'Enter to select' && echo ok)"
else
    check "Frage-Dialog erschienen" fail
fi

# 2. Freigabe
touch "$DIR/check.txt"
start_claude 'Fuehre per Bash-Tool genau diesen Befehl aus: rm check.txt'
if wait_for "Do you want to proceed" 90; then
    check "Freigabe: Registry meldet permission prompt" "$([[ "$(registry_waiting_for)" == "permission prompt" ]] && echo ok)"
    paste_block "Ja klar, mach 1"
    sleep 2
    check "Freigabe: Einfüge-Block bewirkt nichts (Datei bleibt)" "$([[ -f "$DIR/check.txt" ]] && echo ok)"
    check "Freigabe: Dialog noch offen" "$(screen | grep -q 'Do you want to proceed' && echo ok)"
else
    check "Freigabe-Dialog erschienen" fail
fi

exit "$FAILED"
