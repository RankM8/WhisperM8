#!/usr/bin/env bash
# Fehler-Szenarien für „Neustart ohne Chatverlust“ — Abnahme der Rückfall-Wege.
# Nur gegen die Test-Instanz; nutzt die Prüf-Funktionen aus handover-soak.sh.
# Unter zsh oder sh liefe beim Einbinden sonst der Dauerlauf statt der Szenarien.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
# Hintergrund: docs/plans/neustart-zweite-meinung.md (Risiko 3: die Rückfall-
# Wege sind die am wenigsten geübten und die gefährlichsten).
#
#   scripts/handover-soak-faults.sh capabilities              # was Paket 4 dafür schon liefert
#   scripts/handover-soak-faults.sh run [--only <szenario>]   # Szenarien fahren, Bericht
#            [--signing dev|adhoc] [--keep] [--report <datei>] [--use-running]
#   scripts/handover-soak-faults.sh self-test                 # Prüf-Funktionen ohne App
#
# Szenarien:
#   kill-mid-take    Aufbewahrer per SIGKILL mitten in der Übernahme
#   hold-deadline    keine neue App bis zur Haltefrist, danach Start
#   secret-missing   neue App findet kein Geheimnis
#   secret-wrong     neue App hat ein falsches Geheimnis
#   binary-swap      Programm unter dem laufenden Aufbewahrer ersetzt (wie make dev)
#   double-restart   zweiter Neustart, während die Übernahme des ersten noch läuft
#
# Prüfung jeweils:
#   - nie zwei Prozesse auf einer Sitzung: Ein Wächter fragt etwa jede Sekunde
#     Claudes Registry und für Codex die Prozessliste (WHISPERM8_SESSION_ID in der
#     Umgebung) ab. Blind ist er für eine Überschneidung, bevor sich ein neuer
#     Claude-Prozess in der Registry einträgt; das Ende deckt check_comeback ab
#     (alter Prozess muss tot sein, wenn ein neuer läuft);
#   - jeder Chat kommt zurück (übernommen oder fortgesetzt, je nach Szenario),
#     und sein Prozess bleibt einige Sekunden stabil;
#   - keine Leichen: kein Aufbewahrer, kein Socket (auch der Ausweich-Socket),
#     keine fremde Datei im Ordner des Aufbewahrers, kein Claude-Prozess ohne Chat;
#   - kein Schlüsselbund-Dialog (SecurityAgent) während des Szenarios, Ordner
#     des Aufbewahrers 0700, Dateien darin 0600;
#   - am Ende: Das Geheimnis (jede unbekannte kleine Datei im Ordner des
#     Aufbewahrers) steht in keinem Log.
#
# Signatur (Vics Auflage 4): `--signing dev` signiert das Test-Bundle mit
# „WhisperM8 Local Dev“ wie `make dev`, `--signing adhoc` ad hoc wie die
# Release-Pipeline (Brew-Nutzer). binary-swap ersetzt dann das Bundle durch
# einen neuen Build derselben Art: Dev auf Dev oder ad hoc auf ad hoc.
#
# Ergebnis und Exit wie handover-soak.sh: OK, FEHLER, FEHLT; Exit 0/1/2/64. Ein
# Szenario, dem eine Voraussetzung fehlt, steht nur als FEHLT da, ohne weitere
# Einträge. Nach binary-swap trägt das Test-Bundle die Build-Nummer „soak-…“,
# nach --signing adhoc eine Ad-hoc-Signatur; `scripts/test-instance.sh build`
# setzt beides zurück.
set -euo pipefail

# shellcheck source=handover-soak.sh
source "$(cd "$(dirname "$0")" && pwd)/handover-soak.sh"

APP="$REPO/.build-test/WhisperM8Test.app"
TEST_DOMAIN="com.whisperm8.app.test"
HANDOVER_DIR="$ROOT/home/Library/Application Support/WhisperM8/handover"
COMEBACK_TIMEOUT=120
SETTLE_SECONDS=5
SAMPLER_PID=""
ONLY=""
SCENARIOS="kill-mid-take hold-deadline secret-missing secret-wrong binary-swap double-restart"
KNOBS="handoverTakeDelayMs handoverHoldSeconds handoverSecretOverride"
SKIPPED=2   # Rückgabe einer Szenario-Funktion: Voraussetzung fehlt, nichts geprüft
SIGNING=""  # Signaturart des Test-Bundles und jedes Austauschs: dev, adhoc oder leer (vom Bundle übernehmen)
# Dateien aus Paket 2 (Aufbewahrer) und Paket 4 (last-take.json); alles andere gilt als
# Geheimnis-Kandidat (Ablage als Datei, Vics Urteil) und muss danach weg sein.
KNOWN_HANDOVER_FILES="keeper.lock keeper.log socket-path keeper.sock last-take.json"

# MARK: - Fähigkeiten (Paket 4)

has_handover_only() { grep -qE '^[[:space:]]*handover\)' "$TI"; }
# Stellschraube der Test-Instanz, die Paket 4 im Code liest.
has_knob() {
    local hits
    hits=$(grep -rh "\"$1\"" "$REPO/WhisperM8" 2>/dev/null | grep -v '^[[:space:]]*//' || true)
    [[ -n "$hits" ]]
}
has_codesign_identity() {
    local ids
    ids=$(security find-identity -p codesigning -v 2>/dev/null || true)
    contains "$ids" 'WhisperM8 Local Dev'
}

# Für binary-swap: dev braucht das Zertifikat, ad hoc nichts.
has_signing() { [[ "$SIGNING" == adhoc ]] || { [[ "$SIGNING" == dev ]] && has_codesign_identity; }; }

cmd_fault_capabilities() {
    local name
    for name in chat_start keep_chats handover_only codesign_identity; do
        if "has_$name"; then echo "da     $name"; else echo "fehlt  $name"; fi
    done
    for name in $KNOBS; do
        if has_knob "$name"; then echo "da     knob:$name"; else echo "fehlt  knob:$name"; fi
    done
}

# MARK: - Reine Prüf-Funktionen (self-test)

# Wie ist ein Chat zurückgekommen? Ausgabe: OK/FEHLER mit Begründung.
#   erwartung: same (übernommen), resumed (über den Rückfall), either
judge_comeback() { # pid_vorher pid_jetzt alter_lebt(0|1) erwartung
    local before="$1" now="$2" old_alive="$3" expect="$4"
    if [[ -z "$now" ]]; then echo "FEHLER nicht zurückgekommen"; return 0; fi
    if [[ "$now" == "$before" ]]; then
        if [[ "$expect" == resumed ]]; then echo "FEHLER alter Prozess $now lebt noch (erwartet: beendet und fortgesetzt)"
        else echo "OK übernommen ($now)"; fi
        return 0
    fi
    if [[ "$old_alive" == 1 ]]; then echo "FEHLER zwei Prozesse: alt $before lebt neben neu $now"; return 0; fi
    if [[ "$expect" == same ]]; then echo "FEHLER Rückfall statt Übernahme ($before -> $now)"
    else echo "OK fortgesetzt ($before -> $now)"; fi
}

# Claude-Prozesse aus der Registry, die zu keinem Chat gehören (Leichen).
orphans() { # registry-ausgabe chat-pids(leerzeichengetrennt)
    printf '%s\n' "$1" | awk -v keep=" $2 " '
        NF >= 2 { for (i = 2; i <= NF; i++) if (index(keep, " " $i " ") == 0) print $i }'
}

