---
description: Settings-Seite „Output Overview" — Referenz für Default-Output, Codex-Status und letzten Output
description_long: |
  Vollständige Referenz der Settings-Seite „Output Overview": Zweck, UI-Aufbau,
  alle Optionen, Anzeigen, Buttons und History-Sprünge mit Control, Default,
  Persistenz, Datenquelle, Wirkung, Querverweisen und UX-Beobachtungen.
updated: 2026-07-06 14:05
status: ✅ Validiert (Opus-Gegenprüfung 2026-07-06, 0 Mängel)
---

> ⚠️ HISTORISCH (Stand vor Refactor 2026-07-06) — Inhalte beschreiben die alte Seite; neue Seite: `OutputWorkspacePage.swift` + Doku-Verweis [ARCHITEKTUR: Pages](ARCHITEKTUR.md#pages).

# Settings: Output Overview

> **Sidebar-Gruppe:** Output · **View:** `WhisperM8/Views/OutputOverviewView.swift` · **Enum-Case:** `ControlCenterSection.outputOverview` (`WhisperM8/Views/SettingsView.swift`)
>
> **Primäre Quell-Dateien:** `OutputOverviewView.swift`, `OutputReportComponents.swift`, `Models/AppState.swift`

## 1. Zweck & Überblick

„Output Overview" ist eine kompakte Settings-Seite für drei Dinge: Default-Output-Modus, Codex-CLI-Status und Vorschau des zuletzt erzeugten Outputs (`WhisperM8/Views/OutputOverviewView.swift:14`, `WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:45`). Sie liegt in der Sidebar-Gruppe „Output" und wird über `ControlCenterSection.outputOverview` geroutet (`WhisperM8/Views/SettingsView.swift:6`, `WhisperM8/Views/SettingsView.swift:96`, `WhisperM8/Views/SettingsView.swift:100`, `WhisperM8/Views/SettingsView.swift:127`, `WhisperM8/Views/SettingsView.swift:128`). Der einzige persistente Schreibzugriff auf dieser Seite ist der Picker `Default Mode`, der den UserDefaults-Key `defaultOutputModeID` direkt bindet (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Support/AppPreferences.swift:84`, `WhisperM8/Support/AppPreferences.swift:86`). Die übrigen Elemente lesen flüchtigen View-State oder `AppState` und verlinken bei Bedarf zur vollständigen History-Seite (`WhisperM8/Views/OutputOverviewView.swift:7`, `WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:48`, `WhisperM8/Views/SettingsView.swift:210`, `WhisperM8/Views/SettingsView.swift:216`).

## 2. UI-Aufbau

Die View ist ein gruppiertes SwiftUI-`Form` mit drei Sections und dem Detailtitel „Overview" (`WhisperM8/Views/OutputOverviewView.swift:13`, `WhisperM8/Views/OutputOverviewView.swift:14`, `WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:45`, `WhisperM8/Views/OutputOverviewView.swift:62`, `WhisperM8/Views/OutputOverviewView.swift:63`). Die Section „Default Output" enthält den Picker „Default Mode" mit allen aktivierten Output-Modes und einen erklärenden Caption-Text (`WhisperM8/Views/OutputOverviewView.swift:14`, `WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Views/OutputOverviewView.swift:16`, `WhisperM8/Views/OutputOverviewView.swift:21`). Die Section „Codex" zeigt eine Statuszeile und zwei Buttons: „Check Again" prüft erneut lokal, „Set up Codex" öffnet die Codex-CLI-Webseite (`WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:27`, `WhisperM8/Views/OutputOverviewView.swift:35`, `WhisperM8/Views/OutputOverviewView.swift:39`, `WhisperM8/Views/OutputOverviewView.swift:40`). Die Section „Last Output" zeigt entweder eine Reportkarte für `lastTranscriptRunReport`, einen Raw/Final-Fallback aus den letzten Transkriptionsstrings oder den leeren Zustand „No output yet" (`WhisperM8/Views/OutputOverviewView.swift:45`, `WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:56`). Die vollständige History lädt dagegen eine Master-Detail-Ansicht mit Liste, Filtern, Detailansicht und Löschaktion (`WhisperM8/Views/OutputHistoryView.swift:3`, `WhisperM8/Views/OutputHistoryView.swift:7`, `WhisperM8/Views/OutputHistoryView.swift:27`, `WhisperM8/Views/OutputHistoryView.swift:33`, `WhisperM8/Views/OutputHistoryView.swift:34`, `WhisperM8/Views/OutputHistoryView.swift:70`, `WhisperM8/Views/OutputHistoryView.swift:82`, `WhisperM8/Views/TranscriptReportDetailView.swift:28`).

## 3. Optionen im Detail

### Default Mode

| Aspekt | Wert |
|---|---|
| Control | Picker mit Label „Default Mode"; die Auswahl ist an `@AppStorage("defaultOutputModeID")` gebunden (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Views/OutputOverviewView.swift:15`). |
| Default | `OutputMode.cleanID` beziehungsweise Stringwert `clean`, wenn kein Wert in UserDefaults liegt (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Models/OutputMode.swift:128`, `WhisperM8/Support/AppPreferences.swift:84`, `WhisperM8/Support/AppPreferences.swift:85`). |
| Persistenz | UserDefaults-Key `defaultOutputModeID`; der Key ist in `PreferenceKeys` definiert und wird von `AppPreferences.defaultOutputModeID` gelesen und geschrieben (`WhisperM8/Support/AppPreferences.swift:84`, `WhisperM8/Support/AppPreferences.swift:86`, `WhisperM8/Support/AppPreferences.swift:368`). |
| Gelesen von | `OutputOverviewView` für den Picker, `OutputMode.defaultMode()` für neue Aufnahmen, `OutputModeStore.mode(for:)` und `OutputModeStore.normalized(_:)` für Mode-Auflösung und Default-Markierung (`WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Models/OutputMode.swift:237`, `WhisperM8/Models/OutputMode.swift:238`, `WhisperM8/Services/Dictation/OutputModeStore.swift:76`, `WhisperM8/Services/Dictation/OutputModeStore.swift:77`, `WhisperM8/Services/Dictation/OutputModeStore.swift:152`, `WhisperM8/Services/Dictation/OutputModeStore.swift:156`). |
| Wirkung | Neue Recordings starten mit `OutputMode.defaultMode()`, weil `RecordingCoordinator` beim Aufnahmestart `appState.selectedOutputMode` daraus setzt (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:160`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:167`). |
| Abhängigkeiten | Die Picker-Liste kommt aus `OutputMode.enabledBuiltInModes`, das auf `OutputModeStore().enabledModes` zeigt; im Dictation-only-Profil kann `OutputMode.defaultMode(profile:)` effektiv auf Raw/Fast zurückfallen, wenn der gespeicherte Default Codex-abhängig ist (`WhisperM8/Views/OutputOverviewView.swift:16`, `WhisperM8/Models/OutputMode.swift:248`, `WhisperM8/Models/OutputMode.swift:249`, `WhisperM8/Models/OutputMode.swift:237`, `WhisperM8/Models/OutputMode.swift:242`, `WhisperM8/Models/OutputMode.swift:243`). |

### Default-Output-Hinweistext

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement: Caption-Text „New recordings start with this mode. You can still switch mode while recording." (`WhisperM8/Views/OutputOverviewView.swift:21`, `WhisperM8/Views/OutputOverviewView.swift:22`, `WhisperM8/Views/OutputOverviewView.swift:23`). |
| Default | Immer sichtbar, sobald die Section „Default Output" sichtbar ist (`WhisperM8/Views/OutputOverviewView.swift:14`, `WhisperM8/Views/OutputOverviewView.swift:21`). |
| Persistenz | Keine eigene Persistenz; der Text ist statisch im SwiftUI-Code hinterlegt (`WhisperM8/Views/OutputOverviewView.swift:21`). |
| Gelesen von | Nur `OutputOverviewView` rendert diesen Text (`WhisperM8/Views/OutputOverviewView.swift:21`). |
| Wirkung | Keine Laufzeitwirkung; der Text erklärt die Wirkung des Pickers, während die tatsächliche Aufnahmelogik über `OutputMode.defaultMode()` läuft (`WhisperM8/Views/OutputOverviewView.swift:21`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:167`). |
| Abhängigkeiten | Inhaltlich abhängig vom `Default Mode`-Picker; technisch keine Binding- oder State-Abhängigkeit (`WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Views/OutputOverviewView.swift:21`). |

### Codex-Statusanzeige

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement in einer `HStack`: Label „Status" plus `codexStatus.displayText` (`WhisperM8/Views/OutputOverviewView.swift:27`, `WhisperM8/Views/OutputOverviewView.swift:28`, `WhisperM8/Views/OutputOverviewView.swift:30`). |
| Default | Initial `.unknown`, angezeigt als „Unknown", bis `.onAppear` oder „Check Again" den Status prüft (`WhisperM8/Views/OutputOverviewView.swift:7`, `WhisperM8/Views/OutputOverviewView.swift:64`, `WhisperM8/Views/OutputOverviewView.swift:65`, `WhisperM8/Services/Dictation/CodexSupport.swift:127`, `WhisperM8/Services/Dictation/CodexSupport.swift:139`, `WhisperM8/Services/Dictation/CodexSupport.swift:140`). |
| Persistenz | Keine Persistenz; `codexStatus` ist `@State` der View (`WhisperM8/Views/OutputOverviewView.swift:7`). |
| Gelesen von | `OutputOverviewView` liest `CodexConnectionStatus.displayText`; die möglichen Texte sind „Not installed", „Installed", „Signed in with ChatGPT", „Not signed in" und „Unknown" (`WhisperM8/Views/OutputOverviewView.swift:30`, `WhisperM8/Services/Dictation/CodexSupport.swift:129`, `WhisperM8/Services/Dictation/CodexSupport.swift:132`, `WhisperM8/Services/Dictation/CodexSupport.swift:134`, `WhisperM8/Services/Dictation/CodexSupport.swift:136`, `WhisperM8/Services/Dictation/CodexSupport.swift:138`, `WhisperM8/Services/Dictation/CodexSupport.swift:140`). |
| Wirkung | Informiert nur über lokale Codex-CLI-Erreichbarkeit und Login-Status; non-interaktives Codex-Processing gilt nur bei `.signedIn` als bereit (`WhisperM8/Services/Dictation/CodexSupport.swift:144`, `WhisperM8/Services/Dictation/CodexSupport.swift:145`). |
| Abhängigkeiten | Abhängig von `CodexStatusProbe.status()`, das `codex login status` über den aufgelösten `codex`-Pfad ausführt (`WhisperM8/Services/Dictation/CodexSupport.swift:169`, `WhisperM8/Services/Dictation/CodexSupport.swift:170`, `WhisperM8/Services/Dictation/CodexSupport.swift:172`, `WhisperM8/Services/Dictation/CodexSupport.swift:220`, `WhisperM8/Services/Dictation/CodexSupport.swift:227`). |

### Check Again

| Aspekt | Wert |
|---|---|
| Control | Button „Check Again" in der Codex-Section (`WhisperM8/Views/OutputOverviewView.swift:34`, `WhisperM8/Views/OutputOverviewView.swift:35`). |
| Default | Immer sichtbar in der Codex-Section (`WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:34`, `WhisperM8/Views/OutputOverviewView.swift:35`). |
| Persistenz | Keine Persistenz; der Button überschreibt nur den lokalen `@State` `codexStatus` (`WhisperM8/Views/OutputOverviewView.swift:7`, `WhisperM8/Views/OutputOverviewView.swift:36`). |
| Gelesen von | Der Button ruft `CodexStatusProbe().status()` auf; diese Methode prüft den `codex`-Pfad und wertet die Ausgabe von `codex login status` aus (`WhisperM8/Views/OutputOverviewView.swift:36`, `WhisperM8/Services/Dictation/CodexSupport.swift:169`, `WhisperM8/Services/Dictation/CodexSupport.swift:170`, `WhisperM8/Services/Dictation/CodexSupport.swift:172`, `WhisperM8/Services/Dictation/CodexSupport.swift:175`, `WhisperM8/Services/Dictation/CodexSupport.swift:179`, `WhisperM8/Services/Dictation/CodexSupport.swift:185`). |
| Wirkung | Aktualisiert die sichtbare Statuszeile sofort innerhalb der View (`WhisperM8/Views/OutputOverviewView.swift:30`, `WhisperM8/Views/OutputOverviewView.swift:36`). |
| Abhängigkeiten | Nutzt dieselbe Probe wie `.onAppear`, aber keine gemeinsame Cache-Schicht auf dieser Seite (`WhisperM8/Views/OutputOverviewView.swift:36`, `WhisperM8/Views/OutputOverviewView.swift:64`, `WhisperM8/Views/OutputOverviewView.swift:65`). |

### Set up Codex

| Aspekt | Wert |
|---|---|
| Control | Button „Set up Codex" in der Codex-Section (`WhisperM8/Views/OutputOverviewView.swift:39`). |
| Default | Immer sichtbar in der Codex-Section (`WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:39`). |
| Persistenz | Keine App-Persistenz; der Button öffnet eine externe URL via `NSWorkspace.shared.open` (`WhisperM8/Views/OutputOverviewView.swift:40`). |
| Gelesen von | Nur `OutputOverviewView` definiert diesen Button und die URL `https://developers.openai.com/codex/cli` (`WhisperM8/Views/OutputOverviewView.swift:39`, `WhisperM8/Views/OutputOverviewView.swift:40`). |
| Wirkung | Öffnet die Codex-CLI-Setup-Seite im Systembrowser (`WhisperM8/Views/OutputOverviewView.swift:40`). |
| Abhängigkeiten | Keine technische Abhängigkeit vom aktuellen `codexStatus`; der Button ist auch bei installiertem oder angemeldetem Codex sichtbar (`WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:30`, `WhisperM8/Views/OutputOverviewView.swift:39`). |

### Last-Output-Reportkarte

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement `LastOutputCard(report:)`, sichtbar wenn `appState.lastTranscriptRunReport` gesetzt ist (`WhisperM8/Views/OutputOverviewView.swift:45`, `WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:47`). |
| Default | Nicht sichtbar, solange `lastTranscriptRunReport` `nil` ist (`WhisperM8/Models/AppState.swift:42`, `WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:55`). |
| Persistenz | Die Karte selbst persistiert nichts; der Report wird als `report.json` im Reports-Verzeichnis gespeichert und zusätzlich in `appState.lastTranscriptRunReport` gehalten (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:355`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:356`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:170`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:174`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:371`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:374`). |
| Gelesen von | `OutputOverviewView` liest `appState.lastTranscriptRunReport`; die Reportstruktur enthält `id`, `createdAt`, `status`, `mode`, `rawTranscript` und `finalTranscript` (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Models/TranscriptRunReport.swift:105`, `WhisperM8/Models/TranscriptRunReport.swift:106`, `WhisperM8/Models/TranscriptRunReport.swift:109`, `WhisperM8/Models/TranscriptRunReport.swift:111`, `WhisperM8/Models/TranscriptRunReport.swift:120`, `WhisperM8/Models/TranscriptRunReport.swift:121`). |
| Wirkung | Zeigt eine kompakte Zusammenfassung des letzten gespeicherten Runs und bietet den Sprung zur History mit Report-ID an (`WhisperM8/Views/OutputOverviewView.swift:47`, `WhisperM8/Views/OutputOverviewView.swift:48`, `WhisperM8/Views/OutputOverviewView.swift:78`, `WhisperM8/Views/OutputOverviewView.swift:91`, `WhisperM8/Views/OutputOverviewView.swift:100`). |
| Abhängigkeiten | Abhängig vom erfolgreichen Speichern in `TranscriptRunReportStore.save(_:)`; schlägt das Speichern fehl, loggt der Coordinator nur und setzt keinen neuen `lastTranscriptRunReport` (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:355`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:356`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:357`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:358`). |

### Last-Output-Titel und Uhrzeit

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement innerhalb `LastOutputCard`: `report.title` links und `report.createdAt` rechts als Stunde/Minute (`WhisperM8/Views/OutputOverviewView.swift:78`, `WhisperM8/Views/OutputOverviewView.swift:79`, `WhisperM8/Views/OutputOverviewView.swift:82`). |
| Default | Nur sichtbar im Reportkarten-Zweig (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:47`). |
| Persistenz | Keine eigene Persistenz; `createdAt`, `mode.name` und `sourceAppName` kommen aus dem `TranscriptRunReport` (`WhisperM8/Models/TranscriptRunReport.swift:106`, `WhisperM8/Models/TranscriptRunReport.swift:107`, `WhisperM8/Models/TranscriptRunReport.swift:111`). |
| Gelesen von | `report.title` kombiniert `mode.name` und `sourceAppName ?? "Unknown app"`; `createdAt` wird direkt formatiert (`WhisperM8/Models/TranscriptRunReport.swift:135`, `WhisperM8/Models/TranscriptRunReport.swift:136`, `WhisperM8/Models/TranscriptRunReport.swift:137`, `WhisperM8/Models/TranscriptRunReport.swift:138`, `WhisperM8/Views/OutputOverviewView.swift:82`). |
| Wirkung | Liefert Kontext, welcher Mode in welcher App zuletzt gelaufen ist und zu welcher Uhrzeit der Run entstand (`WhisperM8/Models/TranscriptRunReport.swift:136`, `WhisperM8/Models/TranscriptRunReport.swift:137`, `WhisperM8/Views/OutputOverviewView.swift:82`). |
| Abhängigkeiten | Source-App und Mode-Snapshot werden beim Speichern des Reports aus Draft und Context-Bundle übernommen (`WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:129`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:132`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:136`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:138`). |

### Last-Output-Status

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement `Text(report.status.displayText)` innerhalb `LastOutputCard` (`WhisperM8/Views/OutputOverviewView.swift:87`). |
| Default | Nur sichtbar im Reportkarten-Zweig (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:47`, `WhisperM8/Views/OutputOverviewView.swift:87`). |
| Persistenz | Keine eigene Persistenz; der Status ist Teil von `TranscriptRunReport.status` (`WhisperM8/Models/TranscriptRunReport.swift:109`). |
| Gelesen von | `TranscriptRunStatus.displayText` bildet `.succeeded`, `.rawFallback`, `.cautiousFallback` und `.failed` auf englische Labels ab (`WhisperM8/Models/TranscriptRunReport.swift:3`, `WhisperM8/Models/TranscriptRunReport.swift:9`, `WhisperM8/Models/TranscriptRunReport.swift:11`, `WhisperM8/Models/TranscriptRunReport.swift:13`, `WhisperM8/Models/TranscriptRunReport.swift:15`, `WhisperM8/Models/TranscriptRunReport.swift:17`). |
| Wirkung | Macht Erfolg, Fallback oder Fehler des letzten Runs in der Overview sichtbar (`WhisperM8/Views/OutputOverviewView.swift:87`, `WhisperM8/Models/TranscriptRunReport.swift:11`, `WhisperM8/Models/TranscriptRunReport.swift:13`, `WhisperM8/Models/TranscriptRunReport.swift:15`, `WhisperM8/Models/TranscriptRunReport.swift:17`). |
| Abhängigkeiten | Der Status wird beim Speichern aus dem Post-Processing-Ergebnis abgeleitet (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:112`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:113`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:327`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:330`). |

### Last-Output-Kurzvorschau

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement `Text(report.shortSummary)` mit drei Zeilen und aktivierter Textauswahl (`WhisperM8/Views/OutputOverviewView.swift:91`, `WhisperM8/Views/OutputOverviewView.swift:94`, `WhisperM8/Views/OutputOverviewView.swift:95`). |
| Default | Nur sichtbar im Reportkarten-Zweig (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:47`, `WhisperM8/Views/OutputOverviewView.swift:91`). |
| Persistenz | Keine eigene Persistenz; `shortSummary` liest `finalTranscript`, danach `rawTranscript`, danach `errorMessage` oder „No transcript" aus dem Report (`WhisperM8/Models/TranscriptRunReport.swift:141`, `WhisperM8/Models/TranscriptRunReport.swift:142`, `WhisperM8/Models/TranscriptRunReport.swift:145`, `WhisperM8/Models/TranscriptRunReport.swift:148`). |
| Gelesen von | `LastOutputCard` liest `report.shortSummary`; die vollständige History nutzt dieselbe Kurzvorschau in der linken Liste (`WhisperM8/Views/OutputOverviewView.swift:91`, `WhisperM8/Views/OutputHistoryView.swift:171`). |
| Wirkung | Zeigt einen gekürzten Ausschnitt des letzten Ergebnisses, ohne in die Detailansicht zu wechseln (`WhisperM8/Views/OutputOverviewView.swift:91`, `WhisperM8/Views/OutputOverviewView.swift:94`). |
| Abhängigkeiten | Final- und Raw-Text werden im Transkriptionsdurchlauf gesetzt und danach in den Report-Draft geschrieben (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:52`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:79`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:341`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:342`). |

### Open in History

| Aspekt | Wert |
|---|---|
| Control | Borderless Button mit Label „Open in History" und Systembild `arrow.right` innerhalb `LastOutputCard` (`WhisperM8/Views/OutputOverviewView.swift:100`, `WhisperM8/Views/OutputOverviewView.swift:103`, `WhisperM8/Views/OutputOverviewView.swift:105`). |
| Default | Nur sichtbar, wenn eine `LastOutputCard` für `lastTranscriptRunReport` angezeigt wird (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:47`, `WhisperM8/Views/OutputOverviewView.swift:100`). |
| Persistenz | Keine Persistenz; der Button ruft nur die übergebene Closure `onOpenInHistory` auf (`WhisperM8/Views/OutputOverviewView.swift:73`, `WhisperM8/Views/OutputOverviewView.swift:74`, `WhisperM8/Views/OutputOverviewView.swift:101`). |
| Gelesen von | `OutputOverviewView` übergibt `onOpenHistory(report.id)` an die Karte; `SettingsView` nimmt die ID entgegen (`WhisperM8/Views/OutputOverviewView.swift:47`, `WhisperM8/Views/OutputOverviewView.swift:48`, `WhisperM8/Views/SettingsView.swift:210`, `WhisperM8/Views/SettingsView.swift:211`). |
| Wirkung | Wechselt in die Settings-Section `.history` und setzt die Vorselektion auf die ID des letzten Reports (`WhisperM8/Views/SettingsView.swift:210`, `WhisperM8/Views/SettingsView.swift:211`, `WhisperM8/Views/SettingsView.swift:212`, `WhisperM8/Views/SettingsView.swift:216`). |
| Abhängigkeiten | `OutputHistoryView.reload()` selektiert die übergebene ID nur, wenn sie unter den sichtbaren Reports vorhanden ist; sonst wählt sie die bestehende oder erste sichtbare Auswahl (`WhisperM8/Views/OutputHistoryView.swift:127`, `WhisperM8/Views/OutputHistoryView.swift:131`, `WhisperM8/Views/OutputHistoryView.swift:132`, `WhisperM8/Views/OutputHistoryView.swift:133`, `WhisperM8/Views/OutputHistoryView.swift:134`, `WhisperM8/Views/OutputHistoryView.swift:135`). |

### Raw-Fallback-Preview

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement `LastOutputPreview(title: "Raw", text: raw)` im Fallback-Zweig ohne persistierten Report (`WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:52`). |
| Default | Sichtbar, wenn kein `lastTranscriptRunReport` existiert, aber `lastRawTranscription` gesetzt und nicht leer ist (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`). |
| Persistenz | Keine eigene Persistenz; `lastRawTranscription` ist flüchtiger `AppState` und wird nach erfolgreicher Transkription gesetzt (`WhisperM8/Models/AppState.swift:34`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:47`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:52`). |
| Gelesen von | `OutputOverviewView` liest `appState.lastRawTranscription`; `LastOutputPreview` rendert den Text oder „No output yet" (`WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:52`, `WhisperM8/Views/OutputOverviewView.swift:112`, `WhisperM8/Views/OutputOverviewView.swift:121`). |
| Wirkung | Zeigt bis zu drei Zeilen des letzten Raw-Transkripts, falls noch kein Report persistiert wurde (`WhisperM8/Views/OutputOverviewView.swift:52`, `WhisperM8/Views/OutputOverviewView.swift:121`, `WhisperM8/Views/OutputOverviewView.swift:122`). |
| Abhängigkeiten | Dieser Zweig ist ein expliziter Fallback „falls noch kein persistierter Report vorliegt" (`WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:51`). |

### Final-Fallback-Preview

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement `LastOutputPreview(title: "Final", text: appState.lastFinalTranscription ?? appState.lastTranscription)` (`WhisperM8/Views/OutputOverviewView.swift:53`). |
| Default | Sichtbar im selben Fallback-Zweig wie die Raw-Preview (`WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:53`). |
| Persistenz | Keine eigene Persistenz; `lastFinalTranscription` und `lastTranscription` sind flüchtige `AppState`-Werte (`WhisperM8/Models/AppState.swift:31`, `WhisperM8/Models/AppState.swift:35`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:79`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:80`). |
| Gelesen von | `OutputOverviewView` liest `appState.lastFinalTranscription` mit Fallback auf `appState.lastTranscription`; `LastOutputPreview` rendert den Text oder „No output yet" (`WhisperM8/Views/OutputOverviewView.swift:53`, `WhisperM8/Views/OutputOverviewView.swift:121`). |
| Wirkung | Zeigt bis zu drei Zeilen des letzten finalen Outputs, wenn der gespeicherte Report noch fehlt (`WhisperM8/Views/OutputOverviewView.swift:53`, `WhisperM8/Views/OutputOverviewView.swift:121`, `WhisperM8/Views/OutputOverviewView.swift:122`). |
| Abhängigkeiten | Final-Text entsteht aus Post-Processing oder Raw-Fallback und wird nach der Auslieferung in `lastFinalTranscription` und `lastTranscription` geschrieben (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:54`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:60`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:78`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:79`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:80`). |

### Open History

| Aspekt | Wert |
|---|---|
| Control | Button „Open History" im Fallback-Zweig und im leeren Zustand (`WhisperM8/Views/OutputOverviewView.swift:54`, `WhisperM8/Views/OutputOverviewView.swift:58`). |
| Default | Sichtbar, wenn kein persistierter Report angezeigt wird; im Raw/Final-Fallback und im „No output yet"-Zweig ruft er `onOpenHistory(nil)` auf (`WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:54`, `WhisperM8/Views/OutputOverviewView.swift:55`, `WhisperM8/Views/OutputOverviewView.swift:58`). |
| Persistenz | Keine Persistenz; es wird keine Report-ID übergeben (`WhisperM8/Views/OutputOverviewView.swift:54`, `WhisperM8/Views/OutputOverviewView.swift:58`). |
| Gelesen von | `SettingsView` erhält `nil`, speichert `historyPreselectID = nil` und wechselt zur History (`WhisperM8/Views/SettingsView.swift:210`, `WhisperM8/Views/SettingsView.swift:211`, `WhisperM8/Views/SettingsView.swift:212`). |
| Wirkung | Öffnet die History-Seite ohne explizite Vorselektion; `OutputHistoryView` wählt dann beim Reload die bestehende oder erste sichtbare Auswahl (`WhisperM8/Views/SettingsView.swift:216`, `WhisperM8/Views/OutputHistoryView.swift:127`, `WhisperM8/Views/OutputHistoryView.swift:134`, `WhisperM8/Views/OutputHistoryView.swift:135`). |
| Abhängigkeiten | Die History lädt bis zu 200 Reports aus `TranscriptRunReportStore.recentReports(limit:)` (`WhisperM8/Views/OutputHistoryView.swift:127`, `WhisperM8/Views/OutputHistoryView.swift:128`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:179`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:192`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:193`). |

### No output yet

| Aspekt | Wert |
|---|---|
| Control | Reines Anzeigeelement `Text("No output yet")` im leeren Last-Output-Zweig (`WhisperM8/Views/OutputOverviewView.swift:55`, `WhisperM8/Views/OutputOverviewView.swift:56`). |
| Default | Sichtbar, wenn weder `lastTranscriptRunReport` noch nichtleeres `lastRawTranscription` vorhanden ist (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:55`). |
| Persistenz | Keine Persistenz; der Zustand ergibt sich aus flüchtigem `AppState` (`WhisperM8/Models/AppState.swift:34`, `WhisperM8/Models/AppState.swift:42`, `WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`). |
| Gelesen von | Nur `OutputOverviewView` rendert diesen leeren Zustand (`WhisperM8/Views/OutputOverviewView.swift:55`, `WhisperM8/Views/OutputOverviewView.swift:56`). |
| Wirkung | Signalisiert, dass die Overview aktuell keine letzte Ausgabe anzeigen kann, bietet aber direkt den History-Sprung über den folgenden Button an (`WhisperM8/Views/OutputOverviewView.swift:56`, `WhisperM8/Views/OutputOverviewView.swift:58`). |
| Abhängigkeiten | Unabhängig von der persistierten History, weil die Bedingung nicht `TranscriptRunReportStore.recentReports` abfragt (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputHistoryView.swift:127`, `WhisperM8/Views/OutputHistoryView.swift:128`). |

### onOpenHistory-Sprung zur History-Seite

| Aspekt | Wert |
|---|---|
| Control | Closure-Übergabe von `OutputOverviewView` an `SettingsView`; `OutputOverviewView` hat als Default eine No-op-Closure (`WhisperM8/Views/OutputOverviewView.swift:9`, `WhisperM8/Views/OutputOverviewView.swift:10`, `WhisperM8/Views/SettingsView.swift:210`). |
| Default | Ohne Injection passiert nichts; im Settings-Fenster setzt die Closure `historyPreselectID` und `selection = .history` (`WhisperM8/Views/OutputOverviewView.swift:10`, `WhisperM8/Views/SettingsView.swift:210`, `WhisperM8/Views/SettingsView.swift:211`, `WhisperM8/Views/SettingsView.swift:212`). |
| Persistenz | Keine Persistenz; `historyPreselectID` ist `@State` im `SettingsView` (`WhisperM8/Views/SettingsView.swift:113`, `WhisperM8/Views/SettingsView.swift:115`). |
| Gelesen von | `OutputHistoryView(preselectReportID:)` erhält den State-Wert aus `SettingsView` (`WhisperM8/Views/SettingsView.swift:216`). |
| Wirkung | Verbindet Overview und History innerhalb derselben `NavigationSplitView`-Selection (`WhisperM8/Views/SettingsView.swift:117`, `WhisperM8/Views/SettingsView.swift:118`, `WhisperM8/Views/SettingsView.swift:138`, `WhisperM8/Views/SettingsView.swift:202`, `WhisperM8/Views/SettingsView.swift:209`, `WhisperM8/Views/SettingsView.swift:216`). |
| Abhängigkeiten | Die Vorselektion funktioniert nur, wenn der Report in der gefilterten History sichtbar ist; Filter und Report-Liste werden in `OutputHistoryView` lokal gehalten (`WhisperM8/Views/OutputHistoryView.swift:13`, `WhisperM8/Views/OutputHistoryView.swift:15`, `WhisperM8/Views/OutputHistoryView.swift:18`, `WhisperM8/Views/OutputHistoryView.swift:19`, `WhisperM8/Views/OutputHistoryView.swift:131`, `WhisperM8/Views/OutputHistoryView.swift:132`). |

## 4. Datenfluss & Persistenz

`defaultOutputModeID` wird durch den Picker sofort über `@AppStorage` in UserDefaults geschrieben und über `AppPreferences.defaultOutputModeID` wieder gelesen (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Support/AppPreferences.swift:84`, `WhisperM8/Support/AppPreferences.swift:86`). Die Mode-Liste wird über `OutputMode.enabledBuiltInModes` aus `OutputModeStore.enabledModes` gelesen; `OutputModeStore` normalisiert dabei Datei- und Built-in-Modes und setzt den Default anhand von `AppPreferences.shared.defaultOutputModeID` (`WhisperM8/Views/OutputOverviewView.swift:16`, `WhisperM8/Models/OutputMode.swift:248`, `WhisperM8/Models/OutputMode.swift:249`, `WhisperM8/Services/Dictation/OutputModeStore.swift:64`, `WhisperM8/Services/Dictation/OutputModeStore.swift:72`, `WhisperM8/Services/Dictation/OutputModeStore.swift:145`, `WhisperM8/Services/Dictation/OutputModeStore.swift:152`, `WhisperM8/Services/Dictation/OutputModeStore.swift:156`). Neue Aufnahmen lesen den Default beim Start live über `OutputMode.defaultMode()`; ein App-Neustart ist für diese Wirkung im Codepfad nicht erkennbar nötig (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:160`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:167`, `WhisperM8/Models/OutputMode.swift:237`, `WhisperM8/Models/OutputMode.swift:238`).

Der Codex-Status ist flüchtiger View-State: Initial `.unknown`, beim Erscheinen und per Button neu geprüft, aber nicht gespeichert (`WhisperM8/Views/OutputOverviewView.swift:7`, `WhisperM8/Views/OutputOverviewView.swift:35`, `WhisperM8/Views/OutputOverviewView.swift:36`, `WhisperM8/Views/OutputOverviewView.swift:64`, `WhisperM8/Views/OutputOverviewView.swift:65`). `CodexStatusProbe.status()` löst das `codex`-Binary auf, führt `codex login status` aus und klassifiziert die Ausgabe in `.signedIn`, `.notSignedIn`, `.installed` oder `.notInstalled` (`WhisperM8/Services/Dictation/CodexSupport.swift:169`, `WhisperM8/Services/Dictation/CodexSupport.swift:170`, `WhisperM8/Services/Dictation/CodexSupport.swift:172`, `WhisperM8/Services/Dictation/CodexSupport.swift:175`, `WhisperM8/Services/Dictation/CodexSupport.swift:179`, `WhisperM8/Services/Dictation/CodexSupport.swift:185`).

Der letzte Output kommt primär aus `AppState.lastTranscriptRunReport`, das beim Speichern eines Run-Reports gesetzt wird (`WhisperM8/Models/AppState.swift:42`, `WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:355`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:356`). Der Report-Store schreibt `report.json` unter `Application Support/WhisperM8/Reports/<UUID>/report.json` und kopiert Anhänge in ein `Attachments`-Unterverzeichnis (`WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:71`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:73`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:74`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:170`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:174`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:371`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:377`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:383`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:384`). Die Overview lädt keine Reports aus dem Store nach; wenn `AppState` keinen Report hält, nutzt sie nur den flüchtigen Raw/Final-Fallback oder den leeren Zustand (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:53`, `WhisperM8/Views/OutputOverviewView.swift:55`). Die History lädt dagegen beim Erscheinen `store.recentReports(limit: 200)` und der Store sortiert Reports absteigend nach `createdAt` (`WhisperM8/Views/OutputHistoryView.swift:49`, `WhisperM8/Views/OutputHistoryView.swift:127`, `WhisperM8/Views/OutputHistoryView.swift:128`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:179`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:188`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:192`).

## 5. Querverweise

Die Seite „Modes" schreibt denselben UserDefaults-Key `defaultOutputModeID` und kann damit den Picker auf „Output Overview" beeinflussen (`WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Views/OutputModesView.swift:143`, `WhisperM8/Views/OutputModesView.swift:146`, `WhisperM8/Views/OutputModesView.swift:378`, `WhisperM8/Support/AppPreferences.swift:368`). Die Codex-Seite zeigt ebenfalls einen lokalen Status und nutzt `CodexStatusProbe`, bietet dort aber zusätzlich einen Login-in-Terminal-Pfad über `openLoginInTerminal()` (`WhisperM8/Views/CodexSettingsView.swift:8`, `WhisperM8/Views/CodexSettingsView.swift:37`, `WhisperM8/Views/CodexSettingsView.swift:43`, `WhisperM8/Views/CodexSettingsView.swift:47`, `WhisperM8/Services/Dictation/CodexSupport.swift:188`). Die History-Seite ist der vollständige Zielort für Reports: Sie zeigt Liste, Suche, Scope-Filter, Status-Menü, Detailansicht und Löschfunktion (`WhisperM8/Views/OutputHistoryView.swift:52`, `WhisperM8/Views/OutputHistoryView.swift:70`, `WhisperM8/Views/OutputHistoryView.swift:82`, `WhisperM8/Views/OutputHistoryView.swift:85`, `WhisperM8/Views/OutputHistoryView.swift:105`, `WhisperM8/Views/OutputHistoryView.swift:140`, `WhisperM8/Views/TranscriptReportDetailView.swift:28`).

`OutputReportComponents.swift` ist nicht direkt in `OutputOverviewView` verbaut, bildet aber die gemeinsamen Report-Bausteine der History-Detailansicht: `ReportCard`, `ReportKeyValue`, `ReportTextBlock`, `CopyToClipboardButton` und `TranscriptAttachmentCard` (`WhisperM8/Views/OutputReportComponents.swift:4`, `WhisperM8/Views/OutputReportComponents.swift:25`, `WhisperM8/Views/OutputReportComponents.swift:47`, `WhisperM8/Views/OutputReportComponents.swift:80`, `WhisperM8/Views/OutputReportComponents.swift:102`, `WhisperM8/Views/TranscriptReportDetailView.swift:41`, `WhisperM8/Views/TranscriptReportDetailView.swift:84`, `WhisperM8/Views/TranscriptReportDetailView.swift:100`, `WhisperM8/Views/TranscriptReportDetailView.swift:118`, `WhisperM8/Views/TranscriptReportDetailView.swift:133`). Die Overview nutzt stattdessen eigene lokale Komponenten `LastOutputCard` und `LastOutputPreview` (`WhisperM8/Views/OutputOverviewView.swift:72`, `WhisperM8/Views/OutputOverviewView.swift:112`).

## 6. UX-Beobachtungen (Rohmaterial fürs Redesign)

1. **Unklare Verortung als Settings-Seite:** Die Seite enthält nur einen echten Setting-Schreibzugriff (`defaultOutputModeID`), während Codex-Status und Last Output Diagnose- beziehungsweise Dashboard-Inhalte sind (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:45`). Das spricht dafür, „Overview" eher als Output-Dashboard oder Summary-Startseite zu behandeln als als klassische Einstellungsseite (`WhisperM8/Views/SettingsView.swift:6`, `WhisperM8/Views/SettingsView.swift:100`, `WhisperM8/Views/SettingsView.swift:128`).

2. **Redundanz und Asymmetrie zur History:** Die Overview zeigt den letzten Report nur kompakt und springt zur History, während die History selbst Reports lädt, filtert, durchsucht, detailliert darstellt und löschen kann (`WhisperM8/Views/OutputOverviewView.swift:91`, `WhisperM8/Views/OutputOverviewView.swift:100`, `WhisperM8/Views/OutputHistoryView.swift:70`, `WhisperM8/Views/OutputHistoryView.swift:82`, `WhisperM8/Views/OutputHistoryView.swift:85`, `WhisperM8/Views/TranscriptReportDetailView.swift:31`, `WhisperM8/Views/TranscriptReportDetailView.swift:35`). Die Overview liest aber keine persistierte History nach, sodass nach einem App-Neustart trotz vorhandener Reports „No output yet" möglich ist, weil die Bedingung nur `AppState.lastTranscriptRunReport` und `AppState.lastRawTranscription` prüft (`WhisperM8/Models/AppState.swift:34`, `WhisperM8/Models/AppState.swift:42`, `WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputOverviewView.swift:55`, `WhisperM8/Views/OutputHistoryView.swift:127`, `WhisperM8/Views/OutputHistoryView.swift:128`).

3. **Doppelte Default-Mode-Orte:** „Output Overview" und „Modes" schreiben denselben Key `defaultOutputModeID`, wodurch ein zentraler Wert an zwei Stellen änderbar ist (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Views/OutputModesView.swift:143`, `WhisperM8/Views/OutputModesView.swift:146`, `WhisperM8/Views/OutputModesView.swift:378`). Zusätzlich ist der Fallback im Working Tree uneinheitlich: `OutputOverviewView` und `AppPreferences` fallen auf `clean`, `OutputModesView` auf `raw` (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Support/AppPreferences.swift:85`, `WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Models/OutputMode.swift:127`, `WhisperM8/Models/OutputMode.swift:128`).

4. **Sprachmix DE/EN:** Die sichtbaren Strings dieser Seite sind Englisch, etwa „Default Output", „Default Mode", „New recordings start with this mode.", „Check Again", „Set up Codex", „Last Output", „Open in History" und „No output yet" (`WhisperM8/Views/OutputOverviewView.swift:14`, `WhisperM8/Views/OutputOverviewView.swift:15`, `WhisperM8/Views/OutputOverviewView.swift:21`, `WhisperM8/Views/OutputOverviewView.swift:35`, `WhisperM8/Views/OutputOverviewView.swift:39`, `WhisperM8/Views/OutputOverviewView.swift:45`, `WhisperM8/Views/OutputOverviewView.swift:56`, `WhisperM8/Views/OutputOverviewView.swift:103`). Gleichzeitig enthalten Code-Kommentare im selben File Deutsch, etwa beim History-Sprung und beim Report-Fallback (`WhisperM8/Views/OutputOverviewView.swift:9`, `WhisperM8/Views/OutputOverviewView.swift:51`, `WhisperM8/Views/OutputOverviewView.swift:70`, `WhisperM8/Views/OutputOverviewView.swift:71`).

5. **Codex-Setup-Pfad ist schwächer als auf der Codex-Seite:** „Output Overview" öffnet nur eine Webseite, während `CodexSettingsView` einen direkten Login-in-Terminal-Button über `CodexStatusProbe().openLoginInTerminal()` anbietet (`WhisperM8/Views/OutputOverviewView.swift:39`, `WhisperM8/Views/OutputOverviewView.swift:40`, `WhisperM8/Views/CodexSettingsView.swift:43`, `WhisperM8/Services/Dictation/CodexSupport.swift:188`, `WhisperM8/Services/Dictation/CodexSupport.swift:198`, `WhisperM8/Services/Dictation/CodexSupport.swift:210`). Dadurch ist die Overview als Setup-Einstieg weniger handlungsstark als die dedizierte Codex-Seite (`WhisperM8/Views/CodexSettingsView.swift:37`, `WhisperM8/Views/CodexSettingsView.swift:43`, `WhisperM8/Views/CodexSettingsView.swift:47`).

## 7. Offene Fragen

1. Soll `Output Overview` dauerhaft eine Settings-Section bleiben oder als Output-Dashboard aus dem Settings-Fenster herausgelöst werden? Der aktuelle Code platziert sie in der Settings-Sidebar-Gruppe „Output", obwohl zwei von drei Sections nicht persistente Einstellungen sind (`WhisperM8/Views/SettingsView.swift:6`, `WhisperM8/Views/SettingsView.swift:100`, `WhisperM8/Views/OutputOverviewView.swift:26`, `WhisperM8/Views/OutputOverviewView.swift:45`).

2. Soll der Default-Fallback für `defaultOutputModeID` fachlich `clean` oder `raw` sein? `OutputOverviewView` und `AppPreferences` verwenden `clean`, `OutputModesView` verwendet `raw` (`WhisperM8/Views/OutputOverviewView.swift:6`, `WhisperM8/Support/AppPreferences.swift:85`, `WhisperM8/Views/OutputModesView.swift:10`, `WhisperM8/Models/OutputMode.swift:127`, `WhisperM8/Models/OutputMode.swift:128`).

3. Soll die Overview beim Öffnen den neuesten persistierten Report aus `TranscriptRunReportStore` laden, damit „Last Output" nach App-Neustart konsistent mit der History ist? Aktuell liest die Overview nur `AppState`, während die History explizit `store.recentReports(limit: 200)` lädt (`WhisperM8/Views/OutputOverviewView.swift:46`, `WhisperM8/Views/OutputOverviewView.swift:50`, `WhisperM8/Views/OutputHistoryView.swift:127`, `WhisperM8/Views/OutputHistoryView.swift:128`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:179`).
