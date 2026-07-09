# WhisperM8 Refactoring Plan

## Gegenpruefung des fremden Plans

Geprueft am 2026-05-11 gegen `analysis/refactoring-2026-05-11/refactoring-plan.md` und ergaenzend gegen dessen `overview.md`/`findings.md`. Der fremde Plan wurde nicht veraendert. Uebernommen wurden nur Punkte, die im aktuellen Code nachvollziehbar waren.

### Uebernommen oder angepasst

- [Gegenpruefung uebernommen] Test-Fundament sollte explizit CI, Test-Helpers und Testfile-Splitting enthalten. Es gibt aktuell keinen `.github/workflows`-Eintrag; `AgentChatsTests.swift` ist sehr gross und Helper-Duplikation ist plausibel.
- [Gegenpruefung uebernommen] Legacy-Workspace-Decode ist ein reales Datenverlust-Risiko: `AgentChatSession.imagePaths` und `hasLaunchedInitialPrompt` sind nicht optional, waehrend `AgentSessionStore.loadWorkspace()` Decode-Fehler schluckt und `.empty` liefert.
- [Gegenpruefung uebernommen] `AgentWorkspace` hat kein `schemaVersion`; Schema-Safety und Backup-/Recovery-Verhalten gehoeren vor tiefere Store-Refactors.
- [Gegenpruefung uebernommen] Headless-CLI-Aufrufe fuer Auto-Naming/Summaries haben keinen Wallclock-Timeout; ein haengender Prozess kann In-Flight-State blockieren.
- [Gegenpruefung uebernommen] `TranscriptRunReportStore` hat keine Retention/Rotation; bei visuellen Attachments kann der Reports-Ordner unbegrenzt wachsen.
- [Gegenpruefung uebernommen] `WindowRequest.outputDashboard` mappt auf das Settings-Window, aber `SettingsView` startet mit `.api`; Routing/Selection muss explizit modelliert werden.
- [Gegenpruefung uebernommen] `make install` sollte denselben LaunchServices-Register-Schritt wie `make dev` nutzen.
- [Gegenpruefung uebernommen] `Defaults` ist als Dependency eingebunden, im Code aber nicht genutzt. Daraus folgt nicht automatisch eine Migration zu `Defaults`; zunaechst ist das ein Hygiene-/Build-Entscheidungspunkt.

### Bewusst nicht uebernommen

- Der fremde Plan behauptet einen `<0.3 s`-`isProcessing`-Leak in `RecordingCoordinator.stopRecording()`. Im aktuellen Code liegt der Early-Return in Zeile 151-153 vor `isProcessing = true` in Zeile 157. Nicht als Fakt uebernommen.
- `BranchTag` wurde nicht als sofort zu loeschender Dead Code uebernommen. `rg` findet aktuell nur die Definition, aber der Verlauf nennt Project-Inspector-Nutzung als Absicht. Loeschung nur nach separater Produkt-/Code-Entscheidung.
- Snapshot-Tests als harte Voraussetzung wurden nicht uebernommen. Im Repo existiert keine Snapshot-Test-Infrastruktur; fuer diesen Plan bleiben sie optional, waehrend Unit-Tests und manuelle Smoke-Checks Pflicht sind.
- `AgentSessionStore` direkt als `@MainActor ObservableObject`/Singleton umzubauen wurde nicht uebernommen. Das waere ein staerkerer Architekturentscheid als no-breaking Refactor. Der Plan bleibt bei Repository/serialer Mutations-API als Zwischenschritt.
- Eine komplette Migration von `AppPreferences` auf `Defaults` wurde nicht uebernommen. Verifiziert ist nur die ungenutzte Dependency; ob Migration oder Dependency-Entfernung besser ist, bleibt offen.

### Angepasste Risiken und Reihenfolge

- Schema-/Decode-Safety wurde nach vorne gezogen, weil sie Datenverlust verhindern kann und vor Store-Koordinatoren sinnvoll ist.
- Headless-CLI-Timeouts und Report-Retention wurden als eigene Service-Hardening-Arbeiten ergaenzt.
- CI/Test-Helpers wurden in Phase 0 aufgenommen.
- Build-/Deployment-Phase nennt jetzt auch `make install`/`lsregister`.

### Offene Fragen fuer den finalen Gesamtplan

- Soll das Xcode-Projekt entfernt, synchronisiert oder klar als nicht-kanonisch dokumentiert werden?
- Soll `Defaults` genutzt werden oder aus `Package.swift` entfernt werden?
- Welche Report-Retention-Defaults sind produktseitig akzeptabel: Alter, Anzahl, Gesamtgroesse?
- Soll Tab-Reihenfolge langfristig identisch mit Sidebar-Reihenfolge bleiben oder getrennt werden?
- Soll eine Snapshot-Test-Infrastruktur eingefuehrt werden oder reichen Unit-Tests plus manuelle UI-Smokes?

