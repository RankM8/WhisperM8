#!/usr/bin/env bash
# Patch SwiftPM-generierte resource_bundle_accessor.swift, damit `Bundle.module`
# Ressourcen in Contents/Resources eines .app findet.
#
# Problem: Diese Toolchain generiert einen Accessor, der das Resource-Bundle nur
# unter `Bundle.main.bundleURL/<name>.bundle` (= .app-WURZEL) plus einem
# hartkodierten Build-Pfad sucht. In einer signierten .app dürfen aber keine
# losen Bundles an der Wurzel liegen (codesign: "unsealed contents present in the
# bundle root"), also liegen sie in Contents/Resources — wo der Accessor nicht
# schaut. Auf dem Build-Rechner rettet nur zufällig der hartkodierte Pfad; auf
# fremden Macs (DMG/Homebrew) crasht KeyboardShortcuts/SwiftTerm/... mit
# fatalError "could not load resource bundle".
#
# Fix: `Bundle.main.bundleURL` → `(Bundle.main.resourceURL ?? Bundle.main.bundleURL)`.
# resourceURL == Contents/Resources im .app (wo die Bundles liegen) und == bundleURL
# bei nackten Executables (.build) — funktioniert also in beiden Fällen.
#
# Ablauf (siehe Makefile): `swift build` generiert die Accessors, danach läuft
# dieses Skript. Bereits gepatchte Dateien (schreibgeschützt 444 vom letzten
# Lauf — SwiftPM überspringt "Write sources" für read-only Dateien) werden
# übersprungen; nur frisch generierte werden gepatcht + auf 444 gesetzt. Das
# Makefile führt den zweiten `swift build` NUR bei Exit 3 aus — im Normalfall
# (alles schon gepatcht) entfällt er komplett. Nach `make clean` oder einem
# Toolchain-Wechsel greift automatisch wieder der volle Patch+Rebuild-Pfad.
#
# Usage: scripts/patch-resource-accessors.sh [release|debug]   (default: release)
#
# Exit-Codes (fürs Makefile):
#   0 — alle Accessors bereits gepatcht, kein Rebuild nötig
#   3 — mindestens ein Accessor frisch gepatcht → zweiter `swift build` nötig
#   1 — keine Accessors gefunden oder Patch nicht anwendbar (Fehler)

set -euo pipefail

CONFIG="${1:-release}"

# Unabhängig vom Aufrufverzeichnis auf dem Repo-Root arbeiten.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

PATCHED_MARKER='(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent'

found=0
changed=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    found=1
    if grep -Fq "$PATCHED_MARKER" "$f"; then
        # Bereits gepatcht (444 vom letzten Lauf) — nichts zu tun.
        continue
    fi
    chmod u+w "$f"
    sed -i '' \
        's/Bundle\.main\.bundleURL\.appendingPathComponent/(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent/' \
        "$f"
    if ! grep -Fq "$PATCHED_MARKER" "$f"; then
        echo "❌ Patch nicht anwendbar: $f — Accessor-Template geändert? (sed-Muster prüfen)" >&2
        exit 1
    fi
    # Schreibschutz → der nächste `swift build` regeneriert die Datei NICHT.
    chmod 444 "$f"
    changed=1
    echo "  patched: $f"
done < <(find .build -path "*/${CONFIG}/*/DerivedSources/resource_bundle_accessor.swift" 2>/dev/null)

if [ "$found" -eq 0 ]; then
    echo "❌ Keine resource_bundle_accessor.swift für config '${CONFIG}' gefunden — ohne Patch crasht die App auf fremden Macs (DMG/Homebrew)." >&2
    exit 1
fi

if [ "$changed" -eq 1 ]; then
    exit 3
fi
echo "  Accessors bereits gepatcht — kein Rebuild nötig."
exit 0
