#!/usr/bin/env bash
# Lastgenerator für die Performance-Baseline (Paket A4).
#
# Erzeugt reproduzierbaren Terminal-Output mit definierter Datenrate und einem
# festen Anteil ANSI-/TUI-Sequenzen. Ohne so etwas ist keine Messung
# wiederholbar: „gefühlt viel Output" ist keine Größe, gegen die man optimieren
# kann.
#
# Das Skript wird IN einem Agent-Chat-Terminal ausgeführt, nicht daneben —
# nur so läuft die Last durch dieselbe PTY-Kette wie echter Agenten-Output.
#
# Verwendung (in je einem Chat pro Pane starten):
#   scripts/perf-load.sh                # 60 s, 64 KiB/s, 20 % Sequenzen
#   scripts/perf-load.sh 30 128         # 30 s, 128 KiB/s
#   scripts/perf-load.sh 10 1024 burst  # 10 s Dauerfeuer, ~1 MiB/s
#
# Messung nebenher mitschreiben:
#   log stream --predicate 'subsystem == "com.whisperm8.app" AND category == "AgentPerformance"'
#
# Vorher einschalten (App-Neustart nötig, Default ist aus):
#   defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES

set -euo pipefail

DURATION="${1:-60}"        # Sekunden
RATE_KIB="${2:-64}"        # KiB pro Sekunde
MODE="${3:-normal}"        # normal | burst | quiet

# Anteil Zeilen mit ANSI-Sequenzen (Farben, Cursorbewegung) — echter
# TUI-Output besteht nicht aus reinem Text, und die Sequenzen sind es, die den
# Parser beschäftigen.
ANSI_SHARE=20

# Eine Zeile ist ~80 Zeichen; daraus die Zeilen pro Sekunde für die Zielrate.
BYTES_PER_LINE=80
LINES_PER_SEC=$(( RATE_KIB * 1024 / BYTES_PER_LINE ))
# In Schüben von 50 ms ausgeben, sonst dominiert der Aufruf-Overhead die Rate.
CHUNKS_PER_SEC=20
LINES_PER_CHUNK=$(( LINES_PER_SEC / CHUNKS_PER_SEC ))
[ "$LINES_PER_CHUNK" -lt 1 ] && LINES_PER_CHUNK=1

if [ "$MODE" = "burst" ]; then
    # Dauerfeuer ohne Pausen — der Härtefall, an dem sich zeigt, ob die
    # Bündelung greift oder das Fenster stehenbleibt.
    CHUNKS_PER_SEC=0
fi

echo "── Lastgenerator ───────────────────────────────"
echo "   Dauer:    ${DURATION}s"
echo "   Rate:     ${RATE_KIB} KiB/s  (~${LINES_PER_SEC} Zeilen/s)"
echo "   Modus:    ${MODE}"
echo "   Sequenzen: ${ANSI_SHARE} %"
echo "   Start:    $(date '+%H:%M:%S')"
echo "────────────────────────────────────────────────"

END=$(( $(date +%s) + DURATION ))
LINE=0

while [ "$(date +%s)" -lt "$END" ]; do
    for _ in $(seq 1 "$LINES_PER_CHUNK"); do
        LINE=$(( LINE + 1 ))
        if [ $(( LINE % 100 )) -lt "$ANSI_SHARE" ]; then
            # Farbwechsel + Cursor-Spalte: beschäftigt den Sequenz-Parser.
            printf '\033[1;3%dm[%06d]\033[0m \033[38;5;%dm%s\033[0m\n' \
                $(( LINE % 8 )) "$LINE" $(( LINE % 256 )) \
                "Zeile mit Sequenzen — Fuellung bis auf Zeilenlaenge xxxxxxxxxxxxxx"
        else
            printf '[%06d] Reiner Text ohne Sequenzen — Fuellung bis auf Zeilenlaenge xxxxxxx\n' "$LINE"
        fi
    done
    if [ "$CHUNKS_PER_SEC" -gt 0 ]; then
        # 1/20 Sekunde Pause zwischen den Schüben.
        perl -e 'select(undef,undef,undef,0.05)'
    fi
done

ELAPSED=$(( $(date +%s) - (END - DURATION) ))
[ "$ELAPSED" -lt 1 ] && ELAPSED=1
ACTUAL_KIB=$(( LINE * BYTES_PER_LINE / ELAPSED / 1024 ))

echo "────────────────────────────────────────────────"
echo "   Fertig:   $LINE Zeilen in ${ELAPSED}s, Ende $(date '+%H:%M:%S')"
# Die ERREICHTE Rate ist die, gegen die gemessen wird — die Zielrate oben wird
# vom Shell-Overhead (ein printf je Zeile) regelmäßig unterschritten. Wer die
# Zielrate protokolliert statt dieser Zahl, vergleicht später Äpfel mit Birnen.
echo "   Erreicht: ~${ACTUAL_KIB} KiB/s  ($(( LINE / ELAPSED )) Zeilen/s) ← diese Zahl protokollieren"