## Grundsaetze

- Keine Breaking Changes, keine Feature-Aenderungen.
- Zuerst Tests und reine Extraktionen, dann Koordinatoren.
- Build-/Signing-/Bundle-ID-/LSUIElement-Aenderungen nur explizit und separat.
- `make dev` bleibt Entwicklungsstandard; Refactor-Schritte sollten mit `swift test` und mindestens `make build` validiert werden.

## Phase 0 - Absicherung und Hygienetests

Ziel: Refactors absichern, ohne Verhalten zu aendern.

- Tests hinzufuegen:
  - [Gegenpruefung uebernommen] Legacy-Workspace ohne `imagePaths` und `hasLaunchedInitialPrompt` muss dekodieren und bestehende Sessions behalten.
  - [Gegenpruefung uebernommen] Decode-Failure-Pfad fuer korrupte Workspace-Datei muss beobachtbar und recoverbar werden; vor Implementierung mindestens Test fuer aktuelles `.empty`-Risiko dokumentieren.
  - DnD Self-drop ist No-op.
  - DnD stale IDs und unvollstaendige `orderedIDs`.
  - UTI-Strings in Code vs. `Info.plist`.
  - `OutputModeStore` mit doppelten/korrupteren IDs soll nicht crashen.
  - `AgentSessionStore` konkurrierende Mutationssimulation oder serialisierte Mutations-API vorbereiten.
  - [Gegenpruefung uebernommen] `TranscriptRunReportStore` Retention-Verhalten fuer `maxAge`, `maxCount` oder `maxBytes` vorbereiten.
- Teststruktur:
  - [Gegenpruefung uebernommen] `Tests/WhisperM8Tests/Helpers/` fuer Temp-Dateien, Preference-Isolation und wiederverwendbare Mocks anlegen.
  - `AgentChatsTests.swift` in thematische Testfiles aufteilen: CommandBuilder, Indexer, Store, Runtime, AutoNamer, DnD, Theme.
  - Index-basierte Assertions in `OutputDashboardTests` durch ID-basierte Assertions ersetzen.
- [Gegenpruefung uebernommen] Minimalen CI-Workflow fuer `swift build` und `swift test` auf macOS ergaenzen, sofern das Repo GitHub Actions verwenden soll.
- `make test`/`make ci` als Komfortziele pruefen; nur aufnehmen, wenn sie den kanonischen SwiftPM-Pfad ohne Xcode-Projekt nutzen.

Risiko: niedrig.

Vorher/Nachher: `swift test`. Wenn CI ergaenzt wird: lokaler `swift build` + `swift test` vor Push.

## Phase 1 - Mechanische View-Splits ohne Logikverlagerung

Ziel: Dateigroessen senken und spaetere Refactors lokalisieren.

- `AgentChatsView.swift` splitten:
  - `AgentChatsSidebarView.swift`
  - `AgentChatsHeaderView.swift`
  - `ProjectChatGroup.swift`
  - `SessionManagementMenu.swift`
  - `ProjectDetailPanel.swift`
  - `AgentSessionDetailView.swift`
  - `AgentResourceSummaryView.swift`
  - `AgentTheme.swift`
  - `AgentChatsWindowConfigurator.swift`
- `OutputDashboardView.swift` splitten:
  - `TranscriptReportsView.swift`
  - `TaskReportsView.swift`
  - `OutputModesView.swift`
  - `OutputTemplatesView.swift`
  - `CodexSettingsView.swift`
  - `OutputTestLabView.swift`
- Kleine Sheets extrahieren:
  - `RenameSessionSheet`
  - `RenameProjectSheet`

Risiko: niedrig bis mittel, hauptsaechlich SwiftUI-Compile/Access-Control.

Vorher/Nachher: `swift test`, `make build`. Visueller Smoke via `make dev` falls UI-Dateien groesser verschoben wurden.

## Phase 2 - Pure Helper und Presenter extrahieren

Ziel: Logik testbar machen, aber noch keine grossen Laufzeitkoordinatoren ersetzen.

- `AgentSessionOrdering`:
  - `makeSessionOrder(...)`
  - `makeProjectOrder(...)`
  - Self-drop, hidden sessions, stale IDs.
- `AgentSessionPresentation`:
  - sichtbare Sessions fuer Sidebar/Tabs.
  - Labels, Runtime-Text, Provider-Farbe, default title checks.
