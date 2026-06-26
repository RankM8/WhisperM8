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
# Ablauf (siehe Makefile): `swift build` generiert die Accessor, danach läuft
# dieses Skript (patcht + chmod 444), dann ein zweiter `swift build`. Der zweite
# Build überspringt "Write sources" für die schreibgeschützten Dateien, sodass
# die gepatchte Variante kompiliert und gelinkt wird.
#
# Usage: scripts/patch-resource-accessors.sh [release|debug]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"

found=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    found=1
    chmod u+w "$f"
    sed -i '' \
        's/Bundle\.main\.bundleURL\.appendingPathComponent/(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent/' \
        "$f"
    # Schreibschutz → der nächste `swift build` regeneriert die Datei NICHT.
    chmod 444 "$f"
    echo "  patched: $f"
done < <(find .build -path "*/${CONFIG}/*/DerivedSources/resource_bundle_accessor.swift" 2>/dev/null)

if [ "$found" -eq 0 ]; then
    echo "⚠️  Keine resource_bundle_accessor.swift für config '${CONFIG}' gefunden." >&2
fi
