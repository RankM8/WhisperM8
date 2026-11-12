#!/usr/bin/env bash
# Dauerlauf „Neustart ohne Chatverlust“ (Paket 6) — nur gegen die Test-Instanz.
# Plan: docs/plans/neustart-ohne-chatverlust.md, Abschnitt „Pflichttest“.
#
#   scripts/handover-soak.sh capabilities        # welche Startbefehle aus Paket 4 schon da sind
#   scripts/handover-soak.sh run [--rounds N]    # Chats anlegen, N Neustarts, prüfen, Bericht (Standard 5)
#            [--keep] [--report <datei>]          #   --keep: Chats danach nicht beenden
#            [--use-running]                      #   eine schon laufende Test-Instanz benutzen
#   scripts/handover-soak.sh self-test           # Prüf-Funktionen gegen Beispieldaten (ohne App)
#
# Beteiligt (wie im Plan, ohne GPT-Chat — die Test-Instanz hat kein GPT-Login):
#   bash      Claude-Chat mit vielen Bash-Schritten
#   stream    Claude-Chat mit langer gestreamter Antwort
#   codex     Codex-Chat mit Shell-Schritten
#   counter   Terminal-Tab mit Zähler                  (braucht Paket 4: --provider terminal)
#   attached  angedockter Hintergrund-Chat              (braucht Paket 4: --background)
#   question  Chat mit offener Rückfrage
#
# Prüfungen je Durchgang: gleiche PIDs; kein „API Error“/„Retrying“; Antworten
# vollständig (am Ende); Rückfrage offen; Zähler lückenlos; kein zweiter Prozess
# je Sitzung; `chats list` aus jedem Chat; keine doppelte Fertig-Meldung;
# Aufbewahrer nach dem Ende weg.
#
# Ergebnis je Prüfung: OK, FEHLER oder FEHLT (Startbefehl/Messpunkt aus Paket 4
# noch nicht da — dann wird ehrlich nicht geprüft). Exit: 0 alles OK, 1 mindestens
# ein FEHLER, 2 kein FEHLER, aber etwas FEHLT, 64 Aufruf.
#
# Sicherheit: Alle App-Befehle laufen über scripts/test-instance.sh (eigene Wurzel,
# eigene Bundle-ID). Nie `make dev|kill|run|install`, nie die Produktiv-App, nie
# `claude --bg/attach/stop` an echten Sitzungen. Codex-Update-Prüfung wird in der
# Test-Instanz abgeschaltet, damit kein Enter einen Update-Dialog bestätigt.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TI="$REPO/scripts/test-instance.sh"
ROOT="${WHISPERM8_TEST_ROOT:-$HOME/.whisperm8-test-instance}"
BIN="$REPO/.build-test/WhisperM8Test.app/Contents/MacOS/WhisperM8"
PY=/usr/bin/python3
SOAK="$ROOT/soak"
STATE="$SOAK/state"
PROJECT="$SOAK/project"
COUNTER_FILE="$SOAK/counter.log"
ROUNDS=5
KEEP=0
REPORT=""
USE_RUNNING=0

# Prompts: kurz, mit Endmarken, die die Prüfungen wiederfinden.
PROMPT_BASH='Führe bitte nacheinander 40 Bash-Befehle einzeln aus, jeweils `echo SOAK-STEP-<n>; sleep 3` mit n von 1 bis 40. Keine Zusammenfassung dazwischen. Schreibe am Ende genau SOAK-BASH-ENDE.'
PROMPT_STREAM='Schreibe ohne Werkzeuge 400 nummerierte Zeilen im Format „Zeile <n>: <kurzer Satz>“ und zum Schluss genau SOAK-STREAM-ENDE.'
PROMPT_CODEX='Führe nacheinander 30 Shell-Befehle einzeln aus: `echo SOAK-CODEX-<n>; sleep 3` mit n von 1 bis 30. Schreibe am Ende genau SOAK-CODEX-ENDE.'
PROMPT_QUESTION='Stell mir mit dem Werkzeug AskUserQuestion genau eine Frage: „Welche Farbe soll der Test haben?“ mit den Optionen Rot und Blau. Warte dann auf meine Antwort und tu sonst nichts.'
PROMPT_ATTACHED='Führe nacheinander 30 Bash-Befehle einzeln aus: `echo SOAK-BG-<n>; sleep 4`. Schreibe am Ende genau SOAK-BG-ENDE.'
COUNTER_COMMAND="i=0; while :; do i=\$((i+1)); echo \$i >> '$COUNTER_FILE'; echo \"zähler \$i\"; sleep 1; done"