- `AgentGitStatusService`:
  - `GitProjectStatus` aus View-Datei herausziehen.
- `AgentThemeTokens`:
  - SwiftUI/AppKit/Terminal-Farbwerte zentralisieren.
- [Gegenpruefung uebernommen] `Color.dynamic`, `Color(hex:)`, `String.nilIfEmpty` und statische Swatch-Farbkonvertierung aus `AgentChatsView.swift` herausziehen; Werte unveraendert lassen.
- `ReportBrowserView(filter:title:)` fuer Transcript/Task Reports.
- `OutputModesView` Store-Initialisierung vereinheitlichen.
- [Gegenpruefung uebernommen] `AgentSessionDropCoordinator` bzw. `DragDropCoordinator` als pure Value-Type pruefen, bevor die UI-Drop-Targets erweitert werden.

Risiko: niedrig bis mittel.

Vorher/Nachher: gezielte Unit-Tests plus `swift test`.

## Phase 3 - Agent-Chat-Koordinatoren einfuehren

Ziel: `AgentChatsView` von Domain-Orchestrierung entlasten.

- `AgentWorkspaceRepository`:
  - Laden/Speichern/Migration.
  - Zunaechst gleiche JSON-Datei und gleiche Codierung beibehalten.
  - Serielle Mutations-API einfuehren.
  - [Gegenpruefung uebernommen] `schemaVersion` und Backup-/Recovery-Strategie fuer inkompatible oder korrupte Workspace-Dateien planen. Nicht still `.empty` als einziger Pfad.
  - [Gegenpruefung uebernommen] Legacy-Defaults fuer fehlende non-optionale Session-Felder per custom Decode oder kompatibler Modellmigration absichern.
- `AgentSessionRefreshCoordinator`:
  - Index-Cache laden.
  - Codex/Claude indexieren.
  - Workspace mergen.
  - Stale running sessions behandeln.
  - [Gegenpruefung uebernommen] Indexer-Cache-Eviction fuer geloeschte JSONL-Dateien pruefen.
- `AgentSessionLifecycleCoordinator`:
  - Start/Resume/Terminate.
  - `markLaunched`, `markTerminated`.
  - External-ID-Bind mit Retry statt fixer 1,5s-Einmalprobe.
- `AgentSessionEnrichmentCoordinator`:
  - Auto-Naming.
  - Summary-Generierung.
  - In-flight Status.
  - [Gegenpruefung uebernommen] gemeinsamer Headless-CLI-Runner mit Timeout fuer Auto-Naming und Summaries.
  - [Gegenpruefung uebernommen] gemeinsamer JSONL-Reader fuer Indexer/Watcher/Transcript-Locator pruefen.
- `AgentChatSelectionCoordinator`:
  - `AppState.activeAgentChat`-Sync kapseln.

Risiko: mittel bis hoch, weil Agent-Chats viele Nebenlaeufigkeiten haben.

Vorher benoetigte Tests:

- Store-Mutation und Merge-Policy.
- Lifecycle Start/Terminate/Binder mit Fake Indexer.
- Auto-Namer respektiert manuelle Titel.
- Summary-In-Flight.
- Headless-CLI-Timeout raeumt In-Flight-State auf.
- Selection-Sync.

Nachher: `swift test`, `make build`, manuelle Agent-Chats-Smoke-Tests: Session erstellen, starten, terminieren, scannen, Titel generieren, Summary, DnD, Project-Icon.

## Phase 4 - RecordingCoordinator testbar zerlegen

Ziel: wichtigste User-Journey absichern und Verantwortlichkeiten trennen.

- Protocols/Fakes einfuehren:
  - `AudioRecording`
  - `OverlayControlling`
  - `PasteDelivering`
  - `KeychainProviding`
  - `TranscriptionServiceFactory`
  - `PermissionChecking`
  - `PasteboardProviding`
  - `Clock/Sleeper`
  - `ProcessRunning`
- Teilkoordinatoren:
  - `RecordingSessionController`: Start/Stop/Cancel, Timer, Audio-Ducking.
  - `TranscriptionPipeline`: Provider/API, Normalisierung, Fehler.
  - `PostProcessingPipeline`: OutputMode, Codex, Fallback.
  - `DeliveryPipeline`: Clipboard, Auto-Paste, Attachments.
  - `TranscriptRunReporter`: Report-Draft und Persistenz.

Risiko: hoch, da Kernworkflow.

Vorher benoetigte Tests:

