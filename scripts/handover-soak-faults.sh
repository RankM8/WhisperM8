#!/usr/bin/env bash
# Fehler-Szenarien für „Neustart ohne Chatverlust“ — Abnahme der Rückfall-Wege.
# Nur gegen die Test-Instanz; nutzt die Prüf-Funktionen aus handover-soak.sh.
# Hintergrund: docs/plans/neustart-zweite-meinung.md (Risiko 3: die Rückfall-
# Wege sind die am wenigsten geübten und die gefährlichsten).
#
#   scripts/handover-soak-faults.sh capabilities              # was Paket 4 dafür schon liefert
#   scripts/handover-soak-faults.sh run [--only <szenario>]   # Szenarien fahren, Bericht
#            [--keep] [--report <datei>] [--use-running]
#   scripts/handover-soak-faults.sh self-test                 # Prüf-Funktionen ohne App
#
# Szenarien:
#   kill-mid-take    Aufbewahrer per SIGKILL mitten in der Übernahme
#   hold-deadline    keine neue App bis zur Haltefrist, danach Start
#   secret-missing   neue App findet kein Geheimnis
#   secret-wrong     neue App hat ein falsches Geheimnis
#   binary-swap      Programm unter dem laufenden Aufbewahrer ersetzt (wie make dev)
#   double-restart   zweimal Neustart hintereinander ohne Pause
#
# Prüfung jeweils: nie zwei Prozesse auf einer Sitzung (Wächter zweimal pro
# Sekunde während des ganzen Szenarios), jeder Chat kommt zurück (übernommen
# oder über den Rückfall fortgesetzt, je nach Szenario), keine Leichen (kein
# Aufbewahrer, kein Socket, kein Claude-Prozess ohne Chat).
#
# Ergebnis und Exit wie handover-soak.sh: OK, FEHLER, FEHLT; Exit 0/1/2/64.
set -euo pipefail

# shellcheck source=handover-soak.sh
source "$(cd "$(dirname "$0")" && pwd)/handover-soak.sh"

APP="$(cd "$(dirname "$BIN")/../.." 2>/dev/null && pwd || echo "$REPO/.build-test/WhisperM8Test.app")"
TEST_DOMAIN="com.whisperm8.app.test"
HANDOVER_DIR="$ROOT/home/Library/Application Support/WhisperM8/handover"
COMEBACK_TIMEOUT=120
SAMPLER_PID=""
ONLY=""
SCENARIOS="kill-mid-take hold-deadline secret-missing secret-wrong binary-swap double-restart"
KNOBS="handoverTakeDelayMs handoverHoldSeconds handoverSecretOverride"

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

# Aufbewahrer-Status (JSON von `app handover-status --json`): „pid anzahl“ oder leer.
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

# MARK: - Werkzeuge

keeper_status_json() {
    env -u WHISPERM8_SESSION_ID -u WHISPERM8_SESSION_TOKEN WHISPERM8_INSTANCE_ROOT="$ROOT" "$BIN" app handover-status --json 2>/dev/null || true
}

keeper_pids() { pgrep -f "handover-keeper --root $ROOT" 2>/dev/null || true; }

