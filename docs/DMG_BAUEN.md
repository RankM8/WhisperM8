# WhisperM8 DMG bauen — Kurzanleitung

## Was du brauchst

- Einen Mac mit Apple Silicon (M1/M2/M3/M4)
- Terminal (findest du unter Programme → Dienstprogramme → Terminal)

## Schritte

### 1. Terminal öffnen und ins Projekt navigieren

```bash
cd ~/projects/WhisperM8
```

### 2. Preview-Patch anwenden

Ohne Xcode muss eine Datei gepatcht werden, damit der Build durchläuft. Kopiere diesen Befehl ins Terminal:

```bash
sed -i '' '/^@available(macOS 10.15/,/^#endif/{ /^@available/d; /^#Preview/,/^}/d; }' \
  .build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift
```

> **Hinweis:** Falls du vorher `swift package reset` ausgeführt hast oder der `.build`-Ordner fehlt, zuerst einmal `swift build 2>/dev/null; true` laufen lassen, damit die Dependencies geladen werden. Dann den Patch nochmal ausführen.

### 3. DMG bauen

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools make dmg
```

### 4. Fertig!

Das DMG findest du unter:

```
dist/WhisperM8-X.X.X.dmg
```

Die Versionsnummer wird automatisch aus dem Projekt übernommen.

## Für den Empfänger

Beim ersten Öffnen auf einem anderen Mac: **Rechtsklick auf WhisperM8.app → Öffnen** — die Gatekeeper-Warnung mit "Öffnen" bestätigen. Danach startet die App normal.

## Bei Problemen

| Problem | Lösung |
|---------|--------|
| `missing DEVELOPER_DIR` | `DEVELOPER_DIR=/Library/Developer/CommandLineTools` vor dem Befehl setzen |
| `PreviewsMacros` Fehler | Schritt 2 (Patch) nochmal ausführen |
| `.build` Ordner fehlt | `swift package resolve` ausführen, dann Schritt 2 wiederholen |