- Start setzt `isRecording`, Kontext, Overlay.
- Stop friert OutputMode/Kontext ein.
- fehlender API-Key.
- STT-Fehler.
- Postprocessing-Fallback.
- Auto-Paste an/aus.
- Report-Felder.

Nachher: `swift test`, `make build`, manueller Recording-Smoke mit Mikrofon, Auto-Paste aus/an, Screenshot-Kontext, ScreenClip, Cancel.

## Phase 5 - Menues, Commands und Routing konsolidieren

Ziel: macOS-konforme Discoverability und weniger Menu-Drift.

- `AppRoute`/`AppCommand` zentralisieren.
- `.commands` in `WhisperM8App` fuer:
  - Settings
  - Agent Chats
  - Output & Templates
  - New Chat
  - Scan Sessions
  - Toggle Sidebar/Inspector
  - Rename Session
- `WindowRequestCenter` explizit in App-Shell hosten.
- [Gegenpruefung uebernommen] `outputDashboard`-Route korrigieren: entweder eigenes Window fuer `OutputDashboardView` oder Settings-Route mit expliziter Start-Selection in den Output-Bereich.
- Session-/Project-Menu-Definitionen vereinheitlichen.
- [Gegenpruefung uebernommen] Settings-Zeile `Agent Chats` als Launcher oder echte Settings-Seite klaeren; aktuell oeffnet die Zeilenauswahl direkt das Agent-Chats-Window.

Risiko: mittel.

Tests: Routing-Unit-Tests, WindowRequestCenter reset/isolation, ggf. leichte UI-Smoke-Tests.

## Phase 6 - Build-/Deployment-Aufraeumen

Ziel: eine kanonische Build-Quelle und weniger Release-Risiko.

- Entscheiden:
  - Xcode-Projekt entfernen/ignorieren oder voll synchronisieren.
  - `scripts/build.sh`/`run.sh` auf Makefile umleiten.
- Version aus `Info.plist`/Bundle lesen.
- Ressourcenliste zentralisieren oder Makefile-Kommentare/Tests fuer Assets.
- [Gegenpruefung uebernommen] `make install` denselben LaunchServices-Register-Schritt wie `make dev` ausfuehren lassen; ideal als gemeinsames Makefile-Rezept.
- Release-Gates dokumentieren:
  - codesign verify
  - entitlements inspect
  - `spctl`
  - notary submit + staple

Risiko: mittel, wegen TCC/Signing/Bundle-ID.

Tests/Checks: `make clean`, `make build`, codesign verify. Keine Bundle-ID-/LSUIElement-Aenderung in derselben Phase.

## Phase 7 - Kleine Hygiene-PRs

Ziel: lokale Qualitaetslast reduzieren.

- `Transcribing`/`TranscriptionRequest` entfernen oder integrieren.
- `PostProcessingService.didTimeout` synchronisieren.
- Audio-Tap-Installation extrahieren.
- `SelectedContextService` Force-Cast entfernen.
- `import Combine` in `AudioRecorder` entfernen, falls wirklich ungenutzt.
- `lastSelectedOutputModeID` Semantik klaeren: verwenden oder entfernen.
- [Gegenpruefung uebernommen] `TranscriptRunReportStore.cleanup(maxAge:maxCount:maxBytes:)` als isolierten Service-Refactor umsetzen, wenn Produktdefaults geklaert sind.
- [Gegenpruefung uebernommen] Ungenutzte `Defaults`-Dependency pruefen: entweder gezielt nutzen oder aus Manifest/Doku entfernen.
- [Gegenpruefung uebernommen] `ClaudeThemeWriter` Retry nach transientem Parse-Fail pruefen; Code ueberschreibt bei Parse-Fail aktuell korrekt nicht, versucht aber auch nicht automatisch erneut.
- [Gegenpruefung teilweise uebernommen] Dead-Code-Kandidaten nur nach `rg` und Produktcheck entfernen: `HeaderIconButton` wirkt ungenutzt; `BranchTag` bleibt offen wegen widerspruechlichem Verlaufskontext.

Risiko: niedrig bis mittel.

Tests: gezielte Unit-Tests plus `swift test`.

## Priorisierung

1. Phase 0 und 1: schnellster Wartbarkeitsgewinn mit niedrigem Risiko.
2. Phase 2 und 3: Agent-Chats stabilisieren, weil dort die groesste aktuelle Komplexitaet liegt.
3. Phase 4: Recording-Kernworkflow erst nach Testseams refactoren.
4. Phase 5 und 6: UX/Build-Konsolidierung separat halten.
5. Phase 7: laufend als kleine PRs, aber nicht mit grossen Architekturphasen vermischen.
