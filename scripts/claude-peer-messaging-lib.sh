#!/usr/bin/env bash
# Hilfsfunktionen für Messungen an Claudes nativem Sitzungs-Messaging
# (ListAgents/SendMessage, WM8-79). Wird von scripts/claude-peer-messaging-check.sh
# geladen, lässt sich aber auch von Hand nutzen:
#
#   source scripts/claude-peer-messaging-lib.sh
#   peer_start a ai default          # Sitzung „a“ auf Konto ai
#   peer_prompt a 'Sag nur OK.'
#   peer_screen a
#   peer_stop_all
#
# Alles läuft auf einem eigenen tmux-Server (-L wm8peer) in EINEM festen
# Wegwerf-Ordner, mit leerer Umgebung (env -i), damit nichts aus dem
# aufrufenden Chat (Messaging-Socket, WhisperM8-Session, GPT-Proxy) erbt.
# Echte Chats werden nicht angefasst.

PEER_TMUX=(tmux -L wm8peer)
PEER_DIR="${PEER_DIR:-${TMPDIR:-/tmp}/wm8-peer-messaging-check}"
PEER_PROFILES="$HOME/.claude-profiles"
mkdir -p "$PEER_DIR/logs"

# Konto -> Konfigurationsordner. „main“ = kein CLAUDE_CONFIG_DIR.
peer_config_dir() {
    if [[ "$1" == main ]]; then echo "$HOME/.claude"; else echo "$PEER_PROFILES/$1"; fi
}

# Bricht ab, wenn der Konto-Ordner fehlt. Sonst legte Claude dort ein leeres
# Konto an, und die App zeigte es als Geister-Konto.
peer_require_account() {
    local dir conf; dir="$(peer_config_dir "$1")"
    # Hauptkonto: Konfiguration liegt in ~/.claude.json, sonst im Profil-Ordner.
    if [[ "$1" == main ]]; then conf="$HOME/.claude.json"; else conf="$dir/.claude.json"; fi
    if [[ ! -d "$dir" || ! -f "$conf" ]]; then
        echo "Konto „$1“ fehlt ($dir) — Abbruch, damit kein leeres Konto entsteht" >&2
        return 1
    fi
}

# peer_start <name> <konto> <permission-mode> [settings-json-datei] [zusatz-env...]
peer_start() {
    local name="$1" account="$2" mode="$3" settings="${4:-}"
    peer_require_account "$account" || return 1
    shift 4 2>/dev/null || shift $#
    local envs=(HOME="$HOME" USER="$USER" PATH="$PATH" TERM=xterm-256color LANG="${LANG:-de_DE.UTF-8}" SHELL=/bin/zsh)
    [[ "$account" != main ]] && envs+=(CLAUDE_CONFIG_DIR="$(peer_config_dir "$account")")
    envs+=("$@")
    local args=(claude --model sonnet --name "$name" --permission-mode "$mode")
    [[ -n "$settings" ]] && args+=(--settings "$settings")
    "${PEER_TMUX[@]}" kill-session -t "$name" 2>/dev/null
    # exec: Pane-PID = Claude-PID (Registry <config>/sessions/<pid>.json)
    "${PEER_TMUX[@]}" new-session -d -s "$name" -x 160 -y 50 -c "$PEER_DIR" \
        "exec env -i $(printf '%q ' "${envs[@]}") $(printf '%q ' "${args[@]}")"
    # Vertrauens-Dialog (erster Start je Konto in diesem Ordner)
    local s
    for _ in $(seq 1 25); do
        s="$(peer_screen "$name")"
        if grep -q "trust this folder" <<<"$s"; then
            # Vorauswahl ist „No, exit“ -> erst nach unten
            "${PEER_TMUX[@]}" send-keys -t "$name" Down; sleep 0.3
            "${PEER_TMUX[@]}" send-keys -t "$name" Enter; sleep 2
        fi
        grep -q -E '^\s*(❯|>)\s' <<<"$s" && grep -q -i -E 'for shortcuts|bypass|accept edits|auto mode|plan mode|\? for' <<<"$s" && break
        sleep 1
    done
}

peer_screen() { "${PEER_TMUX[@]}" capture-pane -t "$1" -p 2>/dev/null; }
peer_pid() { "${PEER_TMUX[@]}" list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null; }

# Registry-Eintrag der Sitzung (ohne Schlüssel).
peer_registry() {
    local name="$1" account="$2" pid
    pid="$(peer_pid "$name")"
    python3 - "$(peer_config_dir "$account")/sessions/$pid.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    keep = ("pid", "name", "nameSource", "status", "waitingFor", "messagingSocketPath", "peerFeatures", "version")
    print(json.dumps({k: d.get(k) for k in keep}, ensure_ascii=False))
except Exception as e:
    print("{}  # " + str(e))
PY
}

# Text als Einfüge-Block eingeben und absenden.
peer_prompt() {
    local name="$1" text="$2"
    "${PEER_TMUX[@]}" set-buffer -b wm8peer "$text"
    "${PEER_TMUX[@]}" paste-buffer -p -b wm8peer -t "$name"
    sleep 0.8
    "${PEER_TMUX[@]}" send-keys -t "$name" Enter
}

# Wartet, bis der Bildschirm das Muster zeigt (höchstens $3 Sekunden).
peer_wait_for() {
    local name="$1" pattern="$2" seconds="${3:-60}"
    for _ in $(seq 1 "$seconds"); do
        peer_screen "$name" | grep -q -E -- "$pattern" && return 0
        sleep 1
    done
    return 1
}

# Wartet, bis der Registry-Status den Wert hat.
peer_wait_status() {
    local name="$1" account="$2" want="$3" seconds="${4:-90}"
    for _ in $(seq 1 "$seconds"); do
        peer_registry "$name" "$account" | grep -q "\"status\": \"$want\"" && return 0
        sleep 1
    done
    return 1
}

# Settings-Datei mit Hook-Mitschnitt (UserPromptSubmit, Stop, Notification) ins
# Log <name>.hooks.jsonl. Erlaubt sind nur SendMessage und ListAgents; mehr
# Rechte gibt das zweite Argument (JSON, ersetzt gleichnamige Schlüssel), etwa
# '{"permissions":{"allow":["SendMessage","ListAgents","Bash(sleep 30)"]}}'.
peer_hook_settings() {
    local name="$1" extra="${2:-}"
    local log="$PEER_DIR/logs/$name.hooks.jsonl" file="$PEER_DIR/$name.settings.json"
    local cmd="python3 -c 'import sys,json,time; d=json.load(sys.stdin); d[\"_t\"]=time.strftime(\"%H:%M:%S\"); open(\"$log\",\"a\").write(json.dumps(d,ensure_ascii=False)+\"\\n\")'"
    python3 - "$file" "$cmd" "$extra" <<'PY'
import json, sys
path, cmd, extra = sys.argv[1], sys.argv[2], sys.argv[3]
hook = [{"hooks": [{"type": "command", "command": cmd}]}]
d = {"hooks": {"UserPromptSubmit": hook, "Stop": hook, "Notification": hook},
     "permissions": {"allow": ["SendMessage", "ListAgents"]}}
if extra:
    d.update(json.loads(extra))
json.dump(d, open(path, "w"), indent=1)
PY
    echo "$file"
}

peer_stop_all() {
    "${PEER_TMUX[@]}" kill-server 2>/dev/null
    sleep 1
}