# Doppelte Sitzungen aus einer Registry-Ausgabe, mit Zeitstempel.
violations_now() { # registry-ausgabe zeit
    printf '%s\n' "$1" | awk -v t="$2" 'NF > 2 {print t, $0}'
}

# Codex-Prozesse je Chat aus `ps -E -ww -axo pid=,comm=,command=` (stdin):
# nur Prozesse namens codex in dieser Test-Wurzel. Ausgabe: Chats mit mehr als
# einem Prozess („sitzung pid pid…“).
codex_doubles() { # wurzel
    "$PY" -I -c '
import os, re, sys
root = sys.argv[1]
groups = {}
for line in sys.stdin:
    parts = line.split(None, 2)
    if len(parts) < 3 or os.path.basename(parts[1]) != "codex":
        continue
    found = re.search(r"WHISPERM8_INSTANCE_ROOT=(\S+)", parts[2])
    if not found or os.path.normpath(found.group(1)) != os.path.normpath(root):
        continue
    m = re.search(r"WHISPERM8_SESSION_ID=(\S+)", parts[2])
    if m:
        groups.setdefault(m.group(1), []).append(parts[0])
for sid, pids in sorted(groups.items()):
    if len(pids) > 1:
        print(sid, *pids)
' "$1"
}

# Aufbewahrer-Status (JSON von `app handover-status --json`): „pid anzahl phase“ oder leer.
keeper_summary() {
    "$PY" -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
k = d.get("keeper") if d.get("active") else None
if k:
    print(k.get("pid", ""), len(k.get("chats", [])), k.get("phase", ""))
'
}

# Prozesse eines Aufbewahrers genau dieser Wurzel (exakter Teilstring, kein Regex).
keeper_pids_from() { # ps-ausgabe(pid command) handover-dir
    printf '%s\n' "$1" | awk -v needle="handover-keeper --root $2 " 'index($0, needle) {print $1}'
}

# Signaturart aus `codesign -dvv`: dev (Zertifikat WhisperM8 Local Dev), adhoc oder andere.
signing_kind_from() { # codesign-ausgabe
    if contains "$1" '^Signature=adhoc'; then echo adhoc
    elif contains "$1" '^Authority=WhisperM8 Local Dev$'; then echo dev
    else echo andere; fi
}

# Rechte im Ordner des Aufbewahrers (Vics Auflage 2: Geheimnis als Datei 0600
# im 0700-Ordner): Ordner 0700, jede Datei außer denen aus Paket 2 0600.
# Ausgabe: je Abweichung eine Zeile, sonst nichts.
handover_dir_issues() { # ordner
    [[ -d "$1" ]] || return 0
    local mode base
    mode=$(stat -f %Lp "$1" 2>/dev/null || echo '?')
    [[ "$mode" == 700 ]] || echo "Ordner $mode"
    for base in $(unknown_handover_files "$1"); do
        [[ -f "$1/$base" ]] || continue
        mode=$(stat -f %Lp "$1/$base" 2>/dev/null || echo '?')
        [[ "$mode" == 600 ]] || echo "Datei $mode $base"
    done
}

# Unbekannte Dateien im Ordner des Aufbewahrers (nur Namen).
unknown_handover_files() { # ordner
    local f base
    for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [[ -e "$f" ]] || continue
        base=$(basename "$f")
        [[ " $KNOWN_HANDOVER_FILES " == *" $base "* ]] && continue
        [[ "$base" == keeper.log.* ]] && continue
        [[ "$base" == .last-take-*.tmp ]] && continue   # Zwischendatei vor rename
        echo "$base"
    done
}

# Kleine unbekannte Dateien als Geheimnis-Kandidaten sichern (Name, Base64).
capture_secret_candidates() { # ordner ziel
    local base size line
    for base in $(unknown_handover_files "$1"); do
        [[ -f "$1/$base" ]] || continue
        size=$(stat -f %z "$1/$base" 2>/dev/null || echo 99999)
        (( size > 0 && size <= 4096 )) || continue
        line=$(printf '%s\t%s' "$base" "$(base64 < "$1/$base" 2>/dev/null | tr -d '\n')")
        grep -qxF -- "$line" "$2" 2>/dev/null || printf '%s\n' "$line" >> "$2" 2>/dev/null || true
    done
}

# Logzeilen (stdin) mit „secret“ und einem Hex-Wert ab 7 Zeichen (erlaubt sind
# höchstens 6). UUIDs zählen nicht. Ausgabe gekürzt: Zeit (falls die Zeile mit
# einer beginnt) und die ersten 6 Zeichen des Werts, egal wie die Zeile aussieht.
# Enthält die Ausgabe trotzdem 7 Hex-Zeichen am Stück, wird sie verworfen.
secret_pattern_hits() {
    "$PY" -I -c '
import re, sys
hit = re.compile(r"(secret[^0-9a-f]{0,6})([0-9a-f]{7,})(-[0-9a-f]{4}-)?", re.I)
stamp = re.compile(r"^\s*\[?(\d{4}-\d\d-\d\d[ T][\d:.]+Z?)")
uuid_tail = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-", re.I)
for line in sys.stdin:
    for m in hit.finditer(line):
        if uuid_tail.match(line[m.start(2):]):
            continue
        s = stamp.match(line)
        out = ((s.group(1) + " ") if s else "") + m.group(1) + m.group(2)[:6] + "…"
        if re.search(r"[0-9a-f]{7,}", out[len(s.group(1)) if s else 0:], re.I):
            out = "(Zeile verworfen, Wert nicht kürzbar)"
        print(out)
        break
' 2>/dev/null || true
}

# In welchen Dateien steht ein Geheimnis-Kandidat (roh, hex oder Base64)?
# Kandidaten unter 8 Byte zählen nicht, sonst träfe jede Zahl.
secret_hits() { # kandidaten-datei datei…
    "$PY" -I - "$@" <<'PYEOF'
import base64, sys
needles = set()
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t", 1)
    if len(parts) != 2:
        continue
    try:
        raw = base64.b64decode(parts[1])
    except Exception:
        continue
    raw = raw.strip()
    if len(raw) < 8:
        continue
    needles.update({raw, raw.hex().encode(), base64.b64encode(raw)})
for path in sys.argv[2:]:
    try:
        data = open(path, "rb").read()
    except OSError:
        continue
    if any(n in data for n in needles):
        print(path)
PYEOF
}

# MARK: - Werkzeuge

bundle_signing() { signing_kind_from "$(codesign -dvv "$1" 2>&1 || true)"; }
bundle_cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}' || true; }

signing_identity() { # art → Identität für codesign
    case "$1" in
        adhoc) echo - ;;
        dev) security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/WhisperM8 Local Dev/ {print $2; exit}' || true ;;
    esac
}

# Signiert wie das Makefile (`_build_dev`); ohne Zertifikat signiert es ad hoc,
# und so baut auch die Release-Pipeline.
sign_bundle() { # bundle art → 0 ok, sonst Grund auf stdout
    local id kind
    id=$(signing_identity "$2")
    [[ -n "$id" ]] || { echo "kein Zertifikat WhisperM8 Local Dev"; return 1; }
    codesign --force --deep --sign "$id" --entitlements "$REPO/WhisperM8/WhisperM8.entitlements" --timestamp=none "$1" >/dev/null 2>&1 \
        || { echo "Signieren gescheitert"; return 1; }
    codesign --verify --deep --strict "$1" >/dev/null 2>&1 || { echo "Signatur ungültig"; return 1; }
    kind=$(bundle_signing "$1")
    [[ "$kind" == "$2" ]] || { echo "Signatur ist ${kind}, erwartet $2"; return 1; }
}

