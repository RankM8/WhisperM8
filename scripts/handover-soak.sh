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
# Prüfungen je Durchgang: gleiche PIDs; kein „API Error“/„Retrying“; Rückfrage
# offen; Zähler lückenlos; kein zweiter Prozess je Sitzung; `chats list` und ein
# mutierender Aufruf aus jedem Chat (Token übersteht die Übergabe); Aufbewahrer
# weg. Am Ende: Antworten vollständig, genau eine Fertig-Meldung je Chat.
#
# Ergebnis je Prüfung: OK, FEHLER oder FEHLT (Startbefehl/Messpunkt aus Paket 4
# noch nicht da — dann wird ehrlich nicht geprüft). Exit: 0 alles OK, 1 mindestens
# ein FEHLER, 2 kein FEHLER, aber etwas FEHLT, 64 Aufruf.
# Vor Paket 4 gilt der heutige Weg (Neustart beendet die Chats): Der Neustart
# steht dann als FEHLT, die Prüfungen danach (PIDs, Rückfrage …) als FEHLER —
# Exit 1 ist dann der ehrliche Befund, kein Fehler des Skripts.
#
# Sicherheit: Alle App-Befehle laufen über scripts/test-instance.sh (eigene Wurzel,
# eigene Bundle-ID); die Wurzel muss ein absoluter Pfad sein, sonst ignoriert die
# App sie und spräche die Produktiv-Instanz an. Nie `make dev|kill|run|install`,
# nie die Produktiv-App, nie `claude --bg/attach/stop` an echten Sitzungen.
# Codex-Update-Prüfung wird in der Test-Instanz abgeschaltet, damit kein Enter
# einen Update-Dialog bestätigt.
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
RUN_STARTED=0

# Prompts: Die Endmarke steht zerlegt im Prompt („SOAK-BASH“ + „-ENDE“), damit
# sie im Transcript erst mit der Antwort vorkommt. Geprüft wird ohnehin nur
# Assistant-Text.
PROMPT_BASH='Führe bitte nacheinander 40 Bash-Befehle einzeln aus, jeweils `echo SOAK-STEP-<n>; sleep 3` mit n von 1 bis 40. Keine Zusammenfassung dazwischen. Schreibe am Ende genau das Wort SOAK-BASH, direkt gefolgt von -ENDE.'
PROMPT_STREAM='Schreibe ohne Werkzeuge 400 nummerierte Zeilen im Format „Zeile <n>: <kurzer Satz>“ und zum Schluss genau das Wort SOAK-STREAM, direkt gefolgt von -ENDE.'
PROMPT_CODEX='Führe nacheinander 30 Shell-Befehle einzeln aus: `echo SOAK-CODEX-<n>; sleep 3` mit n von 1 bis 30. Schreibe am Ende genau das Wort SOAK-CODEX, direkt gefolgt von -ENDE.'
PROMPT_QUESTION='Stell mir mit dem Werkzeug AskUserQuestion genau eine Frage: „Welche Farbe soll der Test haben?“ mit den Optionen Rot und Blau. Warte dann auf meine Antwort und tu sonst nichts.'
PROMPT_ATTACHED='Führe nacheinander 30 Bash-Befehle einzeln aus: `echo SOAK-BG-<n>; sleep 4`. Schreibe am Ende genau das Wort SOAK-BG, direkt gefolgt von -ENDE.'
COUNTER_COMMAND="i=0; while :; do i=\$((i+1)); echo \$i >> '$COUNTER_FILE'; echo \"zähler \$i\"; sleep 1; done"

# Chats, deren Antwort am Ende vollständig sein muss: name endmarke zeilen
ANSWERS="bash SOAK-BASH-ENDE 0
stream SOAK-STREAM-ENDE 400
codex SOAK-CODEX-ENDE 0"

# Nach jedem Start oder Neustart das Grid wieder öffnen (solange Chats nur
# über die Anzeige starten), sonst starten fortgesetzte Chats nicht.
ti() {
    local rc=0
    "$TI" "$@" || rc=$?
    if (( rc == 0 )) && [[ "${1:-}" == start || "${1:-}" == restart ]]; then reopen_grid; fi
    return "$rc"
}
reopen_grid() {
    [[ -f "${STATE:-/nonexistent}/grid-name" ]] || return 0
    local name
    name=$(cat "$STATE/grid-name")
    cli chats workspace open "$name" --json >/dev/null 2>&1 \
        || record grid wieder-offen FEHLER "Grid „$name“ nach dem Neustart nicht geöffnet"
}
cli() { "$TI" cli "$@"; }
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# MARK: - Ergebnisse

