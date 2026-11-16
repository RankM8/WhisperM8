#!/bin/bash
# Wartet, bis auf dem Rechner kein Bau und kein Testlauf mehr läuft.
#
# Auf einem Rechner, an dem mehrere Chats bauen, reicht der Arbeitsspeicher
# nur für einen `swift build` oder `swift test` zur selben Zeit. Ein Testlauf
# trägt je nach Toolchain verschiedene Prozessnamen: `swift-test` ist bei
# Xcode nur ein Verweis auf `swift-package`, die Tests selbst laufen in
# `xctest`. Geprüft wird nur der Prozessname (`pgrep -x`), nie die
# Befehlszeile: `pgrep -f` träfe die eigene Shell.
#
#   scripts/wait-for-build-slot.sh && swift build
#   scripts/wait-for-build-slot.sh --timeout 1200 && swift test --filter …
#
# Exit 0: frei. Exit 1: nach der Frist (Standard 600 s) noch belegt; dann
# nicht trotzdem bauen, sondern Bescheid geben. Beendet nie fremde Läufe.

set -u

NAMES=(swift-build swift-test swift-package xctest)
TIMEOUT=600
INTERVAL=15

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="${2:?--timeout braucht Sekunden}"; shift 2 ;;
        --interval) INTERVAL="${2:?--interval braucht Sekunden}"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    esac
done

busy() {
    local found=()
    for name in "${NAMES[@]}"; do
        if pgrep -x "$name" >/dev/null 2>&1; then found+=("$name"); fi
    done
    if [ ${#found[@]} -gt 0 ]; then
        echo "${found[*]}"
        return 0
    fi
    return 1
}

start=$(date +%s)
announced=""
while running=$(busy); do
    waited=$(( $(date +%s) - start ))
    if [ "$waited" -ge "$TIMEOUT" ]; then
        echo "Nach ${waited} s läuft noch: ${running}. Nicht bauen, Bescheid geben." >&2
        exit 1
    fi
    if [ "$running" != "$announced" ]; then
        echo "Warte, es läuft: ${running}" >&2
        announced="$running"
    fi
    sleep "$INTERVAL"
done
[ -n "$announced" ] && echo "Frei." >&2
exit 0