# Haken aus prepare_instance: Test-Bundle vor dem Start in die verlangte
# Signaturart bringen. Ohne --signing gilt die Art des Bundles (so wie
# `test-instance.sh build` es signiert hat). Eine laufende Instanz
# (--use-running) wird nie umsigniert.
prepare_bundle() { # pid der laufenden instanz oder leer
    local kind reason
    kind=$(bundle_signing "$APP")
    if [[ -z "$SIGNING" ]]; then
        SIGNING=$kind
        record setup signatur OK "Test-Bundle $kind signiert, übernommen (CDHash $(bundle_cdhash "$APP"))"
        return 0
    fi
    if [[ "$kind" != "$SIGNING" ]]; then
        if [[ -n "$1" ]]; then
            echo "Test-Bundle ist $kind signiert, verlangt ist $SIGNING — eine laufende Instanz wird nicht umsigniert" >&2
            return 1
        fi
        reason=$(sign_bundle "$APP" "$SIGNING") || { echo "Test-Bundle nicht $SIGNING signiert: $reason" >&2; return 1; }
    fi
    record setup signatur OK "Test-Bundle $SIGNING signiert (CDHash $(bundle_cdhash "$APP"))"
}

keeper_status_json() {
    env -u WHISPERM8_SESSION_ID -u WHISPERM8_SESSION_TOKEN WHISPERM8_INSTANCE_ROOT="$ROOT" "$BIN" app handover-status --json 2>/dev/null || true
}

keeper_pids() { keeper_pids_from "$(ps -axww -o pid=,command= 2>/dev/null || true)" "$HANDOVER_DIR"; }

# Nur einen Aufbewahrer dieser Test-Wurzel töten, nie einen fremden Prozess.
kill_keeper() { # pid signal
    local command
    command=$(ps -ww -o command= -p "$1" 2>/dev/null || true)
    if [[ "$command" == *"handover-keeper --root $HANDOVER_DIR "* ]]; then
        kill "-$2" "$1"
        return 0
    fi
    return 1
}

set_knob() { defaults write "$TEST_DOMAIN" "$1" "$2" "$3"; }
clear_knobs() {
    local key
    for key in $KNOBS; do defaults delete "$TEST_DOMAIN" "$key" >/dev/null 2>&1 || true; done
}

sample_once() { # datei
    local now
    now=$(date +%H:%M:%S)
    violations_now "$(registry_pids "$ROOT/home/.claude/sessions" || true)" "$now" >> "$1" || true
    ps -E -ww -axo pid=,comm=,command= 2>/dev/null | codex_doubles "$ROOT" | sed "s/^/$now codex /" >> "$1" || true
    # Ein Schlüsselbund-Dialog blockiert die Übernahme unbeaufsichtigt (Ole, 13.11.).
    # Nur neue Prozesse zählen; was beim Start schon lief, steht in .keychain-base.
    pgrep -x SecurityAgent 2>/dev/null | grep -vxF -f "$1.keychain-base" | sed "s/^/$now SecurityAgent /" >> "$1.keychain" || true
    handover_dir_issues "$HANDOVER_DIR" | sed "s/^/$now /" >> "$1.modes" || true
    capture_secret_candidates "$HANDOVER_DIR" "$STATE/secret-candidates" || true
}

start_sampler() { # datei
    : > "$1"
    : > "$1.modes"
    keychain_baseline "$1"
    ( while :; do sample_once "$1"; sleep 0.3; done ) &
    SAMPLER_PID=$!
}

# Laufende SecurityAgent-Prozesse als Vergleichsstand; danach zählen nur neue.
keychain_baseline() { # wächter-datei
    pgrep -x SecurityAgent > "$1.keychain-base" 2>/dev/null || true
    : > "$1.keychain"
}

stop_sampler() {
    if [[ -n "$SAMPLER_PID" ]]; then
        kill "$SAMPLER_PID" 2>/dev/null || true
        wait "$SAMPLER_PID" 2>/dev/null || true
        SAMPLER_PID=""
    fi
}

# Programm unter dem laufenden Aufbewahrer ersetzen, wie `make dev` oder ein
# Brew-Update. stage_bundle baut vorher den neuen Build (neue Build-Nummer,
# signiert in der Art aus --signing), damit codesign nicht im Messfenster den
# Schlüsselbund fragt; swap_bundle tauscht nur noch per rsync (Umbenennen).
# Jeder Schritt muss klappen, sonst bleibt das Bundle unangetastet.
stage_bundle() { # build-nummer → 0 ok, sonst Grund auf stdout
    local work="$SOAK/swap" copy reason
    [[ -d "$APP/Contents/MacOS" ]] || { echo "kein Test-Bundle unter $APP"; return 1; }
    rm -rf "$work" && mkdir -p "$work" || { echo "Arbeitsordner"; return 1; }
    cp -R "$APP" "$work/" || { echo "Kopie gescheitert"; return 1; }
    copy="$work/$(basename "$APP")"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $1" "$copy/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $1" "$copy/Contents/Info.plist" \
        || { echo "Info.plist"; return 1; }
    reason=$(sign_bundle "$copy" "$SIGNING") || { echo "Kopie: $reason"; return 1; }
    : > "$work/ready"
}

swap_bundle() { # → 0 ok, sonst Grund auf stdout
    local work="$SOAK/swap" copy
    copy="$work/$(basename "$APP")"
    [[ -f "$work/ready" && -d "$copy/Contents/MacOS" ]] || { echo "kein vorbereiteter Build"; return 1; }
    rsync -a --delete "$copy/" "$APP/" || { echo "rsync gescheitert"; return 1; }
    rm -rf "$work"
}

# MARK: - Gemeinsame Prüfungen je Szenario

chat_pids_now() {
    local name pids=""
    for name in $(chat_names); do pids="$pids $(chat_pid "$name")"; done
    echo "$pids"
}

# Wartet auf einen stabilen Prozess des Chats. Bei Erwartung `resumed` zählt
# nur eine neue PID (der alte Prozess lebt nach SIGKILL des Aufbewahrers oft
# noch kurz, bis das SIGHUP wirkt). Liest mindestens einmal, auch nach Fristende.
await_pid() { # name pid_vorher erwartung frist(epoch) → pid oder leer
    local name="$1" before="$2" expect="$3" deadline="$4" pid stable
    while :; do
        pid=$(chat_pid "$name")
        if [[ -n "$pid" ]] && { [[ "$expect" != resumed ]] || [[ "$pid" != "$before" ]]; } && kill -0 "$pid" 2>/dev/null; then
            sleep "$SETTLE_SECONDS"
            stable=$(chat_pid "$name")
            if [[ "$stable" == "$pid" ]] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; return 0; fi
        fi
        if (( $(date +%s) >= deadline )); then
            # Frist vorbei: frisch lesen und nur eine lebende PID melden.
            pid=$(chat_pid "$name")
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; else echo ""; fi
            return 0
        fi
        sleep 2
    done
}

