#!/usr/bin/env bash
# Wertet die Performance-Logs zu einer Baseline-Tabelle aus (Paket A4).
#
# Verwendung:
#   scripts/perf-report.sh              # letzte 10 Minuten
#   scripts/perf-report.sh 30m
#   scripts/perf-report.sh 2h
#   scripts/perf-report.sh 30m xctest   # statt der App die Testläufe auswerten
#
# Sinnvoll direkt nach einem Lauf von scripts/perf-load.sh.

set -euo pipefail
export LC_ALL=C

WINDOW="${1:-10m}"
PROCESS="${2:-WhisperM8}"

if ! [[ "$WINDOW" =~ ^[1-9][0-9]{0,4}[smhd]$ ]]; then
    echo "Fehler: Zeitfenster muss die Form 10m, 2h, 1d haben (war: '$WINDOW')" >&2
    exit 1
fi

# Der Prozessfilter ist NICHT optional-hübsch, sondern notwendig: `swift test`
# schreibt über denselben Logger in dasselbe Subsystem. Ohne ihn landen
# Messwerte aus Unit-Tests in der App-Baseline — nachgewiesen für store.mutate
# und store.load, deren Spitzenwerte vollständig aus xctest stammten. Eine
# Baseline, die Testläufe mitzählt, ist keine.
PRED="subsystem == \"com.whisperm8.app\" AND category == \"AgentPerformance\" AND process == \"$PROCESS\""

set +e
RAW="$(/usr/bin/log show --last "$WINDOW" --info --predicate "$PRED" 2>&1)"
LOG_STATUS=$?
set -e

if [ "$LOG_STATUS" -ne 0 ]; then
    echo "Fehler: 'log show' fehlgeschlagen (Status $LOG_STATUS):" >&2
    printf '%s\n' "$RAW" | head -3 >&2
    exit 1
fi

# `log show` gibt IMMER eine Kopfzeile aus („Timestamp Thread Type …"), auch
# ohne einen einzigen Treffer. Ein Test auf „RAW ist leer" schlägt deshalb nie
# an — das Skript meldete dann „keine Verletzungen, Metal aus" und sah aus wie
# ein sauberes Ergebnis, obwohl gar keine Daten vorlagen. Deshalb: Kopf- und
# Fußzeilen entfernen und erst danach auf Leere prüfen.
BODY="$(printf '%s\n' "$RAW" | grep -E "com.whisperm8.app:AgentPerformance" || true)"

if [ -z "$BODY" ]; then
    echo
    echo "  Keine Messdaten für Prozess '$PROCESS' in den letzten $WINDOW."
    echo
    echo "  Mögliche Gründe:"
    echo "    · Die App läuft nicht oder wurde seit dem Build nicht neu gestartet."
    echo "    · Das Zeitfenster liegt vor dem App-Start."
    echo "    · Falscher Prozessname — verfügbare Prozesse in diesem Fenster:"
    /usr/bin/log show --last "$WINDOW" --info \
        --predicate 'subsystem == "com.whisperm8.app"' 2>/dev/null \
        | grep -oE "^[0-9-]+ [0-9:.+]+ +0x[a-f0-9]+ +[A-Za-z]+ +0x[0-9a-f]+ +[0-9]+ +[0-9]+ +[A-Za-z0-9_.-]+:" \
        | awk '{print $NF}' | sort -u | sed 's/:$//;s/^/        /' | head -5
    exit 1
fi

line() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

echo
echo "  BASELINE — letzte $WINDOW · Prozess $PROCESS"
line

# ── Stillstände: das, was ein Nutzer tatsächlich spürt ────────────────────
echo
echo "  Main-Thread-Stillstände"
FREEZES="$(grep -c "main_thread_freeze" <<<"$BODY" || true)"
if [ "${FREEZES:-0}" -gt 0 ]; then
    echo "    Einfrieren (>1 s):  $FREEZES"
    { grep "main_thread_freeze" <<<"$BODY" || true; } \
        | grep -oE "durationMs=[0-9]+" | sort -t= -k2 -rn | head -5 \
        | sed 's/durationMs=/      /;s/$/ ms/' || true
else
    echo "    Einfrieren (>1 s):  keine"
fi
SUMMARIES="$({ grep "main_thread_stalls" <<<"$BODY" || true; } | tail -3)"
if [ -n "$SUMMARIES" ]; then
    echo "    Letzte Minuten-Zusammenfassungen:"
    grep -oE "count=[0-9]+ worstMs=[0-9]+" <<<"$SUMMARIES" | sed 's/^/      /' || true
else
    echo "    Keine Zusammenfassungen — läuft der Wächter? (ab Build vom 01.08.2026)"
fi

# ── Gerissene Budgets, nach Häufigkeit ────────────────────────────────────
echo
echo "  Gerissene Budgets (nur Überschreitungen — was knapp unter Budget"
echo "  bleibt, taucht hier nie auf)"
BUDGETS="$(grep -oE "name=[a-zA-Z.]+ durationMs=[0-9]+ budgetMs=[0-9]+" <<<"$BODY" || true)"
if [ -n "$BUDGETS" ]; then
    awk '{
        split($1,n,"="); split($2,d,"="); split($3,b,"=");
        count[n[2]]++; if (d[2]+0 > worst[n[2]]+0) worst[n[2]]=d[2]; budget[n[2]]=b[2];
      }
      END {
        for (k in count)
            printf "    %-30s %5d ×   bis %6d ms   (Budget %d ms)\n", k, count[k], worst[k], budget[k]
      }' <<<"$BUDGETS" | sort -k2 -rn
else
    echo "    keine"
fi

# ── Ereigniszähler (nur bei aktiver Detail-Stufe) ─────────────────────────
echo
echo "  Ereigniszähler"
COUNTERS="$({ grep "perf_counters " <<<"$BODY" || true; } | tail -5)"
if [ -z "$COUNTERS" ]; then
    echo "    keine — Detail-Stufe ist aus."
    echo "    defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES"
    echo "    (danach App neu starten)"
else
    echo "    Die letzten 5 Sekunden-Stichproben (NICHT das ganze Fenster):"
    sed 's/.*perf_counters /      /' <<<"$COUNTERS"
    echo
    echo "    Chunks vs. Flushes zeigt, wie stark die Bündelung greift."
    echo "    pane.mounted ohne neu geöffnete Chats = unerwünschter Wiederaufbau."
fi

# ── Terminal-Renderer ─────────────────────────────────────────────────────
echo
echo "  Terminal-Renderer"
# Aus den Defaults lesen, nicht aus Ereignissen: die Aktivierung wird einmal
# beim Öffnen des ersten Terminals geloggt und liegt bei längeren Laufzeiten
# außerhalb des Fensters. Ein „aus" aus fehlendem Ereignis wäre schlicht falsch.
METAL="$(defaults read com.whisperm8.app agentTerminalMetalEnabled 2>/dev/null || echo "unset")"
case "$METAL" in
    1) echo "    Metal: eingeschaltet (per defaults)" ;;
    0) echo "    Metal: ausgeschaltet (per defaults)" ;;
    *) echo "    Metal: aus (Vorgabewert, nicht gesetzt)" ;;
esac
{ grep -oE "terminal_metal_warmup_done ms=[0-9]+" <<<"$BODY" || true; } | tail -1 | sed 's/^/    /'

echo
line
echo "  Vergleichbar wird das erst mit protokollierter Last:"
echo "  Panes, erreichte KiB/s aus perf-load.sh, Modus."
echo