# Nur einen Aufbewahrer dieser Test-Wurzel töten, nie einen fremden Prozess.
kill_keeper() { # pid signal
    local command
    command=$(ps -ww -o command= -p "$1" 2>/dev/null || true)
    if [[ "$command" == *"handover-keeper --root $ROOT"* ]]; then
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

start_sampler() { # datei
    : > "$1"
    (
        while :; do
            violations_now "$(registry_pids "$ROOT/home/.claude/sessions" || true)" "$(date +%H:%M:%S)" >> "$1" || true
            sleep 0.5
        done
    ) &
    SAMPLER_PID=$!
}

stop_sampler() {
    if [[ -n "$SAMPLER_PID" ]]; then
        kill "$SAMPLER_PID" 2>/dev/null || true
        wait "$SAMPLER_PID" 2>/dev/null || true
        SAMPLER_PID=""
    fi
}

# Programm unter dem laufenden Aufbewahrer ersetzen, wie `make dev`: neue
# Build-Nummer, neu signiert mit demselben Zertifikat, per rsync (Umbenennen).
swap_bundle() { # build-nummer
    local work="$SOAK/swap" id
    rm -rf "$work"
    mkdir -p "$work"
    cp -R "$APP" "$work/"
    local copy="$work/$(basename "$APP")"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $1" "$copy/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $1" "$copy/Contents/Info.plist"
    id=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/WhisperM8 Local Dev/ {print $2; exit}' || true)
    codesign --force --deep --sign "$id" --entitlements "$REPO/WhisperM8/WhisperM8.entitlements" --timestamp=none "$copy" >/dev/null
    rsync -a --delete "$copy/" "$APP/"
    rm -rf "$work"
}

# MARK: - Gemeinsame Prüfungen je Szenario

chat_pids_now() {
    local name pids=""
    for name in $(chat_names); do pids="$pids $(chat_pid "$name")"; done
    echo "$pids"
}

# Wartet, bis jeder Chat wieder einen Prozess hat (oder die Frist abläuft),
# und bewertet jeden nach der Erwartung des Szenarios.
check_comeback() { # szenario vorher-datei erwartung
    local scenario="$1" before="$2" expect="$3" name pid_before pid_now old_alive end
    end=$(( $(date +%s) + COMEBACK_TIMEOUT ))
    while IFS=$'\t' read -r name pid_before; do
        pid_now=""
        while (( $(date +%s) < end )); do
            pid_now=$(chat_pid "$name")
            [[ -n "$pid_now" ]] && break
            sleep 2
        done
        old_alive=0
        if [[ -n "$pid_before" ]] && kill -0 "$pid_before" 2>/dev/null; then old_alive=1; fi
        if [[ -z "$pid_before" ]]; then
            record "$scenario" "zurueck:$name" FEHLT "PID vorher nicht ermittelbar"
        else
            record_verdict "$scenario" "zurueck:$name" "$(judge_comeback "$pid_before" "$pid_now" "$old_alive" "$expect")"
        fi
    done < "$before"
}

check_no_leftovers() { # szenario verletzungen-datei
    local scenario="$1" violations="$2" registry stray
    if [[ -s "$violations" ]]; then
        record "$scenario" zwei-prozesse FEHLER "$(head -3 "$violations" | tr '\n' ';')"
    else
        record "$scenario" zwei-prozesse OK "Wächter ohne Befund"
    fi
    if [[ -n "$(keeper_pids)" ]]; then
        record "$scenario" leichen:aufbewahrer FEHLER "läuft noch: $(keeper_pids | tr '\n' ' ')"
    elif [[ -e "$HANDOVER_DIR/keeper.sock" || -e "$HANDOVER_DIR/socket-path" ]]; then
        record "$scenario" leichen:aufbewahrer FEHLER "Socket oder Discovery-Datei liegt noch"
    else
        record "$scenario" leichen:aufbewahrer OK ""
    fi
    registry=$(registry_pids "$ROOT/home/.claude/sessions" || true)
    stray=$(orphans "$registry" "$(chat_pids_now)")
    if [[ -n "$stray" ]]; then
        record "$scenario" leichen:claude FEHLER "Prozesse ohne Chat: $(printf '%s' "$stray" | tr '\n' ' ')"
    else
        record "$scenario" leichen:claude OK ""
    fi
}

# Rahmen jedes Szenarios: Vorher-Stand, Wächter, Fehler auslösen, Prüfen.
run_scenario() { # name erwartung funktion
    local name="$1" expect="$2" action="$3"
    local before="$STATE/fault-$name-before.tsv" violations="$STATE/fault-$name-violations.log"
    log "Szenario $name"
    snapshot "$before"
    start_sampler "$violations"
    local ok=0
    "$action" "$name" && ok=1 || ok=0
    if (( ok )); then
        check_comeback "$name" "$before" "$expect"
    fi
    stop_sampler
    clear_knobs
    check_no_leftovers "$name" "$violations"
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

# MARK: - Szenarien

fault_kill_mid_take() { # szenario
    local scenario="$1" restart_pid summary keeper n seen=0 killed=0 end
    requires "$scenario" keep_chats knob:handoverTakeDelayMs || return 1
    set_knob handoverTakeDelayMs -int 3000
    ti restart --keep-chats > "$STATE/fault-$scenario-restart.log" 2>&1 &
    restart_pid=$!
    end=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < end )); do
        summary=$(keeper_status_json | keeper_summary)
        if [[ -n "$summary" ]]; then
            read -r keeper n _ <<< "$summary"
            if (( n > seen )); then seen=$n; fi
            # Mitten drin: mindestens einer schon übernommen, mindestens einer noch da.
            if (( seen > 1 && n >= 1 && n < seen )); then
                kill_keeper "$keeper" KILL && killed=1
                record "$scenario" ausgeloest OK "SIGKILL an $keeper nach $((seen - n)) von $seen Übernahmen"
                break
            fi
        fi
        sleep 0.2
    done
    wait "$restart_pid" 2>/dev/null || true
    if (( ! killed )); then
        record "$scenario" ausgeloest FEHLER "Zeitfenster mitten in der Übernahme nicht getroffen (gesehen: $seen Chats)"
    fi
    return 0
}