# Befund 13.11.2026: Nach dem Rückfall startet ein fortgesetzter Chat im Grid
# erst, wenn er ausgewählt wird, obwohl sein Pane angezeigt ist (rendered).
# Das wird gemeldet; danach wählt das Skript ihn per `chats open` aus, damit
# die übrigen Prüfungen und Szenarien laufen.
START_WITHOUT_SELECT_SECONDS=20
nudge_unstarted() { # szenario vorher-datei
    local scenario="$1" before="$2" name end missing
    end=$(( $(date +%s) + START_WITHOUT_SELECT_SECONDS ))
    while :; do
        missing=""
        for name in $(chat_names); do
            # Nur Chats, die vorher einen Prozess hatten; der Rest ist FEHLT.
            [[ -n "$(awk -F'\t' -v n="$name" '$1 == n {print $2}' "$before")" ]] || continue
            [[ -n "$(chat_pid "$name")" ]] || missing="$missing $name"
        done
        if [[ -z "$missing" ]]; then
            record "$scenario" start-ohne-auswahl OK "alle Chats laufen ohne Auswahl"
            return 0
        fi
        (( $(date +%s) < end )) || break
        sleep 2
    done
    record "$scenario" start-ohne-auswahl FEHLER "nach ${START_WITHOUT_SELECT_SECONDS} s ohne Prozess, obwohl im Grid angezeigt:$missing (jetzt per chats open ausgewählt)"
    for name in $missing; do
        cli chats open "$(chat_ref "$name")" --json >/dev/null 2>&1 || true
        sleep 1
    done
}

check_comeback() { # szenario vorher-datei erwartung
    local scenario="$1" before="$2" expect="$3" name pid_before pid_now old_alive deadline
    deadline=$(( $(date +%s) + COMEBACK_TIMEOUT ))
    while IFS=$'\t' read -r name pid_before; do
        if [[ -z "$pid_before" ]]; then
            record "$scenario" "zurueck:$name" FEHLT "PID vorher nicht ermittelbar"
            continue
        fi
        pid_now=$(await_pid "$name" "$pid_before" "$expect" "$deadline")
        old_alive=0
        kill -0 "$pid_before" 2>/dev/null && old_alive=1
        record_verdict "$scenario" "zurueck:$name" "$(judge_comeback "$pid_before" "$pid_now" "$old_alive" "$expect")"
    done < "$before"
}

check_no_leftovers() { # szenario verletzungen-datei
    local scenario="$1" violations="$2" registry stray socket
    if [[ -s "$violations" ]]; then
        record "$scenario" zwei-prozesse FEHLER "$(head -3 "$violations" | tr '\n' ';')"
    else
        record "$scenario" zwei-prozesse OK "Wächter ohne Befund"
    fi
    socket=""
    [[ -f "$HANDOVER_DIR/socket-path" ]] && socket=$(head -1 "$HANDOVER_DIR/socket-path")
    if [[ -n "$(keeper_pids)" ]]; then
        record "$scenario" leichen:aufbewahrer FEHLER "läuft noch: $(keeper_pids | tr '\n' ' ')"
    elif [[ -e "$HANDOVER_DIR/keeper.sock" || -f "$HANDOVER_DIR/socket-path" || ( -n "$socket" && -e "$socket" ) ]]; then
        record "$scenario" leichen:aufbewahrer FEHLER "Socket oder Discovery-Datei liegt noch (${socket:-$HANDOVER_DIR/keeper.sock})"
    else
        record "$scenario" leichen:aufbewahrer OK ""
    fi
    local extra
    extra=$(unknown_handover_files "$HANDOVER_DIR" | tr '\n' ' ')
    if [[ -n "$extra" ]]; then
        record "$scenario" leichen:dateien FEHLER "im Ordner des Aufbewahrers liegt noch: $extra"
    else
        record "$scenario" leichen:dateien OK ""
    fi
    if [[ -s "$violations.keychain" ]]; then
        record "$scenario" schluesselbund-dialog FEHLER "SecurityAgent lief: $(head -2 "$violations.keychain" | tr '\n' ';') (kann auch eine fremde App sein, Bildschirm prüfen)"
    else
        record "$scenario" schluesselbund-dialog OK ""
    fi
    if [[ -s "$violations.modes" && ! -s "$STATE/secret-candidates" ]]; then
        record "$scenario" rechte-aufbewahrer FEHLT "noch kein Geheimnis als Datei (Paket 4), Befund bis dahin: $(awk '!seen[$2 FS $3 FS $4]++' "$violations.modes" | head -2 | tr '\n' ';')"
    elif [[ -s "$violations.modes" ]]; then
        record "$scenario" rechte-aufbewahrer FEHLER "$(awk '!seen[$2 FS $3 FS $4]++' "$violations.modes" | head -3 | tr '\n' ';')"
    else
        record "$scenario" rechte-aufbewahrer OK "Ordner 0700, Geheimnis-Kandidaten 0600 (oder kein Ordner)"
    fi
    registry=$(registry_pids "$ROOT/home/.claude/sessions" || true)
    stray=$(orphans "$registry" "$(chat_pids_now)")
    if [[ -n "$stray" ]]; then
        record "$scenario" leichen:claude FEHLER "Prozesse ohne Chat: $(printf '%s' "$stray" | tr '\n' ' ')"
    else
        record "$scenario" leichen:claude OK ""
    fi
}

# Rahmen jedes Szenarios. Szenario-Funktionen melden ihre Schritte selbst
# (errexit ist in ihnen abgeschaltet, weil sie in `|| rc=$?` laufen) und
# liefern $SKIPPED, wenn eine Voraussetzung fehlt — dann gibt es nichts zu prüfen.
run_scenario() { # name erwartung funktion
    local name="$1" expect="$2" action="$3" rc=0
    local before="$STATE/fault-$name-before.tsv" violations="$STATE/fault-$name-violations.log"
    log "Szenario $name"
    snapshot "$before"
    start_sampler "$violations"
    "$action" "$name" || rc=$?
    if (( rc == SKIPPED )); then
        stop_sampler
        clear_knobs
        return 0
    fi
    # Grid im Hauptprozess öffnen: Der Neustart lief im Hintergrund, ein
    # Fehler beim Öffnen dort ginge im Bericht verloren.
    [[ -n "$("$TI" status | awk '/^PID:/ {print $2}')" ]] && reopen_grid
    rm -f "$STATE/pid-ambiguous.log"
    nudge_unstarted "$name" "$before"
    check_comeback "$name" "$before" "$expect"
    if [[ -s "$STATE/pid-ambiguous.log" ]]; then
        record "$name" zwei-prozesse-umgebung FEHLER \
            "mehrere oberste Prozesse je Sitzung: $(sort -u "$STATE/pid-ambiguous.log" | tr '\t\n' ': ' )"
    fi
    stop_sampler
    clear_knobs
    check_no_leftovers "$name" "$violations"
    check_no_inherited_sockets "$name"
}

requires() { # szenario fähigkeit… — trägt FEHLT ein und liefert 1, wenn etwas fehlt
    local scenario="$1" missing="" cap
    shift
    for cap in "$@"; do
        case "$cap" in
            knob:*) has_knob "${cap#knob:}" || missing="$missing $cap" ;;
            *) "has_$cap" || missing="$missing $cap" ;;
        esac
    done
    if [[ -n "$missing" ]]; then
        record "$scenario" voraussetzung FEHLT "braucht aus Paket 4:$missing"
        return 1
    fi
}