RESULTS=""   # Zeilen: runde<TAB>prüfung<TAB>OK|FEHLER|FEHLT<TAB>detail
record() {
    RESULTS="${RESULTS}$1	$2	$3	$4
"
    log "[$1] $2: $3 ${4:+— $4}"
}

# Ergebnis einer Prüf-Funktion („OK …“ / „FEHLER …“) eintragen.
record_verdict() { # runde prüfung befund
    local status="${3%% *}" detail=""
    [[ "$3" == *" "* ]] && detail="${3#* }"
    record "$1" "$2" "$status" "$detail"
}

# MARK: - Fähigkeiten (Paket 4)

# Ausgaben erst einsammeln, dann suchen: `… | grep -q` unter pipefail scheitert,
# sobald grep früh aufhört und der Schreiber SIGPIPE bekommt.
contains() { grep -qE -- "$2" <<< "$1"; }
has_keep_chats() { grep -q -- '--keep-chats' "$TI"; }
# Chat ohne Anzeige starten (Paket 4). Heute startet ein Chat erst, wenn sein
# Tab angezeigt wird — in der versteckten Test-Instanz also nie (Lauf 13.11.).
has_chat_start() { contains "$(cli chats help 2>/dev/null || true)" '--start([^-a-z]|$)'; }
has_terminal_tabs() { contains "$(cli chats help 2>/dev/null || true)" '--provider [^ ]*terminal'; }
has_background_chats() { contains "$(cli chats help 2>/dev/null || true)" '--background'; }
has_terminal_text() { contains "$(cli debug help 2>/dev/null || true)" '^  terminal'; }
# Nur echter Code, kein Kommentar, der den Namen erwähnt.
has_notification_log() {
    local hits
    hits=$(grep -rh 'session_notification_posted' "$REPO/WhisperM8" 2>/dev/null | grep -v '^[[:space:]]*//' || true)
    [[ -n "$hits" ]]
}

cmd_capabilities() {
    local name check
    if [[ ! -x "$BIN" ]]; then
        echo "unbekannt: kein Test-Bundle ($BIN) — erst scripts/test-instance.sh build" >&2
    fi
    for name in chat_start keep_chats terminal_tabs background_chats terminal_text notification_log; do
        check="has_$name"
        if "$check"; then echo "da     $name"; else echo "fehlt  $name"; fi
    done
}

# MARK: - Reine Prüf-Funktionen (testbar per self-test)

# Zahlenfolge (eine Zahl je Zeile) lückenlos und ohne Neubeginn?
check_counter_file() {
    "$PY" -I - "$1" <<'PYEOF'
import sys
nums = []
try:
    for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.isdigit():
            nums.append(int(line))
except FileNotFoundError:
    pass
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
result = {}
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        data = json.load(open(path))
    except Exception:
        continue
    sid = data.get("sessionId") or data.get("session_id")
    try:
        pid = int(data.get("pid") or os.path.basename(path).split(".")[0])
        os.kill(pid, 0)
    except Exception:
        continue
    if sid:
        result.setdefault(sid, []).append(pid)
for sid, pids in sorted(result.items()):
    print(sid, *sorted(pids))
PYEOF
}