ti() { "$TI" "$@"; }
cli() { "$TI" cli "$@"; }
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# MARK: - Ergebnisse

RESULTS=""   # Zeilen: runde<TAB>prüfung<TAB>OK|FEHLER|FEHLT<TAB>detail
record() {
    RESULTS="${RESULTS}$1	$2	$3	$4
"
    log "[$1] $2: $3 ${4:+— $4}"
}

# MARK: - Fähigkeiten (Paket 4)

has_keep_chats() { grep -q -- '--keep-chats' "$TI"; }
has_terminal_tabs() { cli chats help 2>/dev/null | grep -qE -- '--provider [^ ]*terminal'; }
has_background_chats() { cli chats help 2>/dev/null | grep -q -- '--background'; }
has_terminal_text() { cli debug help 2>/dev/null | grep -q '^  terminal'; }
has_notification_log() { grep -rq 'session_notification_posted' "$REPO/WhisperM8" 2>/dev/null; }

cmd_capabilities() {
    local name check
    if [[ ! -x "$BIN" ]]; then
        echo "unbekannt: kein Test-Bundle ($BIN) — erst scripts/test-instance.sh build" >&2
    fi
    for name in keep_chats terminal_tabs background_chats terminal_text notification_log; do
        check="has_$name"
        if "$check"; then echo "da     $name"; else echo "fehlt  $name"; fi
    done
}

# MARK: - Reine Prüf-Funktionen (testbar per self-test)

# Zahlenfolge (eine Zahl je Zeile) lückenlos und ohne Neubeginn? Ausgabe: Befund.
check_counter_file() {
    "$PY" -I - "$1" <<'PYEOF'
import sys
nums = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if line.isdigit():
        nums.append(int(line))
if not nums:
    print("FEHLER leer"); sys.exit(0)
for a, b in zip(nums, nums[1:]):
    if b != a + 1:
        print(f"FEHLER Sprung {a} -> {b}"); sys.exit(0)
print(f"OK {nums[0]}..{nums[-1]}")
PYEOF
}

# Claudes Registry (<home>/.claude/sessions/*.json): je Sitzung die lebenden PIDs.
# Ausgabe: „sessionId pid pid…“ je Zeile; mehr als eine PID = zweiter Prozess.
registry_pids() {
    "$PY" -I - "$1" <<'PYEOF'
import json, os, sys, glob
alive = lambda p: (lambda: (os.kill(p, 0), True)[1])
result = {}
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        data = json.load(open(path))
    except Exception:
        continue
    sid = data.get("sessionId") or data.get("session_id")
    pid = data.get("pid") or int(os.path.basename(path).split(".")[0])
    if not sid:
        continue
    try:
        os.kill(int(pid), 0)
    except Exception:
        continue
    result.setdefault(sid, []).append(int(pid))
for sid, pids in sorted(result.items()):
    print(sid, *sorted(pids))
PYEOF
}

# Transcript (JSONL) auf API-Fehler und Wiederholungen ab Byte-Position durchsuchen.
scan_transcript_errors() {
    "$PY" -I - "$1" "${2:-0}" <<'PYEOF'
import sys
path, start = sys.argv[1], int(sys.argv[2])
hits = []
with open(path, "rb") as f:
    f.seek(start)
    for raw in f:
        line = raw.decode("utf-8", "replace")
        if '"isApiErrorMessage":true' in line.replace(" ", "") or "API Error" in line or "Retrying" in line:
            hits.append(line[:120].strip())
print("FEHLER " + " | ".join(hits[:3]) if hits else "OK")
PYEOF
}