# Wartet, bis ein Aufbewahrer mitten in der Übernahme ist (mindestens einer
# übernommen, mindestens einer noch da). Ausgabe: „pid übernommen gesamt“.
await_mid_take() { # sekunden
    local end summary keeper n seen=0
    end=$(( $(date +%s) + $1 ))
    while (( $(date +%s) < end )); do
        summary=$(keeper_status_json | keeper_summary)
        if [[ -n "$summary" ]]; then
            read -r keeper n _ <<< "$summary"
            if (( n > seen )); then seen=$n; fi
            if (( seen > 1 && n >= 1 && n < seen )); then echo "$keeper $((seen - n)) $seen"; return 0; fi
        fi
        sleep 0.2
    done
    echo "- 0 $seen"
    return 1
}

# MARK: - Szenarien

fault_kill_mid_take() { # szenario
    local scenario="$1" restart_pid hit keeper taken total
    requires "$scenario" keep_chats knob:handoverTakeDelayMs || return "$SKIPPED"
    set_knob handoverTakeDelayMs -int 3000
    ti restart --keep-chats > "$STATE/fault-$scenario-restart.log" 2>&1 &
    restart_pid=$!
    if hit=$(await_mid_take 60); then
        read -r keeper taken total <<< "$hit"
        if kill_keeper "$keeper" KILL; then
            record "$scenario" ausgeloest OK "SIGKILL an $keeper nach $taken von $total Übernahmen"
        else
            record "$scenario" ausgeloest FEHLER "SIGKILL an $keeper gescheitert (Prozess passt nicht zur Test-Wurzel?)"
        fi
    else
        read -r _ _ total <<< "$hit"
        record "$scenario" ausgeloest FEHLER "Zeitfenster mitten in der Übernahme nicht getroffen (gesehen: $total Chats)"
    fi
    wait "$restart_pid" 2>/dev/null || true
    return 0
}

fault_hold_deadline() {
    local scenario="$1" summary keeper n old name pid
    requires "$scenario" handover_only knob:handoverHoldSeconds || return "$SKIPPED"
    set_knob handoverHoldSeconds -int 20
    if ! ti handover > "$STATE/fault-$scenario-handover.log" 2>&1; then
        record "$scenario" ausgeloest FEHLER "test-instance.sh handover gescheitert: $(tail -1 "$STATE/fault-$scenario-handover.log")"
        ti start > /dev/null 2>&1 || true
        return 1
    fi
    summary=$(keeper_status_json | keeper_summary)
    if [[ -z "$summary" ]]; then
        record "$scenario" ausgeloest FEHLER "nach handover kein Aufbewahrer"
    else
        read -r keeper n _ <<< "$summary"
        record "$scenario" ausgeloest OK "Aufbewahrer $keeper hält $n Chats, Frist 20 s"
    fi
    sleep 30
    # Nach der Frist: Aufbewahrer selbst beendet, kein alter Chat-Prozess lebt.
    if [[ -n "$(keeper_pids)" ]]; then record "$scenario" frist-aufbewahrer FEHLER "lebt nach der Frist noch"
    else record "$scenario" frist-aufbewahrer OK ""; fi
    old=""
    while IFS=$'\t' read -r name pid; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then old="$old $name:$pid"; fi
    done < "$STATE/fault-$scenario-before.tsv"
    if [[ -n "$old" ]]; then record "$scenario" frist-chats-beendet FEHLER "leben nach der Frist noch:$old"
    else record "$scenario" frist-chats-beendet OK ""; fi
    ti start > "$STATE/fault-$scenario-start.log" 2>&1 \
        || record "$scenario" neustart FEHLER "start gescheitert: $(tail -1 "$STATE/fault-$scenario-start.log")"
    return 0
}

fault_secret() { # szenario wert
    local scenario="$1" value="$2" restart_pid end seen="" gone=0
    requires "$scenario" keep_chats knob:handoverSecretOverride || return "$SKIPPED"
    set_knob handoverSecretOverride -string "$value"
    ti restart --keep-chats > "$STATE/fault-$scenario-restart.log" 2>&1 &
    restart_pid=$!
    # Erst muss es einen Aufbewahrer geben, sonst ist „beendet“ bedeutungslos.
    end=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < end )); do
        seen=$(keeper_pids | head -1)
        [[ -n "$seen" ]] && break
        sleep 0.2
    done
    if [[ -z "$seen" ]]; then
        record "$scenario" ausgeloest FEHLER "kein Aufbewahrer gesehen (Abgabe gescheitert?)"
    else
        record "$scenario" ausgeloest OK "Aufbewahrer $seen, Geheimnis: $value"
        # Ohne gültiges Geheimnis darf er nicht bis zur Frist (10 min) halten:
        # Die App beendet ihn über die PID aus STATUS.
        end=$(( $(date +%s) + 45 ))
        while (( $(date +%s) < end )); do
            kill -0 "$seen" 2>/dev/null || { gone=1; break; }
            sleep 1
        done
        if (( gone )); then record "$scenario" aufbewahrer-beendet OK ""
        else record "$scenario" aufbewahrer-beendet FEHLER "hält nach 45 s noch (wartet er auf die Frist?)"; fi
    fi
    wait "$restart_pid" 2>/dev/null || true
    return 0
}
fault_secret_missing() { fault_secret "$1" missing; }
fault_secret_wrong() { fault_secret "$1" wrong; }

fault_binary_swap() {
    local scenario="$1" build reason summary keeper bin old_hash new_hash
    requires "$scenario" handover_only signing || return "$SKIPPED"
    build="soak-$(date +%s)"
    if ! reason=$(stage_bundle "$build"); then
        record "$scenario" ausgeloest FEHLER "neuer Build nicht vorbereitet: $reason — nichts abgegeben"
        return 1
    fi
    # Das Signieren gehört nicht zur Übergabe: Vergleichsstand für den Schlüsselbund neu setzen.
    keychain_baseline "$STATE/fault-$scenario-violations.log"
    if ! ti handover > "$STATE/fault-$scenario-handover.log" 2>&1; then
        record "$scenario" ausgeloest FEHLER "test-instance.sh handover gescheitert: $(tail -1 "$STATE/fault-$scenario-handover.log")"
        ti start > /dev/null 2>&1 || true
        return 1
    fi
    # Der Aufbewahrer muss aus genau dem Bundle laufen, das ersetzt wird.
    summary=$(keeper_status_json | keeper_summary)
    read -r keeper _ _ <<< "${summary:-- 0 -}"
    bin=$(ps -o comm= -p "$keeper" 2>/dev/null || true)
    if [[ "$bin" != "$APP/"* ]]; then
        record "$scenario" ausgeloest FEHLER "Aufbewahrer ($keeper) läuft nicht aus $APP, sondern aus ${bin:-?}"
        ti start > /dev/null 2>&1 || true
        return 1
    fi
    old_hash=$(bundle_cdhash "$APP")
    if reason=$(swap_bundle); then
        record "$scenario" ausgeloest OK "Bundle ersetzt (CFBundleVersion $build), Aufbewahrer $keeper läuft aus dem alten Programm"
        new_hash=$(bundle_cdhash "$APP")
        if [[ -n "$new_hash" && "$new_hash" != "$old_hash" ]]; then
            record "$scenario" signatur OK "$SIGNING auf ${SIGNING}, CDHash $old_hash -> $new_hash"
        else
            record "$scenario" signatur FEHLER "CDHash unverändert ($old_hash -> ${new_hash:-?}), kein neuer Build"
        fi
    else
        record "$scenario" ausgeloest FEHLER "Austausch gescheitert: $reason — Bundle unverändert"
    fi
    ti start > "$STATE/fault-$scenario-start.log" 2>&1 \
        || record "$scenario" neustart FEHLER "start gescheitert: $(tail -1 "$STATE/fault-$scenario-start.log")"
    return 0
}