fault_hold_deadline() {
    local scenario="$1" summary keeper n old name pid
    requires "$scenario" handover_only knob:handoverHoldSeconds || return 1
    set_knob handoverHoldSeconds -int 20
    ti handover > "$STATE/fault-$scenario-handover.log" 2>&1
    summary=$(keeper_status_json | keeper_summary)
    if [[ -z "$summary" ]]; then
        record "$scenario" ausgeloest FEHLER "nach handover kein Aufbewahrer"
    else
        read -r keeper n _ <<< "$summary"
        record "$scenario" ausgeloest OK "Aufbewahrer $keeper hält $n Chats, Frist 20 s"
    fi
    sleep 30
    # Nach der Frist: geordnet beendet, kein alter Chat-Prozess lebt weiter.
    old=""
    while IFS=$'\t' read -r name pid; do
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && old="$old $name:$pid"
    done < "$STATE/fault-$scenario-before.tsv"
    if [[ -n "$old" ]]; then record "$scenario" frist-beendet FEHLER "leben nach der Frist noch:$old"
    else record "$scenario" frist-beendet OK ""; fi
    ti start > "$STATE/fault-$scenario-start.log" 2>&1
    return 0
}

fault_secret() { # szenario wert
    local scenario="$1" value="$2" end gone=0
    requires "$scenario" keep_chats knob:handoverSecretOverride || return 1
    set_knob handoverSecretOverride -string "$value"
    ti restart --keep-chats > "$STATE/fault-$scenario-restart.log" 2>&1 || true
    record "$scenario" ausgeloest OK "Geheimnis: $value"
    # Ohne Geheimnis darf der Aufbewahrer nicht bis zur Frist (10 min) halten:
    # Die App beendet ihn über die PID aus STATUS.
    end=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < end )); do
        [[ -z "$(keeper_pids)" ]] && { gone=1; break; }
        sleep 1
    done
    if (( gone )); then record "$scenario" aufbewahrer-beendet OK ""
    else record "$scenario" aufbewahrer-beendet FEHLER "hält nach 30 s noch (wartet er auf die Frist?)"; fi
    return 0
}
fault_secret_missing() { fault_secret "$1" missing; }
fault_secret_wrong() { fault_secret "$1" wrong; }

