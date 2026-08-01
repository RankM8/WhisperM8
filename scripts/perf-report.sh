#!/usr/bin/env bash
# Wertet die Performance-Logs zu einer Baseline-Tabelle aus (Paket A4).
#
# Liest das unified log der App und fasst zusammen, was in einem Zeitraum
# passiert ist: Stillstände des Main Threads, gerissene Budgets, Ereigniszähler.
#
# Verwendung:
#   scripts/perf-report.sh              # letzte 10 Minuten
#   scripts/perf-report.sh 30m
#   scripts/perf-report.sh 2h
#
# Sinnvoll direkt nach einem Lauf von scripts/perf-load.sh.

set -euo pipefail

WINDOW="${1:-10m}"
PRED='subsystem == "com.whisperm8.app" AND category == "AgentPerformance"'
RAW="$(/usr/bin/log show --last "$WINDOW" --info --predicate "$PRED" 2>/dev/null || true)"

if [ -z "$RAW" ]; then
    echo "Keine Log-Einträge in den letzten $WINDOW gefunden."
    echo "Läuft die App? Wurde sie seit dem letzten Build neu gestartet?"
    exit 1
fi

line() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

echo
echo "  BASELINE — letzte $WINDOW"
line

# ── Stillstände: das, was ein Nutzer tatsächlich spürt ────────────────────
echo
echo "  Main-Thread-Stillstände"
FREEZES="$(printf '%s\n' "$RAW" | grep -c "main_thread_freeze" || true)"
if [ "$FREEZES" -gt 0 ]; then
    echo "    Einfrieren (>1 s):  $FREEZES"
    printf '%s\n' "$RAW" | grep "main_thread_freeze" \
        | grep -oE "durationMs=[0-9]+" | sort -t= -k2 -rn | head -5 \
        | sed 's/durationMs=/      längstes: /;s/$/ ms/'
else
    echo "    Einfrieren (>1 s):  keine"
fi
printf '%s\n' "$RAW" | grep "main_thread_stalls" | tail -3 \
    | grep -oE "count=[0-9]+ worstMs=[0-9]+" | sed 's/^/    Fenster: /' || true

# ── Gerissene Budgets, nach Häufigkeit ────────────────────────────────────
echo
echo "  Gerissene Budgets (Anzahl · schlechtester Wert)"
printf '%s\n' "$RAW" | grep -oE "name=[a-zA-Z.]+ durationMs=[0-9]+ budgetMs=[0-9]+" \
    | awk '{
        split($1,n,"="); split($2,d,"="); split($3,b,"=");
        count[n[2]]++; if (d[2]+0 > worst[n[2]]+0) worst[n[2]]=d[2]; budget[n[2]]=b[2];
      }
      END {
        for (k in count)
            printf "    %-28s %5d ×   bis %5d ms   (Budget %d ms)\n", k, count[k], worst[k], budget[k]
      }' | sort -k2 -rn || echo "    keine"

# ── Ereigniszähler (nur bei aktiver Detail-Stufe) ─────────────────────────
echo
echo "  Ereigniszähler"
COUNTERS="$(printf '%s\n' "$RAW" | grep "perf_counters " | tail -5 || true)"
if [ -z "$COUNTERS" ]; then
    echo "    keine — Detail-Stufe ist aus."
    echo "    defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES"
    echo "    (danach App neu starten)"
else
    printf '%s\n' "$COUNTERS" | sed 's/.*perf_counters /    /'
    echo
    echo "    Chunks vs. Flushes zeigt, wie stark die Bündelung greift."
    echo "    pane.mounted ohne neu geöffnete Chats = unerwünschter Wiederaufbau."
fi

# ── Terminal-Renderer ─────────────────────────────────────────────────────
echo
echo "  Terminal-Renderer"
if printf '%s\n' "$RAW" | grep -q "terminal_metal_renderer_enabled"; then
    echo "    Metal: aktiv"
    printf '%s\n' "$RAW" | grep -oE "terminal_metal_warmup_done ms=[0-9]+" | tail -1 | sed 's/^/    /'
else
    echo "    Metal: aus (CPU-Darstellung)"
fi

echo
line
echo "  Vergleichbar wird das erst mit protokollierter Last:"
echo "  Panes, erreichte KiB/s aus perf-load.sh, Modus."
echo