fault_double_restart() {
    local scenario="$1" first_pid hit second_ok=1
    requires "$scenario" keep_chats knob:handoverTakeDelayMs || return "$SKIPPED"
    # Langsame Übernahme, damit der zweite Neustart sie sicher trifft.
    set_knob handoverTakeDelayMs -int 3000
    ti restart --keep-chats > "$STATE/fault-$scenario-1.log" 2>&1 &
    first_pid=$!
    if hit=$(await_mid_take 60); then
        ti restart --keep-chats > "$STATE/fault-$scenario-2.log" 2>&1 || second_ok=0
        record "$scenario" ausgeloest OK "zweiter Neustart mitten in der Übernahme ($hit)"
        if (( ! second_ok )); then
            record "$scenario" zweiter-neustart FEHLER "$(tail -1 "$STATE/fault-$scenario-2.log")"
        fi
    else
        record "$scenario" ausgeloest FEHLER "Übernahme des ersten Neustarts nicht gesehen"
    fi
    wait "$first_pid" 2>/dev/null || record "$scenario" erster-neustart FEHLER "$(tail -1 "$STATE/fault-$scenario-1.log")"
    return 0
}

# Erwartung je Szenario: wie die Chats zurückkommen müssen.
scenario_expectation() {
    case "$1" in
        kill-mid-take) echo either ;;          # übernommene bleiben, der Rest fortgesetzt
        hold-deadline) echo resumed ;;         # nach der Frist beendet, dann fortgesetzt
        secret-missing|secret-wrong) echo resumed ;;
        binary-swap|double-restart) echo same ;;
    esac
}

scenario_function() { echo "fault_$(printf '%s' "$1" | tr '-' '_')"; }

# MARK: - Ablauf

# Liefert die App für diesen Chat eine PID? Claude über die Registry; Codex und
# Terminal erst mit runtime.pid aus Paket 4.
pid_measurable() { # name
    [[ "$(chat_provider "$1")" == claude ]] && return 0
    contains "$(chat_show "$1")" '"pid"'
}

wait_until_running() {
    local end name missing unmeasurable=""
    for name in $(chat_names); do pid_measurable "$name" || unmeasurable="$unmeasurable $name"; done
    if [[ -n "$unmeasurable" ]] && [[ ! -f "$STATE/unmeasurable-recorded" ]]; then
        record setup pid-messbar FEHLT "ohne ermittelbare PID (runtime.pid, Paket 4):$unmeasurable — dort keine Prüfung"
        : > "$STATE/unmeasurable-recorded"
    fi
    end=$(( $(date +%s) + COMEBACK_TIMEOUT ))
    while :; do
        missing=""
        for name in $(chat_names); do
            [[ " $unmeasurable " == *" $name "* ]] && continue
            [[ -n "$(chat_pid "$name")" ]] || missing="$missing $name"
        done
        [[ -z "$missing" ]] && return 0
        (( $(date +%s) < end )) || break
        sleep 2
    done
    record setup laufen FEHLER "ohne Prozess:$missing"
    return 1
}

# Vics Auflage 2: Das Geheimnis steht nie im Log. Zwei Wege:
#   - Muster: eine Logzeile der Test-App mit „secret“ und einem langen
#     Hex-Wert (Lauf vom 13.11., 13:36: handover_take_plan schrieb den Anfang
#     des Geheimnisses öffentlich ins System-Log). Greift auch bei Ablage im
#     Schlüsselbund.
#   - Kandidaten: Inhalt jeder unbekannten kleinen Datei im Ordner des
#     Aufbewahrers (Ablage als Datei), roh, hex oder Base64 in keeper.log,
#     Log der Test-Instanz und System-Log.
check_secret_not_logged() {
    local candidates="$STATE/secret-candidates" unified="$STATE/unified.log" hits pattern
    # Mit --info --debug, sonst liefert log show nur Default-Meldungen.
    /usr/bin/log show --info --debug --style compact --start "$(cat "$STATE/started-at")" \
        --predicate 'processImagePath CONTAINS "WhisperM8Test.app"' > "$unified" 2>/dev/null || true
    pattern=$(cat "$unified" "$HANDOVER_DIR"/keeper.log* "$ROOT/instance.log" 2>/dev/null \
        | secret_pattern_hits | head -2 | tr '\n' ';')
    if [[ -n "$pattern" ]]; then
        record ende geheimnis-muster FEHLER "Logzeile mit Geheimnis-Wert (gekürzt): $pattern"
    elif [[ -s "$unified" ]]; then
        record ende geheimnis-muster OK "System-Log (inkl. info/debug), keeper.log und instance.log ohne secret=<hex>"
    else
        record ende geheimnis-muster FEHLT "System-Log der Test-App leer oder nicht lesbar"
    fi
    if [[ ! -s "$candidates" ]]; then
        record ende geheimnis-im-log FEHLT "kein Geheimnis-Kandidat im Ordner des Aufbewahrers gesehen (Ablage als Datei aus Paket 4?)"
        return 0
    fi
    hits=$(secret_hits "$candidates" "$HANDOVER_DIR"/keeper.log* "$ROOT/instance.log" "$unified" | tr '\n' ' ')
    if [[ -n "$hits" ]]; then
        record ende geheimnis-im-log FEHLER "Geheimnis steht in: $hits"
    else
        record ende geheimnis-im-log OK "$(cut -f1 "$candidates" | sort -u | tr '\n' ' ')geprüft"
    fi
}

on_fault_exit() {
    local status=$?
    stop_sampler
    clear_knobs
    on_exit "$status"
}

validate_scenarios() { # liste
    local scenario
    for scenario in $1; do
        [[ " $SCENARIOS " == *" $scenario "* ]] || { echo "unbekanntes Szenario: $scenario" >&2; exit 64; }
    done
}

cmd_fault_run() {
    local list="${ONLY:-$SCENARIOS}" scenario
    validate_scenarios "$list"
    ROUNDS=$(echo "$list" | wc -w | tr -d ' ')
    prepare_instance
    RUN_STARTED=1
    trap on_fault_exit EXIT
    date '+%Y-%m-%d %H:%M:%S' > "$STATE/started-at"
    clear_knobs
    rm -f "$STATE/unmeasurable-recorded" "$STATE/secret-candidates"
    setup_chats
    if ! wait_until_running; then
        for scenario in $list; do
            record "$scenario" voraussetzung FEHLER "Chats laufen nicht, Szenario nicht gefahren"
        done
    else
        check_no_inherited_sockets setup
        for scenario in $list; do
            run_scenario "$scenario" "$(scenario_expectation "$scenario")" "$(scenario_function "$scenario")"
            wait_until_running || { record "$scenario" weiter FEHLER "Chats nicht zurück, Rest abgebrochen"; break; }
        done
    fi
    stop_sampler
    check_secret_not_logged
    (( KEEP )) || cleanup_chats
    clear_knobs
    RUN_STARTED=0
    local status=0
    report || status=$?
    release_instance_lock
    exit "$status"
}

