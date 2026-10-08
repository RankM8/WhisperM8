---
status: Stufe 1 umgesetzt (UI-Snapshots); Stufe 2 (Debug-Steuerkanal) folgt
stand: 2026-10-08
feature: UI-Tests ohne Computer Use
---

# UI-Tests ohne Computer Use

Native SwiftUI-Apps haben kein Playwright. Damit Ansichten trotzdem ohne
Klick-Automation und ohne Bildschirmzugriff prüfbar sind, gibt es zwei Bausteine:

| Stufe | Was | Wofür |
|---|---|---|
| 1 | **UI-Snapshots**: Ansichten in festen Zuständen als PNG | Layout, Texte, Zustände, Hell/Dunkel |
| 2 | **Debug-Steuerkanal** (folgt) | Zustand auslesen, Fenster öffnen und fotografieren, Diktat mit Audiodatei |

Klick-Automation über die Bedienungshilfen (XCUITest o. ä.) ist bewusst nicht
gebaut: SwiftPM kann keine UI-Test-Bundles bauen, die App hat keine
`accessibilityIdentifier`, eine zweite isolierte Instanz fehlt, und die
Automation würde Fokus und Tastatur des Nutzers übernehmen.

## Stufe 1: UI-Snapshots

```bash
make snapshots                   # alle Fixtures → .build/ui-snapshots/<zeit>/
make snapshots ONLY=chatgpt      # nur Fixtures, deren Name „chatgpt" enthält
scripts/ui-snapshots.sh chatgpt  # dasselbe direkt
```

Jede Fixture wird hell und dunkel gerendert (`<name>-light.png`,
`<name>-dark.png`, doppelte Pixeldichte). Ein Lauf dauert wenige Sekunden nach
dem Build. **Sicher aus einem Agent-Chat:** kein App-Start, keine
Berechtigungen, die laufende App wird nicht berührt.

### Bausteine

- `WhisperM8/Services/Shared/ViewSnapshotRenderer.swift`: rendert über
  `NSHostingView` in einem unsichtbaren Fenster + `cacheDisplay`.
  **Nicht `ImageRenderer`**: der zeichnet AppKit-gestützte Controls (Toggle,
  Picker, TextField) auf macOS nur als Platzhalter. Der Hintergrund
  (`AppTheme.background`) wird explizit gesetzt, sonst wären dunkle Bilder
  transparent (`ViewSnapshotRendererTests` hält das fest).
- `Tests/WhisperM8Tests/UISnapshotGallery.swift`: die Fixtures. Läuft nur mit
  `WHISPERM8_SNAPSHOT_DIR`, im normalen `swift test` wird sie übersprungen.
- `scripts/ui-snapshots.sh`, `make snapshots`.

### Neue Ansicht aufnehmen

1. Fixture in `UISnapshotGallery.fixtures` ergänzen (Name, Größe, View).
2. `@AppStorage`-Werte über `storage:` setzen. Sie landen in einer
   Wegwerf-Suite (`.defaultAppStorage`), nie in den echten Preferences.
3. **Liest die Ansicht Keychain, Proxy, Dateien oder startet Subprozesse**
   (typisch in `onAppear`/`.task`), bekommt sie zuerst eine
   Abhängigkeits-Struktur mit `.live`-Default — Muster:
   `TranscriptionSettingsDependencies`. Im Snapshot darf nichts Echtes passieren.

### Grenzen

- Keine Interaktion, kein Hover, keine Animationen; `.task`-Ergebnisse nur,
  wenn sie innerhalb der kurzen Settle-Zeit (0,15 s) fertig sind.
- Eingebettete AppKit-Ansichten mit eigener Zeichenlogik (SwiftTerm-Terminal,
  Verlaufs-`NSTextView`) sind noch nicht erprobt.
- Kein Pixelvergleich gegen Referenzbilder — die Bilder sind zum Ansehen
  gedacht (Mensch oder Agent liest die PNGs), nicht als Regressions-Gate.

### Erster Befund (2026-10-08)

Schon der erste Lauf fand einen Fehler: Bei abgeschaltetem Kill-Switch
`chatGPTTranscriptionEnabled` und gespeichertem „ChatGPT-Abo" zeigte die
Transkriptions-Seite Groq mit **leerem** Modell-Picker. Jetzt zeigt sie das
Modell, das die Diktat-Logik tatsächlich nimmt (Groq-Default), ohne die
gespeicherte Wahl zu überschreiben.
