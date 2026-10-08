---
status: umgesetzt — Stufe 1 (UI-Snapshots) und Stufe 2 (Debug-Steuerkanal)
stand: 2026-10-08
feature: UI-Tests ohne Computer Use
---

# UI-Tests ohne Computer Use

Native SwiftUI-Apps haben kein Playwright. Damit Ansichten trotzdem ohne
Klick-Automation und ohne Bildschirmzugriff prüfbar sind, gibt es zwei Bausteine:

| Stufe | Was | Wofür |
|---|---|---|
| 1 | **UI-Snapshots**: Ansichten in festen Zuständen als PNG | Layout, Texte, Zustände, Hell/Dunkel |
| 2 | **Debug-Steuerkanal** `whisperm8 debug` | Zustand auslesen, Fenster öffnen und fotografieren, Diktat mit Audiodatei — an der laufenden App |

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

## Stufe 2: Debug-Steuerkanal (`whisperm8 debug`)

Spricht über den vorhandenen Control-Socket (`AgentControlServer`, nur derselbe
Benutzer, Socket 0600) mit der **laufenden** App. Zusätzlich hinter einem
eigenen Schalter, Default aus — ein Fenster-Foto zeigt auch Chat-Inhalte, ein
Diktat schickt Audio an den Anbieter:

```bash
defaults write com.whisperm8.app debugControlEnabled -bool YES   # wirkt sofort
```

| Befehl | Wirkung |
|---|---|
| `whisperm8 debug state` | JSON: Fenster (Nummer, Titel, Identifier, Frame, key), Diktat-Phase, Anbieter/Modell/Sprache, GPT-Backend, Chats/PTYs. Keine Diktat-Texte, nur Längen. |
| `whisperm8 debug open <ziel>` | `settings[/<seite>]`, `agent-chats`, `onboarding`. Bringt die App nach vorn (Fokus!). Seiten = `SettingsPage`-Rohwerte plus Alt-Routen. |
| `whisperm8 debug snapshot [--window <name>\|key\|all] [--out <ordner>]` | Fotografiert sichtbare Fenster samt Titelleiste als PNG über ScreenCaptureKit (`SCShareableContent.currentProcess`, nur eigene Fenster, native Pixeldichte des Bildschirms). Feld `method` nennt den Weg; Rückfall `cacheDisplay`. Default-Ordner `~/Library/Application Support/WhisperM8/debug-snapshots/`. |
| `whisperm8 debug dictate <datei> [--provider groq\|openai\|chatgpt] [--language de\|en\|auto] [--timeout <s>]` | Audiodatei durch den echten Transkriptions-Weg (Einstellungen, Zugangs-Gate, Service-Factory, ChatGPT-Abo inklusive). **Kein** Einfügen, keine Zwischenablage, kein Run-Report, keine Nachbearbeitung, `AppState` bleibt unberührt. |
| `whisperm8 debug job <id>` | Stand eines Diktat-Auftrags. |

Ausgabe immer JSON auf stdout; Exit 0 ok, 1 Aufruf, 3 nicht gefunden,
4 Konflikt/Auftrag gescheitert, 5 App nicht erreichbar, 124 Timeout.

### Typischer Ablauf (Agent)

```bash
whisperm8 debug open settings/transcription
whisperm8 debug snapshot --window settings --out /tmp/shots   # PNG lesen
whisperm8 debug dictate ~/test.m4a --provider chatgpt          # Text + ms
whisperm8 debug state                                          # lastError etc.
```

### Bausteine

- `Services/Shared/DebugControl.swift`: pure Teile — `OpenTarget`,
  Fensterauswahl (`select`, Hilfsfenster wie Statusleiste/Popover raus,
  minimierte raus), Dateinamen, `DebugJobStore`, `DebugDictation`.
- `Services/AgentChats/AgentControlRequestHandler+Debug.swift`: Methoden
  `debug.state|open|snapshot|dictate|job`, Schalter, Audit-Log (außer `job`).
- `CLI/DebugCLICommand.swift`: Parser (`DebugCLIArguments`, relative Pfade
  gegen das Arbeitsverzeichnis der CLI) und Ausgabe.
- `WindowRequestCenter.requestSettings(routeID:)`: öffnet die Einstellungen auf
  einer bestimmten Seite. Die Seite gilt bis zum nächsten normalen
  `request(_:)` — bewusst nicht „einmal verbrauchen", weil die SettingsView die
  Route beim Öffnen zweimal auswertet (`onAppear` + Erstwert des Publishers).

### Warum `dictate` ein Auftrag ist

Der Socket bricht jeden Request nach 10 s ab (`AgentControlServer`). Ein Diktat
mit langer Aufnahme dauert länger; `debug.dictate` legt deshalb einen Auftrag an
und antwortet sofort, die CLI pollt `debug.job` im Halbsekundentakt. Höchstens
2 Aufträge gleichzeitig, fertige bleiben 10 min abfragbar.

### Grenzen

- Klicks und Eingaben gibt es nicht — Zustand ändern nur über `open` oder die
  Einstellungen selbst.
- **Warum ScreenCaptureKit statt `cacheDisplay`** (Live-Befund 2026-10-08):
  In der laufenden App zeichnete `cacheDisplay` nur die Titelleiste — SwiftUI
  rendert dort über eigene Layer, die `cacheDisplay` nicht erfasst. In den
  Offscreen-Fenstern der UI-Snapshots (Stufe 1) tritt das nicht auf. Der
  Rückfall bleibt nur für macOS < 14.4 bzw. wenn ScreenCaptureKit scheitert
  (dann `method: "cacheDisplay"` — das Bild kann leer sein).
- Eine App ohne diese Methoden (alter Build) antwortet „Unbekannte Methode";
  die CLI rät dann zu `make dev`.