# MARK: - Selbsttest

cmd_fault_self_test() {
    local failures=0
    expect_exact() {
        if [[ "$2" == "$1" ]]; then echo "ok    $3"; else echo "FAIL  $3: erwartet '$1', bekam '$2'"; failures=$((failures + 1)); fi
    }
    expect_exact "OK übernommen (10)" "$(judge_comeback 10 10 1 same)" "gleiche PID, Übernahme erwartet"
    expect_exact "OK übernommen (10)" "$(judge_comeback 10 10 1 either)" "gleiche PID, beides erlaubt"
    expect_exact "FEHLER alter Prozess 10 lebt noch (erwartet: beendet und fortgesetzt)" "$(judge_comeback 10 10 1 resumed)" "alter Prozess überlebt die Frist"
    expect_exact "OK fortgesetzt (10 -> 20)" "$(judge_comeback 10 20 0 resumed)" "fortgesetzt wie erwartet"
    expect_exact "FEHLER Rückfall statt Übernahme (10 -> 20)" "$(judge_comeback 10 20 0 same)" "Rückfall, wo Übernahme erwartet"
    expect_exact "FEHLER zwei Prozesse: alt 10 lebt neben neu 20" "$(judge_comeback 10 20 1 either)" "zwei Prozesse"
    expect_exact "FEHLER nicht zurückgekommen" "$(judge_comeback 10 "" 0 either)" "nicht zurück"

    expect_exact "30" "$(orphans "$(printf 's1 10\ns2 20\ns3 30')" "10 20")" "Leiche erkannt"
    expect_exact "" "$(orphans "$(printf 's1 10\ns2 20')" "10 20 ")" "keine Leiche"
    expect_exact "" "$(orphans "" "10")" "leere Registry"

    expect_exact "12:00:00 s1 10 11" "$(violations_now "$(printf 's1 10 11\ns2 20')" 12:00:00)" "Verletzung mit Zeit"
    expect_exact "" "$(violations_now "s2 20" 12:00:00)" "keine Verletzung"

    local ps_fixture
    ps_fixture=$(printf '%s\n' \
        "101 /usr/local/bin/codex codex resume a WHISPERM8_INSTANCE_ROOT=/r WHISPERM8_SESSION_ID=S1" \
        "102 /usr/local/bin/codex codex resume a WHISPERM8_INSTANCE_ROOT=/r WHISPERM8_SESSION_ID=S1" \
        "103 /usr/local/bin/codex codex WHISPERM8_INSTANCE_ROOT=/r WHISPERM8_SESSION_ID=S2" \
        "104 /bin/zsh zsh WHISPERM8_INSTANCE_ROOT=/r WHISPERM8_SESSION_ID=S2" \
        "105 /usr/local/bin/codex codex WHISPERM8_INSTANCE_ROOT=/anders WHISPERM8_SESSION_ID=S2" \
        "106 /usr/local/bin/codex codex WHISPERM8_INSTANCE_ROOT=/r2 WHISPERM8_SESSION_ID=S2" \
        "107 /usr/local/bin/codex codex WHISPERM8_INSTANCE_ROOT=/r/ WHISPERM8_SESSION_ID=S3" \
        "108 /usr/local/bin/codex codex WHISPERM8_INSTANCE_ROOT=/r WHISPERM8_SESSION_ID=S3")
    expect_exact "S1 101 102
S3 107 108" "$(printf '%s\n' "$ps_fixture" | codex_doubles /r)" "Codex doppelt: Wurzel exakt (auch mit /), nur codex"

    expect_exact "4242 2 holding" "$(printf '%s' '{"active": true, "keeper": {"pid": 4242, "phase": "holding", "chats": [{}, {}]}}' | keeper_summary)" "Aufbewahrer-Status gelesen"
    expect_exact "" "$(printf '%s' '{"active": false}' | keeper_summary)" "kein Aufbewahrer"
    expect_exact "" "$(printf '%s' 'kaputt' | keeper_summary)" "kaputtes JSON"

    expect_exact "7" "$(keeper_pids_from "$(printf '%s\n' \
        "7 /x/WhisperM8 handover-keeper --root /r/a.b/handover --run 1" \
        "8 /x/WhisperM8 handover-keeper --root /r/a.b/handover-anders --run 2" \
        "9 /x/WhisperM8 handover-keeper --root /r/aXb/handover --run 3")" "/r/a.b/handover")" "Aufbewahrer genau dieser Wurzel"

    expect_exact "fault_kill_mid_take" "$(scenario_function kill-mid-take)" "Szenario-Funktion"
    local scenario
    for scenario in $SCENARIOS; do
        expect_exact "ja" "$(declare -F "$(scenario_function "$scenario")" >/dev/null && echo ja || echo nein)" "Funktion für $scenario"
        [[ -n "$(scenario_expectation "$scenario")" ]] || { echo "FAIL  Erwartung für $scenario"; failures=$((failures + 1)); }
    done

    # kill_keeper tötet nie einen fremden Prozess.
    sleep 30 &
    local stranger=$!
    expect_exact "nein" "$(kill_keeper "$stranger" KILL && echo ja || echo nein)" "fremder Prozess bleibt verschont"
    kill "$stranger" 2>/dev/null || true
    wait "$stranger" 2>/dev/null || true

    # Abbruch: Exit-Status kommt beim Bericht an (vorher verloren im Trap).
    expect_exact "record abbruch FEHLER Lauf abgebrochen (Exit 3);report" "$(
        stop_sampler() { :; }; clear_knobs() { :; }
        record() { printf 'record %s %s %s;' "$1" "$3" "$4"; }
        report() { printf 'report'; }
        cleanup_chats() { :; }
        RUN_STARTED=1 KEEP=1
        (exit 3) || on_fault_exit
    )" "Abbruch meldet den echten Exit-Status"
    # Abbruch mit Status 0 (bash 3.2: `set -u` in `f || true`) gilt trotzdem als Abbruch.
    expect_exact "record abbruch FEHLER Lauf abgebrochen (Exit 0);report|1" "$(
        stop_sampler() { :; }; clear_knobs() { :; }
        record() { printf 'record %s %s %s;' "$1" "$3" "$4"; }
        report() { printf 'report'; }
        cleanup_chats() { :; }
        ( RUN_STARTED=1 KEEP=1; true; on_fault_exit ); printf '|%s' "$?"
    )" "Abbruch mit Status 0 wird gemeldet, Exit 1"

    # await_pid liest auch nach Fristende noch einmal und wartet bei `resumed`
    # auf eine neue PID.
    expect_exact "$$" "$(SETTLE_SECONDS=0; chat_pid() { echo "$$"; }; await_pid x 1 either 0)" "Frist vorbei: trotzdem gelesen"
    expect_exact "$$" "$(SETTLE_SECONDS=0; chat_pid() { echo "$$"; }; await_pid x "$$" resumed 0)" "resumed ohne neue PID: alte gemeldet, judge sagt FEHLER"
    expect_exact "" "$(SETTLE_SECONDS=0; chat_pid() { echo 999999; }; await_pid x 1 same 0)" "Frist vorbei, tote PID: leer statt übernommen"

    # Signaturart aus codesign -dvv.
    expect_exact "adhoc" "$(signing_kind_from "$(printf 'Executable=/x\nSignature=adhoc\nTeamIdentifier=not set')")" "ad hoc erkannt"
    expect_exact "dev" "$(signing_kind_from "$(printf 'Signature size=1731\nAuthority=WhisperM8 Local Dev\nTeamIdentifier=not set')")" "Dev-Zertifikat erkannt"
    expect_exact "andere" "$(signing_kind_from "$(printf 'Authority=Developer ID Application: X\nAuthority=Apple Root CA')")" "fremde Signatur"
    expect_exact "-" "$(signing_identity adhoc)" "ad hoc signiert mit -"

    # Ordner des Aufbewahrers: Rechte, fremde Dateien, Geheimnis im Log.
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/soak-selftest.XXXXXX")
    mkdir "$dir/h" && chmod 700 "$dir/h"
    : > "$dir/h/keeper.lock"; : > "$dir/h/keeper.log"; : > "$dir/h/keeper.log.1"
    chmod 644 "$dir/h/keeper.log"
    expect_exact "" "$(handover_dir_issues "$dir/h")" "Rechte stimmen (Log aus Paket 2 darf 0644 sein)"
    expect_exact "" "$(unknown_handover_files "$dir/h")" "nur bekannte Dateien"
    expect_exact "" "$(handover_dir_issues "$dir/fehlt")" "kein Ordner, keine Abweichung"
    printf 'geheim-0123456789' > "$dir/h/secret"
    chmod 644 "$dir/h/secret"; chmod 755 "$dir/h"
    expect_exact "Ordner 755