# Endmarke und (optional) lückenlose „Zeile n:“-Folge im Transcript.
check_answer_complete() {
    "$PY" -I - "$1" "$2" "${3:-0}" <<'PYEOF'
import sys, re, json
path, marker, lines = sys.argv[1], sys.argv[2], int(sys.argv[3])
text = []
for raw in open(path, encoding="utf-8", errors="replace"):
    try:
        entry = json.loads(raw)
    except Exception:
        continue
    msg = entry.get("message") or {}
    if msg.get("role") != "assistant":
        continue
    content = msg.get("content")
    if isinstance(content, str):
        text.append(content)
    elif isinstance(content, list):
        text += [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
joined = "\n".join(text)
if marker not in joined:
    print(f"FEHLER Endmarke {marker} fehlt"); sys.exit(0)
if lines:
    found = [int(n) for n in re.findall(r"Zeile (\d+):", joined)]
    if found != list(range(1, lines + 1)):
        print(f"FEHLER Zeilen unvollständig ({len(found)} von {lines})"); sys.exit(0)
print("OK")
PYEOF
}

# Offene Rückfrage: letzter AskUserQuestion-Aufruf ohne Antwort?
check_question_open() {
    "$PY" -I - "$1" <<'PYEOF'
import sys, json
asked, answered = set(), set()
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        entry = json.loads(raw)
    except Exception:
        continue
    content = (entry.get("message") or {}).get("content")
    if not isinstance(content, list):
        continue
    for c in content:
        if not isinstance(c, dict):
            continue
        if c.get("type") == "tool_use" and c.get("name") == "AskUserQuestion":
            asked.add(c.get("id"))
        if c.get("type") == "tool_result":
            answered.add(c.get("tool_use_id"))
open_ids = asked - answered
print("OK" if open_ids else ("FEHLER keine Rückfrage gestellt" if not asked else "FEHLER Rückfrage beantwortet"))
PYEOF
}

# Identität eines Chat-Prozesses (aus seiner Umgebung) für `chats list` „aus dem Chat“.
chat_identity() {
    ps -E -ww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' \
        | grep -E '^WHISPERM8_SESSION_(ID|TOKEN)=' | tr '\n' ' ' || true
}

# MARK: - Test-Instanz vorbereiten

json_field() { "$PY" -I -c 'import json,sys; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }

prepare_instance() {
    [[ -x "$BIN" ]] || { echo "Kein Test-Bundle — erst: scripts/test-instance.sh build" >&2; exit 1; }
    mkdir -p "$STATE" "$PROJECT"
    [[ -d "$PROJECT/.git" ]] || git -C "$PROJECT" init -q
    : > "$COUNTER_FILE"
    # Codex in der Test-Instanz: nie ein Update-Dialog, den ein Enter bestätigt.
    mkdir -p "$ROOT/home/.codex"
    grep -q '^check_for_update_on_startup' "$ROOT/home/.codex/config.toml" 2>/dev/null \
        || echo 'check_for_update_on_startup = false' >> "$ROOT/home/.codex/config.toml"
    # Claude: Ordner der Test-Instanz als vertraut eintragen (eigene .claude.json der
    # Test-Instanz, nie die echte), sonst landet der Prompt im Trust-Dialog.
    "$PY" -I - "$ROOT/home/.claude.json" "$PROJECT" <<'PYEOF'
import json, os, sys
path, project = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    data = json.load(open(path))
data.setdefault("projects", {}).setdefault(project, {})["hasTrustDialogAccepted"] = True
tmp = path + ".soak-tmp"
json.dump(data, open(tmp, "w"), indent=2)
os.replace(tmp, path)
PYEOF
    # Die Test-Instanz hat nur eine Wurzel. Läuft sie schon (vielleicht für einen
    # anderen Chat), würde der Dauerlauf dessen Chats mit neu starten.
    if [[ -n "$("$TI" status | awk '/^PID:/ {print $2}')" ]]; then
        if (( USE_RUNNING )); then
            log "benutze die laufende Test-Instanz (--use-running)"
        else
            echo "Test-Instanz läuft schon (vielleicht für einen anderen Chat) — erst stoppen oder --use-running" >&2
            exit 1
        fi
    else
        ti start
    fi
}

new_chat() { # name provider prompt [extra…]
    local name="$1" provider="$2" prompt="$3"; shift 3
    local out ref args
    args=(--project "$PROJECT" --provider "$provider" --title "soak $name")
    [[ -n "$prompt" ]] && args+=(--prompt "$prompt")
    out=$(cli chats new "${args[@]}" "$@" --json)
    # {"ok": true, "result": {"session": {"id": "<uuid>", …}}}
    ref=$(printf '%s' "$out" | json_field '["result"]["session"]["id"]')
    printf '%s\t%s\t%s\n' "$name" "$ref" "$provider" >> "$STATE/chats.tsv"
    log "Chat $name angelegt: $ref"
}

setup_chats() {
    : > "$STATE/chats.tsv"
    new_chat bash claude "$PROMPT_BASH"
    new_chat stream claude "$PROMPT_STREAM"
    new_chat codex codex "$PROMPT_CODEX"
    new_chat question claude "$PROMPT_QUESTION"
    if has_terminal_tabs; then
        new_chat counter terminal "" --command "$COUNTER_COMMAND"
    else
        record setup counter FEHLT "Terminal-Tab per CLI (Paket 4: chats new --provider terminal)"
    fi
    if has_background_chats; then
        new_chat attached claude "$PROMPT_ATTACHED" --background
    else
        record setup attached FEHLT "Hintergrund-Chat per CLI (Paket 4: chats new --background)"
    fi
}

chat_ref() { awk -F'\t' -v n="$1" '$1 == n {print $2}' "$STATE/chats.tsv"; }

chat_show() { cli chats show "$(chat_ref "$1")" --json 2>/dev/null; }

external_id() { chat_show "$1" | json_field '.get("externalSessionID") or ""' 2>/dev/null || true; }

transcript_path() {
    local id
    id=$(external_id "$1")
    [[ -n "$id" ]] || return 0
    find "$ROOT/home/.claude/projects" "$ROOT/home/.codex/sessions" -name "*$id*.jsonl" 2>/dev/null | head -1
}

# PID eines Chats: Claude über die Registry, sonst runtime.pid (Paket 4).
chat_pid() {
    local id
    id=$(external_id "$1")
    if [[ -n "$id" ]]; then
        registry_pids "$ROOT/home/.claude/sessions" | awk -v s="$id" '$1 == s {print $2}'
    fi
    chat_show "$1" | json_field '.get("runtime", {}).get("pid") or ""' 2>/dev/null || true
}

# MARK: - Durchgang

snapshot() { # datei
    local name
    : > "$1"
    for name in $(cut -f1 "$STATE/chats.tsv"); do
        local path size
        path=$(transcript_path "$name")
        size=0
        [[ -n "$path" && -f "$path" ]] && size=$(stat -f %z "$path")
        printf '%s\t%s\t%s\n' "$name" "$(chat_pid "$name" | head -1)" "$size" >> "$1"
    done
}

restart_instance() {
    if has_keep_chats; then
        ti restart --keep-chats
    else
        record "$1" neustart FEHLT "restart --keep-chats (Paket 4); heutiger Weg: restart + Fortsetzen"
        ti restart
    fi
}

check_round() { # runde vorher-datei
    local round="$1" before="$2" name pid_before pid_now size path verdict
    while IFS=$'\t' read -r name pid_before size; do
        [[ "$name" == counter || "$name" == attached ]] && [[ -z "$pid_before" ]] && continue
        pid_now=$(chat_pid "$name" | head -1)
        if [[ -z "$pid_before" ]]; then
            record "$round" "pid:$name" FEHLT "PID nicht ermittelbar (Codex/Terminal: runtime.pid, Paket 4)"
        elif [[ "$pid_now" == "$pid_before" ]]; then
            record "$round" "pid:$name" OK "$pid_now"
        else
            record "$round" "pid:$name" FEHLER "vorher $pid_before, jetzt ${pid_now:-keiner}"
        fi
        path=$(transcript_path "$name")
        if [[ -n "$path" && -f "$path" ]]; then
            verdict=$(scan_transcript_errors "$path" "$size")
            record "$round" "fehler:$name" "${verdict%% *}" "${verdict#* }"
        fi
        if [[ -n "$pid_now" ]]; then
            local ident
            ident=$(chat_identity "$pid_now")
            if [[ -z "$ident" ]]; then
                record "$round" "chats-list:$name" FEHLER "keine Chat-Identität in der Umgebung von $pid_now"
            elif env $ident WHISPERM8_INSTANCE_ROOT="$ROOT" "$BIN" chats list --json >/dev/null 2>&1; then
                record "$round" "chats-list:$name" OK ""
            else
                record "$round" "chats-list:$name" FEHLER "chats list aus dem Chat gescheitert"
            fi
        fi
    done < "$before"

    local doubles
    doubles=$(registry_pids "$ROOT/home/.claude/sessions" | awk 'NF > 2')
    if [[ -n "$doubles" ]]; then record "$round" "ein-prozess-je-sitzung" FEHLER "$doubles"
    else record "$round" "ein-prozess-je-sitzung" OK ""; fi

    path=$(transcript_path question)
    if [[ -n "$path" ]]; then
        verdict=$(check_question_open "$path")
        record "$round" rueckfrage "${verdict%% *}" "${verdict#* }"
    fi

    if has_terminal_tabs; then
        verdict=$(check_counter_file "$COUNTER_FILE")
        record "$round" zaehler "${verdict%% *}" "${verdict#* }"
    fi

    if pgrep -f "handover-keeper --root $ROOT" >/dev/null 2>&1; then
        record "$round" aufbewahrer-weg FEHLER "läuft noch"
    elif has_keep_chats; then
        record "$round" aufbewahrer-weg OK ""
    fi
}

final_checks() {
    local path verdict name marker lines
    for spec in "bash SOAK-BASH-ENDE 0" "stream SOAK-STREAM-ENDE 400" "codex SOAK-CODEX-ENDE 0"; do
        read -r name marker lines <<< "$spec"
        path=$(transcript_path "$name")
        if [[ -z "$path" ]]; then record ende "vollstaendig:$name" FEHLER "kein Transcript"; continue; fi
        verdict=$(check_answer_complete "$path" "$marker" "$lines")
        record ende "vollstaendig:$name" "${verdict%% *}" "${verdict#* }"
    done
    if has_notification_log; then
        local since
        since=$(cat "$STATE/started-at")
        for name in bash stream codex; do
            local count id
            id=$(chat_show "$name" | json_field '["id"]' 2>/dev/null || true)
            count=$(log show --start "$since" --style compact \
                --predicate "processImagePath CONTAINS \"WhisperM8Test.app\" AND eventMessage CONTAINS \"session_notification_posted kind=turnCompleted session=$id\"" 2>/dev/null \
                | grep -c session_notification_posted || true)
            if (( count > 1 )); then record ende "fertig-meldung:$name" FEHLER "$count Meldungen"
            else record ende "fertig-meldung:$name" OK "$count"; fi
        done
    else
        record ende fertig-meldung FEHLT "Logzeile je Fertig-Meldung (Paket 4)"
    fi
}

wait_until_working() {
    local tries=0
    while (( tries < 60 )); do
        local path
        path=$(transcript_path bash)
        if [[ -n "$path" ]] && grep -q 'SOAK-STEP-2' "$path" 2>/dev/null; then return 0; fi
        sleep 2; tries=$((tries + 1))
    done
    log "Bash-Chat zeigt nach 2 min noch keine Schritte — weiter ohne Gewähr"
}

wait_for_answers() {
    local tries=0
    while (( tries < 180 )); do
        local done_all=1 name marker
        for spec in "bash SOAK-BASH-ENDE" "stream SOAK-STREAM-ENDE" "codex SOAK-CODEX-ENDE"; do
            read -r name marker <<< "$spec"
            local path
            path=$(transcript_path "$name")
            [[ -n "$path" ]] && grep -q "$marker" "$path" 2>/dev/null || done_all=0
        done
        (( done_all )) && return 0
        sleep 5; tries=$((tries + 1))
    done
}

cleanup_chats() {
    local ref
    for ref in $(cut -f2 "$STATE/chats.tsv" 2>/dev/null); do
        cli chats close "$ref" --stop --force >/dev/null 2>&1 || true
    done
}

report() {
    local fails missing
    fails=$(printf '%s' "$RESULTS" | awk -F'\t' '$3 == "FEHLER"' | wc -l | tr -d ' ')
    missing=$(printf '%s' "$RESULTS" | awk -F'\t' '$3 == "FEHLT"' | wc -l | tr -d ' ')
    {
        echo "# Dauerlauf Neustart ohne Chatverlust — $(date '+%d.%m.%Y %H:%M')"
        echo
        echo "Durchgänge: $ROUNDS · Fehler: $fails · fehlt: $missing · keep-chats: $(has_keep_chats && echo ja || echo nein)"
        echo
        echo "| Runde | Prüfung | Ergebnis | Detail |"
        echo "|---|---|---|---|"
        printf '%s' "$RESULTS" | awk -F'\t' 'NF >= 3 {printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}'
    } > "${REPORT:-$SOAK/report.md}"
    cat "${REPORT:-$SOAK/report.md}"
    if (( fails > 0 )); then return 1; fi
    if (( missing > 0 )); then return 2; fi
    return 0
}

cmd_run() {
    prepare_instance
    date '+%Y-%m-%d %H:%M:%S' > "$STATE/started-at"
    setup_chats
    wait_until_working
    local round
    for round in $(seq 1 "$ROUNDS"); do
        snapshot "$STATE/before-$round.tsv"
        log "Durchgang $round/$ROUNDS: Neustart"
        restart_instance "$round"
        sleep 3
        check_round "$round" "$STATE/before-$round.tsv"
        sleep 5
    done
    log "warte auf vollständige Antworten (höchstens 15 min)"
    wait_for_answers
    final_checks
    (( KEEP )) || cleanup_chats
    local status=0
    report || status=$?
    exit "$status"
}

# MARK: - Selbsttest der Prüf-Funktionen

cmd_self_test() {
    local dir failures=0
    dir=$(mktemp -d "${TMPDIR:-/tmp}/handover-soak-selftest.XXXXXX")
    expect() { # erwartet tatsächlich beschreibung
        if [[ "$2" == "$1"* ]]; then echo "ok    $3"; else echo "FAIL  $3: erwartet '$1', bekam '$2'"; failures=$((failures + 1)); fi
    }
    printf '1\n2\n3\n4\n' > "$dir/c1"; expect OK "$(check_counter_file "$dir/c1")" "Zähler lückenlos"
    printf '1\n2\n4\n' > "$dir/c2"; expect "FEHLER Sprung 2 -> 4" "$(check_counter_file "$dir/c2")" "Zähler mit Lücke"
    printf '7\n8\n1\n2\n' > "$dir/c3"; expect "FEHLER Sprung 8 -> 1" "$(check_counter_file "$dir/c3")" "Zähler neu gestartet"

    mkdir -p "$dir/sessions"
    echo "{\"pid\": $$, \"sessionId\": \"s1\"}" > "$dir/sessions/$$.json"
    echo '{"pid": 999999, "sessionId": "s1"}' > "$dir/sessions/999999.json"
    expect "s1 $$" "$(registry_pids "$dir/sessions")" "Registry: nur lebende PIDs"
    echo "{\"pid\": $PPID, \"sessionId\": \"s1\"}" > "$dir/sessions/$PPID.json"
    expect "s1" "$(registry_pids "$dir/sessions" | awk 'NF > 2 {print $1}')" "Registry: zweiter Prozess erkannt"

    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Zeile 1: a\nZeile 2: b\nENDE"}]}}' > "$dir/t1.jsonl"
    expect OK "$(check_answer_complete "$dir/t1.jsonl" ENDE 2)" "Antwort vollständig"
    expect "FEHLER Zeilen" "$(check_answer_complete "$dir/t1.jsonl" ENDE 3)" "Antwort unvollständig"
    expect "FEHLER Endmarke" "$(check_answer_complete "$dir/t1.jsonl" FEHLTNOCH 0)" "Endmarke fehlt"

    printf '%s\n' '{"message":{"role":"assistant","content":"x"},"isApiErrorMessage":true}' > "$dir/t2.jsonl"
    expect FEHLER "$(scan_transcript_errors "$dir/t2.jsonl" 0)" "API-Fehler gefunden"
    expect OK "$(scan_transcript_errors "$dir/t1.jsonl" 0)" "kein API-Fehler"
    expect OK "$(scan_transcript_errors "$dir/t2.jsonl" "$(stat -f %z "$dir/t2.jsonl")")" "nur ab Position gesucht"

    printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion"}]}}' > "$dir/t3.jsonl"
    expect OK "$(check_question_open "$dir/t3.jsonl")" "Rückfrage offen"
    printf '%s\n' '{"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1"}]}}' >> "$dir/t3.jsonl"
    expect "FEHLER Rückfrage beantwortet" "$(check_question_open "$dir/t3.jsonl")" "Rückfrage beantwortet"

    rm -rf "$dir"
    if (( failures == 0 )); then echo "self-test: alles ok"; else echo "self-test: $failures Fehler"; return 1; fi
}

# MARK: - Aufruf

main() {
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rounds) ROUNDS="${2:?--rounds braucht eine Zahl}"; shift 2 ;;
            --keep) KEEP=1; shift ;;
            --report) REPORT="${2:?--report braucht einen Pfad}"; shift 2 ;;
            --use-running) USE_RUNNING=1; shift ;;
            *) echo "unbekanntes Argument: $1" >&2; exit 64 ;;
        esac
    done
    [[ "$ROUNDS" =~ ^[0-9]+$ ]] && (( ROUNDS >= 1 )) || { echo "--rounds braucht eine Zahl ≥ 1" >&2; exit 64; }
    case "$cmd" in
        capabilities) cmd_capabilities ;;
        run) cmd_run ;;
        self-test) cmd_self_test ;;
        *) sed -n '2,8p' "$0"; exit 64 ;;
    esac
}

main "$@"