fault_binary_swap() {
    local scenario="$1" build
    requires "$scenario" handover_only codesign_identity || return 1
    ti handover > "$STATE/fault-$scenario-handover.log" 2>&1
    build="soak-$(date +%s)"
    swap_bundle "$build"
    record "$scenario" ausgeloest OK "Bundle ersetzt (CFBundleVersion $build), Aufbewahrer läuft aus dem alten Programm"
    ti start > "$STATE/fault-$scenario-start.log" 2>&1
    return 0
}

fault_double_restart() {
    local scenario="$1"
    requires "$scenario" keep_chats || return 1
    ti restart --keep-chats > "$STATE/fault-$scenario-1.log" 2>&1 || true
    ti restart --keep-chats > "$STATE/fault-$scenario-2.log" 2>&1 || true
    record "$scenario" ausgeloest OK "zwei Neustarts direkt nacheinander"
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

wait_until_running() {
    local end name missing
    end=$(( $(date +%s) + COMEBACK_TIMEOUT ))
    while (( $(date +%s) < end )); do
        missing=""
        for name in $(chat_names); do [[ -n "$(chat_pid "$name")" ]] || missing="$missing $name"; done
        [[ -z "$missing" ]] && return 0
        sleep 2
    done
    record setup laufen FEHLER "ohne Prozess:$missing"
    return 1
}

on_fault_exit() {
    stop_sampler
    clear_knobs
    on_exit
}

cmd_fault_run() {
    local list="${ONLY:-$SCENARIOS}" scenario
    for scenario in $list; do
        [[ " $SCENARIOS " == *" $scenario "* ]] || { echo "unbekanntes Szenario: $scenario" >&2; exit 64; }
    done
    ROUNDS=$(echo "$list" | wc -w | tr -d ' ')
    prepare_instance
    RUN_STARTED=1
    trap on_fault_exit EXIT
    date '+%Y-%m-%d %H:%M:%S' > "$STATE/started-at"
    clear_knobs
    setup_chats
    if ! has_chat_start || ! wait_until_running; then
        for scenario in $list; do
            record "$scenario" voraussetzung FEHLT "Chats laufen nicht (Chat-Start ohne Anzeige fehlt)"
        done
    else
        for scenario in $list; do
            run_scenario "$scenario" "$(scenario_expectation "$scenario")" "$(scenario_function "$scenario")"
            wait_until_running || { record "$scenario" weiter FEHLER "Chats nicht zurück, Rest abgebrochen"; break; }
        done
    fi
    (( KEEP )) || cleanup_chats
    stop_sampler
    clear_knobs
    RUN_STARTED=0
    local status=0
    report || status=$?
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

    expect_exact "4242 2 holding" "$(printf '%s' '{"active": true, "keeper": {"pid": 4242, "phase": "holding", "chats": [{}, {}]}}' | keeper_summary)" "Aufbewahrer-Status gelesen"
    expect_exact "" "$(printf '%s' '{"active": false}' | keeper_summary)" "kein Aufbewahrer"
    expect_exact "" "$(printf '%s' 'kaputt' | keeper_summary)" "kaputtes JSON"

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

    if (( failures == 0 )); then echo "self-test: alles ok"; else echo "self-test: $failures Fehler"; return 1; fi
}

# MARK: - Aufruf

fault_main() {
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only) ONLY="${2:?--only braucht ein Szenario}"; shift 2 ;;
            --keep) KEEP=1; shift ;;
            --report) REPORT="${2:?--report braucht einen Pfad}"; shift 2 ;;
            --use-running) USE_RUNNING=1; shift ;;
            *) echo "unbekanntes Argument: $1" >&2; exit 64 ;;
        esac
    done
    [[ "$ROOT" == /* ]] || { echo "WHISPERM8_TEST_ROOT muss ein absoluter Pfad sein: $ROOT" >&2; exit 64; }
    case "$cmd" in
        capabilities) cmd_fault_capabilities ;;
        run) cmd_fault_run ;;
        self-test) cmd_fault_self_test ;;
        *) sed -n '2,10p' "$0"; exit 64 ;;
    esac
}

fault_main "$@"