Datei 644 secret" "$(handover_dir_issues "$dir/h")" "falsche Rechte gemeldet"
    expect_exact "secret" "$(unknown_handover_files "$dir/h")" "fremde Datei erkannt"
    capture_secret_candidates "$dir/h" "$dir/cand"
    printf 'nichts\n' > "$dir/sauber.log"
    printf 'x geheim-0123456789 y\n' > "$dir/roh.log"
    printf 'token=%s\n' "$(printf 'geheim-0123456789' | xxd -p | tr -d '\n')" > "$dir/hex.log"
    expect_exact "$dir/roh.log $dir/hex.log " "$(secret_hits "$dir/cand" "$dir/sauber.log" "$dir/roh.log" "$dir/hex.log" "$dir/fehlt.log" | tr '\n' ' ')" "Geheimnis roh und hex gefunden"
    printf 'kurz' > "$dir/h/secret"; : > "$dir/cand2"
    capture_secret_candidates "$dir/h" "$dir/cand2"
    expect_exact "" "$(printf 'kurz\n' > "$dir/k.log"; secret_hits "$dir/cand2" "$dir/k.log")" "unter 8 Byte kein Treffer"
    printf 'geheim-0123456789' > "$dir/h/secret"
    capture_secret_candidates "$dir/h" "$dir/cand3"; capture_secret_candidates "$dir/h" "$dir/cand3"
    expect_exact "1" "$(wc -l < "$dir/cand3" | tr -d ' ')" "Kandidat nur einmal gesichert"
    rm -f "$dir/h/secret"; : > "$dir/h/.versteckt"; : > "$dir/h/..doppel"
    expect_exact "..doppel .versteckt" "$(unknown_handover_files "$dir/h" | sort | tr '\n' ' ' | sed 's/ $//')" "versteckte Dateien erkannt"
    rm -rf "$dir"

    # Geheimnis-Muster im System-Log, Ausgabe gekürzt.
    expect_exact '2026-11-13 13:32:03.686 secret: "256d62…' "$(printf '%s\n' '2026-11-13 13:32:03.686 Df WhisperM8[1:2] [x] handover_take_plan plan=take(secret: "256d62b3860129aa5e2ef5c73d' | secret_pattern_hits)" "Geheimnis im Log erkannt, gekürzt"
    expect_exact "" "$(printf '%s\n' 'handover_take_plan plan=take secret=<redacted>' 'session=9D5AF90C-0A31-4E72-A8E8-09B1757C3284' | secret_pattern_hits)" "kein Fehlalarm ohne Hex-Wert"
    expect_exact 'secret: "256d62…' "$(printf '%s\n' '    take(secret: "256d62b3860129aa5e2ef5c73d1111")' | secret_pattern_hits)" "Folgezeile ohne Zeitstempel gekürzt"
    expect_exact '2026-11-13T13:32:03Z secret=256d62…' "$(printf '%s\n' '[2026-11-13T13:32:03Z] plan secret=256d62b3860129aa' | secret_pattern_hits)" "Zeitstempel in Klammern gekürzt"
    expect_exact 'secret=abcdef…' "$(printf '%s\n' 'x secret=abcdef1' | secret_pattern_hits)" "schon 7 Hex-Zeichen sind ein Treffer"
    expect_exact "" "$(printf '%s\n' 'x secret=abcdef' 'handover_secret_id=9D5AF90C-0A31-4E72-A8E8-09B1757C3284' | secret_pattern_hits)" "6 Hex-Zeichen und UUID neben secret ohne Fehlalarm"

    # Schlüsselbund-Wächter: nur neue SecurityAgent-Prozesse zählen.
    expect_exact "34" "$(printf '12\n34\n' | grep -vxF -f <(printf '12\n'))" "Vergleichsstand blendet Altes aus"
    expect_exact "12 34" "$(printf '12\n34\n' | grep -vxF -f /dev/null | tr '\n' ' ' | sed 's/ $//')" "leerer Vergleichsstand blendet nichts aus"

    # Ohne --signing und ohne erkannte Art kein Austausch.
    expect_exact "nein" "$(SIGNING=andere; has_signing && echo ja || echo nein)" "fremde Signatur: binary-swap fehlt"
    expect_exact "ja" "$(SIGNING=adhoc; has_signing && echo ja || echo nein)" "ad hoc braucht kein Zertifikat"

    if (( failures == 0 )); then echo "self-test: alles ok"; else echo "self-test: $failures Fehler"; return 1; fi
}

# MARK: - Aufruf

fault_main() {
    local cmd="${1:-}"
    # Log-Kopie und Geheimnis-Kandidaten im Zustandsordner nur für den Nutzer.
    umask 077
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only) ONLY="${2:?--only braucht ein Szenario}"; shift 2 ;;
            --signing) SIGNING="${2:?--signing braucht dev oder adhoc}"; shift 2 ;;
            --keep) KEEP=1; shift ;;
            --report) REPORT="${2:?--report braucht einen Pfad}"; shift 2 ;;
            --use-running) USE_RUNNING=1; shift ;;
            *) echo "unbekanntes Argument: $1" >&2; exit 64 ;;
        esac
    done
    [[ "$ROOT" == /* ]] || { echo "WHISPERM8_TEST_ROOT muss ein absoluter Pfad sein: $ROOT" >&2; exit 64; }
    [[ -z "$ONLY" ]] || validate_scenarios "$ONLY"
    [[ -z "$SIGNING" || "$SIGNING" == dev || "$SIGNING" == adhoc ]] || { echo "--signing: dev oder adhoc, nicht $SIGNING" >&2; exit 64; }
    case "$cmd" in
        capabilities) cmd_fault_capabilities ;;
        run) cmd_fault_run ;;
        self-test) cmd_fault_self_test ;;
        *) sed -n '2,10p' "$0"; exit 64 ;;
    esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    fault_main "$@"
fi
