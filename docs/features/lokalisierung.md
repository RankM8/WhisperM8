---
status: aktiv
updated: 2026-10-19
description: Lokalisierung der App (E1) — Englisch als Basis, Deutsch vollständig, String-Katalog, Guard-Test und Regeln für neue Texte.
---

# Lokalisierung (E1)

Seit 19.10.2026 (Launch-Readiness W3.0). **Englisch ist die Basissprache, Deutsch
wird vollständig übersetzt.** Die App folgt der Systemsprache; Fachnamen und
CLI-Befehle (`claude`, `codex`, `whisperm8 chats …`) bleiben unübersetzt.

## Aufbau

- Katalog: `WhisperM8/Localization/Localizable.xcstrings` (`sourceLanguage: en`,
  Schlüssel = englischer Text).
- Kein SwiftPM-Ressource: `make dev`/`make build`/`scripts/test-instance.sh build`
  kompilieren den Katalog mit `xcrun xcstringstool compile` direkt nach
  `WhisperM8.app/Contents/Resources/<sprache>.lproj/` — dort sucht SwiftUI
  `Text("…")` und `String(localized:)` (Bundle.main).
- `Info.plist`: `CFBundleDevelopmentRegion = en`, `CFBundleLocalizations = [en, de]`.

## Regeln für neue oder geänderte Texte

1. Text im Code **englisch** schreiben und den Schlüssel mit deutscher
   Übersetzung (`state: translated`) in den Katalog eintragen.
2. `Text("…")`, `Button("…")`, `Label("…", …)`, `Toggle("…")`,
   `ContentUnavailableView("…", …)` lokalisieren Literale automatisch.
   **Achtung bei `String`-Parametern** (eigene Komponenten wie `SettingsRow(title:)`,
   `SettingsHelpText(_:)`, Alerts, Benachrichtigungen, `NSOpenPanel.prompt`):
   dort `String(localized: "…")` übergeben, sonst bleibt der Text unübersetzt.
3. Werte mit Interpolation: `String(localized: "Moved \(count) chats")` — im
   Katalog als `Moved %lld chats` mit deutschem `%lld Chats verschoben`.
   Platzhalter müssen übereinstimmen (Guard prüft das).
4. Ternäre Ausdrücke aus zwei Literalen (`Text(a ? "x" : "y")`) werden zu
   `String` und **nicht** übersetzt — stattdessen `a ? Text("x") : Text("y")`.
5. **Einstellungen:** Die Kit-Komponenten (`SettingsRow`, `SettingsHelpText`,
   `SettingsSection`, `SettingsToggleRow` …) nehmen weiter `String`-Parameter,
   rendern sie aber zur Laufzeit über den Katalog (`Text(settingsLocalized:)`,
   ohne Markdown). Literale dürfen also direkt übergeben werden; Texte mit
   Interpolation vorher mit `String(localized:)` bilden. `Text(stringVariable)`
   in Einstellungsdateien immer als `Text(settingsLocalized: …)` (Nutzerdaten:
   `Text(verbatim:)`). Der Guard prüft dort zusätzlich `title:`/`subtitle:`/
   `detail:`-Literale und `SettingsSection("…")`/`SettingsHelpText("…")`.
6. Eine vollständig umgestellte Datei in
   `LocalizationCatalogTests.localizedFiles` eintragen; ab dann fällt jeder
   neue Text ohne Katalogeintrag im Test auf.

## Prüfen

- `swift test --filter LocalizationCatalogTests`: Katalog gültig, jede
  Übersetzung fertig, Platzhalter gleich, `xcstringstool` kompiliert.
- Anschauen: `WHISPERM8_TEST_LANG=en scripts/test-instance.sh restart` bzw.
  `=de`, dann `scripts/test-instance.sh cli debug snapshot`.

Die Umstellung der vorhandenen Texte ist Welle W6 (`docs/audit/2026-10-launch-readiness/05-plan/wellen/W6-sprache-bedienbarkeit.md`).
