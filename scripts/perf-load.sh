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
#   scripts/perf-load.sh                # 60 s, 64 KiB/s
#   scripts/perf-load.sh 30 128         # 30 s, 128 KiB/s
#   scripts/perf-load.sh 10 1024 burst  # 10 s ohne Drosselung, so schnell es geht
#
# Messung nebenher mitschreiben:
#   log stream --predicate 'subsystem == "com.whisperm8.app" AND category == "AgentPerformance"'
#
# Detail-Stufe vorher einschalten (App-Neustart nötig, Default ist aus):
#   defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES
#
# ── Warum der Kern in Perl steckt ────────────────────────────────────────────
# Ein Lastgenerator, der selbst CPU frisst, verfälscht genau die Messung, für
# die er da ist. Eine reine Bash-Fassung braucht pro Takt mehrere externe
# Prozesse (Zeit lesen, rechnen, schlafen) — bei 20 Takten pro Sekunde über
# hundert Prozessstarts. Deshalb läuft der getaktete Ausgabe-Loop in EINEM
# langlebigen Perl-Prozess, der die monotone Uhr benutzt und selbst schläft.
# Bash macht nur Eingabeprüfung und Ausgabe der Kopf-/Fußzeilen.

set -euo pipefail
export LC_ALL=C

DURATION="${1:-60}"        # Sekunden
RATE_KIB="${2:-64}"        # KiB pro Sekunde
MODE="${3:-normal}"        # normal | burst

# Eingaben streng prüfen, BEVOR sie irgendwo ausgewertet werden. Bash wertet in
# $(( … )) Command-Substitutions aus — ein Argument wie 'x[$(…)]' würde sonst
# ausgeführt. Das Skript startet zwar von Hand, aber ein Messwerkzeug darf bei
# krummer Eingabe nichts Überraschendes tun.
if ! [[ "$DURATION" =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "Fehler: Dauer muss 1 bis 9999 Sekunden sein (war: '$DURATION')" >&2
    exit 1
fi
# Obergrenze mit Absicht niedrig: 4 MiB/s pro Pane ist bereits weit jenseits
# dessen, was ein Agent erzeugt. Höhere Werte bauen einen Block von hunderten
# MB im Speicher auf und machen das Terminal unbrauchbar.
if ! [[ "$RATE_KIB" =~ ^[1-9][0-9]{0,3}$ ]] || [ "$RATE_KIB" -gt 4096 ]; then
    echo "Fehler: Rate muss 1 bis 4096 KiB/s sein (war: '$RATE_KIB')" >&2
    exit 1
fi
case "$MODE" in
    normal|burst) ;;
    *) echo "Fehler: Modus muss 'normal' oder 'burst' sein (war: '$MODE')" >&2; exit 1 ;;
esac

echo "── Lastgenerator ───────────────────────────────"
echo "   Dauer:     ${DURATION}s"
echo "   Ziel:      ${RATE_KIB} KiB/s"
echo "   Modus:     ${MODE}"
echo "   Start:     $(date '+%H:%M:%S')"
echo "────────────────────────────────────────────────"

DURATION="$DURATION" RATE_KIB="$RATE_KIB" MODE="$MODE" perl -MTime::HiRes= -e '
    use strict;
    use warnings;
    use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

    my $duration = $ENV{DURATION};
    my $rate_kib = $ENV{RATE_KIB};
    my $burst    = ($ENV{MODE} // "normal") eq "burst";

    my $ansi_every    = 5;      # jede 5. Zeile mit Sequenzen
    my $bytes_est     = 83;     # nur zur Blockgröße; gezählt wird echt
    my $ticks_per_sec = 20;
    my $tick          = 1 / $ticks_per_sec;

    my $lines_per_chunk = int($rate_kib * 1024 / $bytes_est / $ticks_per_sec);
    $lines_per_chunk = 1 if $lines_per_chunk < 1;

    # Block EINMAL vorbauen — nicht pro Zeile formatieren.
    my $chunk = "";
    for my $i (1 .. $lines_per_chunk) {
        if ($i % $ansi_every == 0) {
            $chunk .= sprintf("\033[1;3%dm[%06d]\033[0m \033[38;5;%dm%s\033[0m\n",
                $i % 8, $i, $i % 256,
                "Zeile mit Sequenzen — Fuellung bis auf Zeilenlaenge xxxxxxxxxxxxxx");
        } else {
            $chunk .= sprintf("[%06d] Reiner Text ohne Sequenzen — Fuellung bis auf Zeilenlaenge xxxxxxx\n", $i);
        }
    }
    my $chunk_bytes = length($chunk);

    printf("   Block:     %d Zeilen à ~%d B, jede %d. mit Sequenzen\n",
        $lines_per_chunk, $chunk_bytes / $lines_per_chunk, $ansi_every);

    $| = 1;
    # CLOCK_MONOTONIC, nicht die Wanduhr: eine Zeitumstellung oder ein
    # NTP-Sprung mitten im Lauf darf die Messung nicht verfälschen.
    my $start    = clock_gettime(CLOCK_MONOTONIC);
    my $deadline = $start + $duration;
    my $next     = $start;
    my ($total_bytes, $chunks) = (0, 0);

    while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
        print $chunk;
        $total_bytes += $chunk_bytes;
        $chunks++;

        next if $burst;
        # Deadline-getaktet statt „nach der Arbeit 50 ms schlafen": sonst
        # addiert sich die Ausgabezeit auf und die Rate driftet nach unten.
        $next += $tick;
        my $rest = $next - clock_gettime(CLOCK_MONOTONIC);
        sleep($rest) if $rest > 0;
    }

    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $start;
    printf("────────────────────────────────────────────────\n");
    printf("   Fertig:    %d Blöcke, %d Bytes in %.3fs\n", $chunks, $total_bytes, $elapsed);
    # Die ERREICHTE Rate ist die, gegen die gemessen wird — aus tatsächlich
    # geschriebenen Bytes und monoton gemessener Zeit, nicht geschätzt. Wer
    # stattdessen die Zielrate protokolliert, vergleicht später Äpfel mit Birnen.
    printf("   Erreicht:  %.1f KiB/s  ← diese Zahl protokollieren\n",
        $total_bytes / 1024 / $elapsed);
'

echo "   Ende:      $(date '+%H:%M:%S')"