# Transcript (Claude-JSONL oder Codex-Rollout) zu einer externen Sitzungs-ID.
# Fehlende Suchordner sind kein Fehler: dann eben kein Treffer.
find_transcript() { # home id
    local dirs=() dir
    for dir in "$1/.claude/projects" "$1/.codex/sessions"; do
        [[ -d "$dir" ]] && dirs+=("$dir")
    done
    [[ ${#dirs[@]} -gt 0 && -n "$2" ]] || return 0
    find "${dirs[@]}" -name "*$2*.jsonl" 2>/dev/null | head -1 || true
}

# Transcript auf API-Fehler durchsuchen, ab Byte-Position. „Retrying“ zeigt
# Claude nur im Terminal, nicht im JSONL — das prüft check_round über den
# Terminaltext (Paket 4). Mit drittem Argument schreibt die Suche den Stand,
# bis zu dem sie gelesen hat, in diese Datei (nächste Runde liest ab dort).
scan_transcript_errors() {
    "$PY" -I - "$1" "${2:-0}" "${3:-}" <<'PYEOF'
import sys
path, start, offset_out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
hits = []
with open(path, "rb") as f:
    f.seek(start)
    for raw in f:
        line = raw.decode("utf-8", "replace")
        if '"isApiErrorMessage":true' in line.replace(" ", "") or "API Error" in line:
            hits.append(line[:120].strip())
    end = f.tell()
if offset_out:
    with open(offset_out, "w") as out:
        out.write(str(end))
print("FEHLER " + " | ".join(hits[:3]) if hits else "OK")
PYEOF
}

# Endmarke und (optional) lückenlose „Zeile n:“-Folge im Assistant-Text —
# Claude-Format (message.role) und Codex-Rollout (payload.role, output_text).
check_answer_complete() {
    "$PY" -I - "$1" "$2" "${3:-0}" <<'PYEOF'
import sys, re, json
path, marker, lines = sys.argv[1], sys.argv[2], int(sys.argv[3])
text = []
def collect(content):
    if isinstance(content, str):
        text.append(content)
    elif isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get("type") in ("text", "output_text"):
                text.append(c.get("text", ""))
for raw in open(path, encoding="utf-8", errors="replace"):
    try:
        entry = json.loads(raw)
    except Exception:
        continue
    for msg in (entry.get("message"), entry.get("payload")):
        if isinstance(msg, dict) and msg.get("role") == "assistant":
            collect(msg.get("content"))
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

# Offene Rückfrage: ein AskUserQuestion-Aufruf ohne Antwort?
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

# Identität eines Chat-Prozesses (aus seiner Umgebung).
chat_identity() {
    ps -E -ww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' \
        | grep -E '^WHISPERM8_SESSION_(ID|TOKEN)=' | tr '\n' ' ' || true
}

json_field() { "$PY" -I -c 'import json,sys; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }

# MARK: - Test-Instanz vorbereiten

prepare_instance() {
    [[ -x "$BIN" ]] || { echo "Kein Test-Bundle — erst: scripts/test-instance.sh build" >&2; exit 1; }
    # Zuerst: Läuft die Test-Instanz schon (vielleicht für einen anderen Chat),
    # nichts anfassen — der Dauerlauf würde deren Chats mit neu starten.
    local running
    running=$("$TI" status | awk '/^PID:/ {print $2}')
    if [[ -n "$running" ]] && (( ! USE_RUNNING )); then
        echo "Test-Instanz läuft schon (PID $running, vielleicht für einen anderen Chat) — erst stoppen oder --use-running" >&2
        exit 1
    fi
    mkdir -p "$STATE" "$PROJECT"
    rm -f "$STATE/grid-name"   # Grid eines früheren Laufs gilt nicht mehr
    [[ -d "$PROJECT/.git" ]] || git -C "$PROJECT" init -q
    : > "$COUNTER_FILE"
    # Codex in der Test-Instanz: nie ein Update-Dialog, den ein Enter bestätigt.
    mkdir -p "$ROOT/home/.codex"
    grep -q '^check_for_update_on_startup' "$ROOT/home/.codex/config.toml" 2>/dev/null \
        || echo 'check_for_update_on_startup = false' >> "$ROOT/home/.codex/config.toml"
    # Claude: Ordner als vertraut eintragen — in der .claude.json der Test-Instanz
    # ($ROOT/home), nie in der echten. Sonst landet der Prompt im Trust-Dialog.
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
    if [[ -n "$running" ]]; then
        log "benutze die laufende Test-Instanz (--use-running)"
    else
        # Bis Paket 4 Chats ohne Anzeige starten kann: sichtbar starten, damit
        # die Panes im Grid angezeigt werden und ihre Chats starten (show_in_grid).
        # Gilt auch für jeden Neustart in diesem Lauf (exportiert).
        has_chat_start || export WHISPERM8_TEST_VISIBLE=1
        ti start
    fi
}

# Bis Paket 4 `--start` anbietet, startet ein Chat erst, wenn sein Pane oder
# Tab angezeigt wird (Lauf vom 13.11.: versteckte Instanz, kein Chat gestartet).
# Deshalb alle Chats in einen eigenen Grid-Workspace legen und ihn öffnen.
show_in_grid() {
    local name refs=() out
    for name in $(chat_names); do refs+=("$(chat_ref "$name")"); done
    name="soak $(date +%H%M%S)"
    if ! out=$(cli chats workspace create "$name" "${refs[@]}" --json 2>&1); then
        record setup grid FEHLER "Grid-Workspace nicht angelegt: $(printf '%s' "$out" | tail -1)"
        return 1
    fi
    if ! out=$(cli chats workspace open "$name" --json 2>&1); then
        record setup grid FEHLER "Grid-Workspace nicht geöffnet: $(printf '%s' "$out" | tail -1)"
        return 1
    fi
    printf '%s' "$name" > "$STATE/grid-name"
    record setup grid OK "${#refs[@]} Chats im Grid „$name“ geöffnet (bis Paket 4 --start bietet)"
    if (( USE_RUNNING )); then
        record setup grid-sichtbar FEHLT "laufende Instanz (--use-running): ob sie sichtbar läuft, ist unbekannt; versteckt starten die Chats nicht"
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
    printf '%s\t0\n' "$name" >> "$STATE/offsets.tsv"
    log "Chat $name angelegt: $ref"
}

setup_chats() {
    : > "$STATE/chats.tsv"
    : > "$STATE/offsets.tsv"
    local start=() grid=0
    rm -f "$STATE/grid-name"
    if has_chat_start; then
        start=(--start)
    else
        grid=1
        record setup chat-start FEHLT "Chat ohne Anzeige starten (Paket 4: chats new --start); bis dahin über das Grid"
    fi
    new_chat bash claude "$PROMPT_BASH" ${start[@]+"${start[@]}"}
    new_chat stream claude "$PROMPT_STREAM" ${start[@]+"${start[@]}"}
    new_chat codex codex "$PROMPT_CODEX" ${start[@]+"${start[@]}"}
    new_chat question claude "$PROMPT_QUESTION" ${start[@]+"${start[@]}"}
    if has_terminal_tabs; then
        new_chat counter terminal "" --command "$COUNTER_COMMAND" ${start[@]+"${start[@]}"}
    else
        record setup counter FEHLT "Terminal-Tab per CLI (Paket 4: chats new --provider terminal)"
    fi
    if has_background_chats; then
        new_chat attached claude "$PROMPT_ATTACHED" --background ${start[@]+"${start[@]}"}
        ANSWERS="$ANSWERS
attached SOAK-BG-ENDE 0"
    else
        record setup attached FEHLT "Hintergrund-Chat per CLI (Paket 4: chats new --background)"
    fi
    if (( grid )); then show_in_grid || true; fi
}

chat_names() { cut -f1 "$STATE/chats.tsv"; }
chat_ref() { awk -F'\t' -v n="$1" '$1 == n {print $2}' "$STATE/chats.tsv"; }
chat_provider() { awk -F'\t' -v n="$1" '$1 == n {print $3}' "$STATE/chats.tsv"; }
chat_show() { cli chats show "$(chat_ref "$1")" --json 2>/dev/null || true; }
external_id() { chat_show "$1" | json_field '.get("externalSessionID") or ""' 2>/dev/null || true; }
transcript_path() { find_transcript "$ROOT/home" "$(external_id "$1")"; }
offset_of() { awk -F'\t' -v n="$1" '$1 == n {print $2}' "$STATE/offsets.tsv"; }
set_offset() {
    awk -F'\t' -v n="$1" -v o="$2" 'BEGIN {OFS="\t"} $1 == n {$2 = o} {print}' "$STATE/offsets.tsv" > "$STATE/offsets.tmp"
    mv "$STATE/offsets.tmp" "$STATE/offsets.tsv"
}

# PID eines Chats: Claude über die Registry, sonst runtime.pid (Paket 4).
chat_pid() {
    local id pid
    id=$(external_id "$1")
    if [[ -n "$id" ]]; then
        pid=$(registry_pids "$ROOT/home/.claude/sessions" | awk -v s="$id" '$1 == s {print $2}')
        [[ -n "$pid" ]] && { echo "$pid"; return 0; }
    fi
    chat_show "$1" | json_field '.get("runtime", {}).get("pid") or ""' 2>/dev/null || true
}

# MARK: - Durchgang

snapshot() { # datei
    local name
    : > "$1"
    for name in $(chat_names); do
        printf '%s\t%s\n' "$name" "$(chat_pid "$name")" >> "$1"
    done
}

restart_instance() { # runde
    if has_keep_chats; then
        ti restart --keep-chats
    else
        record "$1" neustart FEHLT "restart --keep-chats (Paket 4); heutiger Weg: restart, Chats enden"
        ti restart
    fi
}

# Aus dem Chat heraus: `chats list` plus ein harmloser mutierender Aufruf
# (Pin setzen und wieder entfernen). Nur der mutierende Aufruf prüft das
# Control-Token; `chats list` liest notfalls von der Platte.
check_chat_identity() { # runde name pid
    local ident ref
    ident=$(chat_identity "$3")
    ref=$(chat_ref "$2")
    if [[ -z "$ident" ]]; then
        record "$1" "token:$2" FEHLER "keine Chat-Identität in der Umgebung von PID $3"
        return 0
    fi
    # Wurzel ausdrücklich setzen: ohne sie spräche das Binary die Produktiv-App an.
    if ! env $ident WHISPERM8_INSTANCE_ROOT="$ROOT" "$BIN" chats list --json >/dev/null 2>&1; then
        record "$1" "token:$2" FEHLER "chats list aus dem Chat gescheitert"
    elif env $ident WHISPERM8_INSTANCE_ROOT="$ROOT" "$BIN" chats pin "$ref" >/dev/null 2>&1 \
        && env $ident WHISPERM8_INSTANCE_ROOT="$ROOT" "$BIN" chats unpin "$ref" >/dev/null 2>&1; then
        record "$1" "token:$2" OK ""
    else
        record "$1" "token:$2" FEHLER "mutierender Aufruf mit dem Token des Chats abgelehnt"
    fi
}

check_round() { # runde vorher-datei
    local round="$1" before="$2" name pid_before pid_now path verdict size
    while IFS=$'\t' read -r name pid_before; do
        pid_now=$(chat_pid "$name")
        if [[ -z "$pid_before" ]]; then
            record "$round" "pid:$name" FEHLT "PID vor dem Neustart nicht ermittelbar (Codex/Terminal: runtime.pid, Paket 4)"
        elif [[ "$pid_now" == "$pid_before" ]]; then
            record "$round" "pid:$name" OK "$pid_now"
        else
            record "$round" "pid:$name" FEHLER "vorher $pid_before, jetzt ${pid_now:-keiner}"
        fi

        # Terminal-Tabs haben weder Transcript noch API.
        if [[ "$(chat_provider "$name")" != terminal ]]; then
            path=$(transcript_path "$name")
            if [[ -z "$path" || ! -f "$path" ]]; then
                record "$round" "api-fehler:$name" FEHLER "kein Transcript gefunden"
            else
                # Ab dem Stand der letzten Prüfung; die Suche nennt selbst, bis
                # wohin sie gelesen hat. Am Ende prüft final_checks alles ab 0.
                verdict=$(scan_transcript_errors "$path" "$(offset_of "$name")" "$STATE/offset.tmp")
                record_verdict "$round" "api-fehler:$name" "$verdict"
                set_offset "$name" "$(cat "$STATE/offset.tmp")"
            fi

            if has_terminal_text; then
                local screen
                screen=$(cli debug terminal "$(chat_ref "$name")" --text 2>/dev/null || true)
                if contains "$screen" 'Retrying|API Error'; then
                    record "$round" "retrying:$name" FEHLER "im Terminal sichtbar"
                elif [[ -z "$screen" ]]; then
                    record "$round" "retrying:$name" FEHLER "Terminaltext nicht lesbar"
                else
                    record "$round" "retrying:$name" OK ""
                fi
            else
                record "$round" "retrying:$name" FEHLT "„Retrying“ steht nur im Terminal (Paket 4: debug terminal --text)"
            fi
        fi

        if [[ -n "$pid_now" ]]; then
            check_chat_identity "$round" "$name" "$pid_now"
        elif [[ -z "$pid_before" ]]; then
            record "$round" "token:$name" FEHLT "ohne PID keine Chat-Identität"
        else
            record "$round" "token:$name" FEHLER "Prozess nach dem Neustart weg"
        fi
    done < "$before"

    local registry doubles
    registry=$(registry_pids "$ROOT/home/.claude/sessions")
    doubles=$(printf '%s\n' "$registry" | awk 'NF > 2')
    if [[ -z "$registry" ]]; then
        record "$round" "ein-prozess-je-sitzung" FEHLER "kein lebender Claude-Prozess in der Registry"
    elif [[ -n "$doubles" ]]; then
        record "$round" "ein-prozess-je-sitzung" FEHLER "$doubles"
    else
        record "$round" "ein-prozess-je-sitzung" OK "$(printf '%s\n' "$registry" | wc -l | tr -d ' ') Sitzungen"
    fi

    path=$(transcript_path question)
    if [[ -z "$path" ]]; then
        record "$round" rueckfrage FEHLER "kein Transcript des Rückfrage-Chats"
    else
        record_verdict "$round" rueckfrage "$(check_question_open "$path")"
    fi

    if has_terminal_tabs; then
        record_verdict "$round" zaehler "$(check_counter_file "$COUNTER_FILE")"
    fi

    if pgrep -f "handover-keeper --root $ROOT" >/dev/null 2>&1; then
        record "$round" aufbewahrer-weg FEHLER "läuft noch"
    elif has_keep_chats; then
        record "$round" aufbewahrer-weg OK ""
    else
        record "$round" aufbewahrer-weg FEHLT "ohne Übergabe gibt es keinen Aufbewahrer"
    fi
}

final_checks() {
    local path name marker lines
    while read -r name marker lines; do
        [[ -n "$name" ]] || continue
        path=$(transcript_path "$name")
        if [[ -z "$path" ]]; then record ende "vollstaendig:$name" FEHLER "kein Transcript"; continue; fi
        record_verdict ende "vollstaendig:$name" "$(check_answer_complete "$path" "$marker" "$lines")"
        record_verdict ende "api-fehler-gesamt:$name" "$(scan_transcript_errors "$path" 0)"
    done <<< "$ANSWERS"
    path=$(transcript_path question)
    [[ -n "$path" ]] && record_verdict ende "api-fehler-gesamt:question" "$(scan_transcript_errors "$path" 0)"

    if has_notification_log; then
        local since id count
        since=$(cat "$STATE/started-at")
        while read -r name marker lines; do
            [[ -n "$name" ]] || continue
            id=$(chat_show "$name" | json_field '["id"]' 2>/dev/null || true)
            if [[ -z "$id" ]]; then record ende "fertig-meldung:$name" FEHLER "Chat-ID nicht ermittelbar"; continue; fi
            count=$(log show --start "$since" --style compact \
                --predicate "processImagePath CONTAINS \"WhisperM8Test.app\" AND eventMessage CONTAINS \"session_notification_posted kind=turnCompleted session=$id\"" 2>/dev/null \
                | grep -c session_notification_posted || true)
            if [[ "$count" == 1 ]]; then record ende "fertig-meldung:$name" OK "1"
            else record ende "fertig-meldung:$name" FEHLER "$count Meldungen statt genau einer"; fi
        done <<< "$ANSWERS"
    else
        record ende fertig-meldung FEHLT "Logzeile je Fertig-Meldung (Paket 4)"
    fi
}

wait_until_working() {
    local tries=0 path
    while (( tries < 60 )); do
        path=$(transcript_path bash)
        if [[ -n "$path" ]] && grep -q 'SOAK-STEP-2' "$path" 2>/dev/null; then return 0; fi
        sleep 2; tries=$((tries + 1))
    done
    record setup arbeitet FEHLER "Bash-Chat zeigt nach 2 min keine Schritte"
}

# Bis höchstens 15 min, bis alle Antworten im Assistant-Text vollständig sind.
wait_for_answers() {
    local tries=0 name marker lines path all
    while (( tries < 180 )); do
        all=1
        while read -r name marker lines; do
            [[ -n "$name" ]] || continue
            path=$(transcript_path "$name")
            if [[ -z "$path" ]] || [[ "$(check_answer_complete "$path" "$marker" "$lines")" != OK ]]; then all=0; fi
        done <<< "$ANSWERS"
        (( all )) && return 0
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
    local fails missing file="${REPORT:-$SOAK/report.md}"
    fails=$(printf '%s' "$RESULTS" | awk -F'\t' '$3 == "FEHLER"' | wc -l | tr -d ' ')
    missing=$(printf '%s' "$RESULTS" | awk -F'\t' '$3 == "FEHLT"' | wc -l | tr -d ' ')
    mkdir -p "$(dirname "$file")"
    {
        echo "# Dauerlauf Neustart ohne Chatverlust — $(date '+%d.%m.%Y %H:%M')"
        echo
        echo "Durchgänge: $ROUNDS · Fehler: $fails · fehlt: $missing · keep-chats: $(has_keep_chats && echo ja || echo nein)"
        echo
        echo "| Runde | Prüfung | Ergebnis | Detail |"
        echo "|---|---|---|---|"
        printf '%s' "$RESULTS" | awk -F'\t' 'NF >= 3 {printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}'
    } > "$file"
    cat "$file"
    if (( fails > 0 )); then return 1; fi
    if (( missing > 0 )); then return 2; fi
    return 0
}

# Bricht der Lauf ab (gescheiterter Neustart, `chats new` …): trotzdem Chats
# beenden und einen Bericht schreiben, statt Chats laufen zu lassen.
on_exit() { # [exit-status] — ohne Argument der Status beim Aufruf als Trap
    local status=${1:-$?}
    (( RUN_STARTED )) || return 0
    RUN_STARTED=0
    if (( status != 0 )); then
        record abbruch skript FEHLER "Lauf abgebrochen (Exit $status)"
        (( KEEP )) || cleanup_chats
        report || true
    fi
}

cmd_run() {
    prepare_instance
    RUN_STARTED=1
    trap on_exit EXIT
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
    if has_keep_chats; then
        log "warte auf vollständige Antworten (höchstens 15 min)"
        wait_for_answers
    else
        # Ohne Übergabe enden die Chats beim Neustart; warten bringt nichts.
        log "ohne --keep-chats: kein Warten auf Antworten"
    fi
    final_checks
    (( KEEP )) || cleanup_chats
    RUN_STARTED=0
    local status=0
    report || status=$?
    exit "$status"
}

# MARK: - Selbsttest der Prüf-Funktionen

cmd_self_test() {
    local dir failures=0
    dir=$(mktemp -d "${TMPDIR:-/tmp}/handover-soak-selftest.XXXXXX")
    expect() { # erwartet-präfix tatsächlich beschreibung
        if [[ "$2" == "$1"* ]]; then echo "ok    $3"; else echo "FAIL  $3: erwartet '$1…', bekam '$2'"; failures=$((failures + 1)); fi
    }
    expect_exact() { # erwartet tatsächlich beschreibung
        if [[ "$2" == "$1" ]]; then echo "ok    $3"; else echo "FAIL  $3: erwartet '$1', bekam '$2'"; failures=$((failures + 1)); fi
    }
    printf '1\n2\n3\n4\n' > "$dir/c1"; expect_exact "OK 1..4" "$(check_counter_file "$dir/c1")" "Zähler lückenlos"
    printf '1\n2\n4\n' > "$dir/c2"; expect_exact "FEHLER Sprung 2 -> 4" "$(check_counter_file "$dir/c2")" "Zähler mit Lücke"
    printf '7\n8\n1\n2\n' > "$dir/c3"; expect_exact "FEHLER Sprung 8 -> 1" "$(check_counter_file "$dir/c3")" "Zähler neu gestartet"
    expect_exact "FEHLER leer" "$(check_counter_file "$dir/fehlt")" "Zähler-Datei fehlt"

    mkdir -p "$dir/sessions"
    echo "{\"pid\": $$, \"sessionId\": \"s1\"}" > "$dir/sessions/$$.json"
    echo '{"pid": 999999, "sessionId": "s1"}' > "$dir/sessions/999999.json"
    expect_exact "s1 $$" "$(registry_pids "$dir/sessions")" "Registry: nur lebende PIDs"
    echo "{\"pid\": $PPID, \"sessionId\": \"s1\"}" > "$dir/sessions/$PPID.json"
    expect_exact "s1" "$(registry_pids "$dir/sessions" | awk 'NF > 2 {print $1}')" "Registry: zweiter Prozess erkannt"
    expect_exact "" "$(registry_pids "$dir/keine-registry")" "Registry fehlt: leer, kein Abbruch"

    mkdir -p "$dir/home/.claude/projects/p"
    : > "$dir/home/.claude/projects/p/abc-123.jsonl"
    expect_exact "$dir/home/.claude/projects/p/abc-123.jsonl" "$(find_transcript "$dir/home" abc-123)" "Transcript ohne Codex-Ordner gefunden"
    expect_exact "" "$(find_transcript "$dir/leer" abc-123)" "Suchordner fehlen: kein Abbruch"
    expect_exact "" "$(find_transcript "$dir/home" "")" "leere ID: kein Treffer"

    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Zeile 1: a\nZeile 2: b\nENDE"}]}}' > "$dir/t1.jsonl"
    expect_exact OK "$(check_answer_complete "$dir/t1.jsonl" ENDE 2)" "Antwort vollständig"
    expect "FEHLER Zeilen" "$(check_answer_complete "$dir/t1.jsonl" ENDE 3)" "Antwort unvollständig"
    expect "FEHLER Endmarke" "$(check_answer_complete "$dir/t1.jsonl" FEHLTNOCH 0)" "Endmarke fehlt"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"schreibe am Ende ENDE"}}' > "$dir/t4.jsonl"
    expect "FEHLER Endmarke" "$(check_answer_complete "$dir/t4.jsonl" ENDE 0)" "Endmarke nur im Prompt zählt nicht"
    printf '%s\n' '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fertig SOAK-CODEX-ENDE"}]}}' > "$dir/t5.jsonl"
    expect_exact OK "$(check_answer_complete "$dir/t5.jsonl" SOAK-CODEX-ENDE 0)" "Codex-Rollout erkannt"

    printf '%s\n' '{"message":{"role":"assistant","content":"x"},"isApiErrorMessage":true}' > "$dir/t2.jsonl"
    expect FEHLER "$(scan_transcript_errors "$dir/t2.jsonl" 0)" "API-Fehler gefunden"
    expect_exact OK "$(scan_transcript_errors "$dir/t1.jsonl" 0)" "kein API-Fehler"
    expect_exact OK "$(scan_transcript_errors "$dir/t2.jsonl" "$(stat -f %z "$dir/t2.jsonl")")" "nur ab Position gesucht"
    scan_transcript_errors "$dir/t2.jsonl" 0 "$dir/offset" >/dev/null
    expect_exact "$(stat -f %z "$dir/t2.jsonl")" "$(cat "$dir/offset")" "Suche nennt ihren Endstand"
    expect_exact "ja" "$(contains "$(printf 'a\n  terminal x\n')" '^  terminal' && echo ja || echo nein)" "contains ohne Pipe"

    printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion"}]}}' > "$dir/t3.jsonl"
    expect_exact OK "$(check_question_open "$dir/t3.jsonl")" "Rückfrage offen"
    printf '%s\n' '{"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1"}]}}' >> "$dir/t3.jsonl"
    expect_exact "FEHLER Rückfrage beantwortet" "$(check_question_open "$dir/t3.jsonl")" "Rückfrage beantwortet"
    expect_exact "FEHLER keine Rückfrage gestellt" "$(check_question_open "$dir/t1.jsonl")" "keine Rückfrage"

    RESULTS=""
    record_verdict 1 probe "OK" 2>/dev/null
    record_verdict 1 probe2 "FEHLER Sprung 2 -> 4" 2>/dev/null
    expect_exact "OK|;FEHLER|Sprung 2 -> 4" \
        "$(printf '%s' "$RESULTS" | awk -F'\t' '{printf "%s%s|%s", (NR > 1 ? ";" : ""), $3, $4}')" \
        "Befund ohne Detail sauber eingetragen"

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
    # Die App nimmt nur absolute Wurzeln an; sonst spräche alles die Produktiv-App an.
    [[ "$ROOT" == /* ]] || { echo "WHISPERM8_TEST_ROOT muss ein absoluter Pfad sein: $ROOT" >&2; exit 64; }
    case "$cmd" in
        capabilities) cmd_capabilities ;;
        run) cmd_run ;;
        self-test) cmd_self_test ;;
        *) sed -n '2,9p' "$0"; exit 64 ;;
    esac
}

# Als Bibliothek ladbar (scripts/handover-soak-faults.sh), dann ohne main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
