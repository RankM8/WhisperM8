# Remaining Refactoring Plan After Safety Foundations

Stand: 2026-05-11
Basis-Commit: `2f28c9b` (`Refactor agent chat safety foundations`)

Dieser Plan beschreibt die verbleibenden Refactoring-Schritte nach dem ersten
umgesetzten Sicherheits- und Struktur-Slice. Ziel bleibt: keine Breaking
Changes, keine UI-Neugestaltung, keine semantischen Feature-Änderungen. Jeder
Schritt soll einzeln testbar und revertierbar bleiben.

## Bereits Erledigt

- Workspace-Decode ist legacy-kompatibel fuer neue Session-Felder.
- Workspace-Migration schreibt Backups und degradiert Decode-Fehler nicht mehr
  still ohne Recovery-Signal.
- Window-Routing unterscheidet Settings-Window und Output-Section explizit.
- `make dev` und `make install` nutzen denselben In-place-Install-Pfad inkl.
  LaunchServices-Re-Registrierung.
- `scripts/build.sh` und `scripts/run.sh` delegieren auf `make`.
- Headless-CLI-Aufrufe laufen ueber `AgentHeadlessCLI` mit Timeout und
  Exit-Code-Handling.
- Auto-Namer nutzt den gemeinsamen Headless-Runner.
- Drag-and-Drop-Planung liegt in `AgentDragDropPlanner`.
- Report-Retention-API ist in `TranscriptRunReportStore` vorhanden.
- Erste View-Extraktionen sind erfolgt:
  - `AgentTheme`
  - `AgentChatsWindowAccessor`
  - `ClosedSessionSummaryView`
  - `OutputDashboardSection`
  - `OutputReportComponents`
- `RecordingPhase` modelliert die aktuelle UI-Status-Prioritaet.
- Terminal-Farbregression aus `TERM=dumb` / `NO_COLOR=1` ist behoben.
- Teststand nach Umsetzung: `swift test` mit 165 Tests, 0 Fehler.
- App-Baseline: `make dev` erfolgreich.

## Grundregeln Fuer Alle Weiteren Phasen

- Vor jeder Phase: `swift test` und `make build`.
- Nach jeder UI-nahen Phase: `make dev` plus manueller Smoke-Test.
- Keine Persistenz-Schema-Entfernung ohne Migrations- und Legacy-Decode-Test.
- Keine grossen Datei-Splits zusammen mit Logikaenderungen mischen.
- Jede Phase wird als eigener Commit abgeschlossen.
- Bei AppKit-/Window-Aenderungen immer manuell Settings, Agent Chats und Output
  Dashboard oeffnen.
- Bei Terminal-/CLI-Aenderungen immer neuen Claude- und Codex-Chat starten,
  nicht nur bestehende Prozesse betrachten.

## Phase A - View-Monolithen Weiter Zerlegen

Ziel: `AgentChatsView.swift` und `OutputDashboardView.swift` weiter
verkleinern, ohne Layout oder Verhalten zu aendern.

### A1 - Agent Chats Sidebar Extraktion

Dateien:
- `WhisperM8/Views/AgentChatsView.swift`
- neu: `WhisperM8/Views/AgentChatsSidebarView.swift`
- optional neu: `WhisperM8/Views/AgentProjectSidebarRow.swift`
- optional neu: `WhisperM8/Views/AgentSessionSidebarRow.swift`

Vorgehen:
- Sidebar-Header, Projektliste, Session-Zeilen und Suchfeld in dedizierte
  Views verschieben.
- Nur Daten, Bindings und Callbacks uebergeben, nicht den kompletten Store.
- DnD-Callbacks bleiben zuerst in der Root-View und nutzen weiter
  `AgentDragDropPlanner`.

Tests:
- Bestehende DnD-Planner-Tests muessen unveraendert laufen.
- Manuell: Projekt expandieren/collapsen, Session waehlen, Kontextmenues
  pruefen, Session/Projekt draggen.

Risiko: mittel. Layout- und Selection-Regressions moeglich, aber keine
Persistenzlogik betroffen.

### A2 - Agent Chats Header, Tabs Und Menues Extraktion

Dateien:
- `WhisperM8/Views/AgentChatsView.swift`
- neu: `WhisperM8/Views/AgentChatHeaderView.swift`
- neu: `WhisperM8/Views/AgentChatTabStripView.swift`
- neu: `WhisperM8/Views/AgentSessionMenus.swift`

Vorgehen:
- Tab-Strip, Provider-Switch, Restart/More-Menue und shared Session-Menues
  extrahieren.
- Menue-Aktionen als explizite Closures modellieren.
- Keine Aenderung an Menu-Labels oder Tastaturpfaden.

Tests:
- Bestehende Auto-Title-Tests.
- Manuell: Tab schliessen, Restart, Auto-Titel, Session umbenennen,
  Context-Menue in Sidebar und Header vergleichen.

Risiko: mittel.

### A3 - Project Inspector Extraktion

Dateien:
- `WhisperM8/Views/AgentChatsView.swift`
- neu: `WhisperM8/Views/ProjectDetailPanel.swift`
- neu: `WhisperM8/Services/GitProjectStatus.swift`

Vorgehen:
- `ProjectDetailPanel`, Detail-Zeilen und Git-Status-Ermittlung aus der
  Root-View loesen.
- `GitProjectStatus` als Service oder Support-Typ ablegen, weil dort ein
  `Process`-Aufruf steckt.

Tests:
- Neuer Unit-Test fuer `GitProjectStatus` mit temp Git-Repo, wenn sinnvoll.
- Manuell: Inspector ein/aus, Branch-Anzeige, PHPStorm-Button.

Risiko: niedrig bis mittel.

### A4 - Output Dashboard Sections Extraktion

Dateien:
- `WhisperM8/Views/OutputDashboardView.swift`
- neu: `OutputOverviewView.swift`
- neu: `TranscriptReportsView.swift`
- neu: `OutputModesView.swift`
- neu: `OutputTemplatesView.swift`
- neu: `OutputTestLabView.swift`

Vorgehen:
- Section-Views dateiweise extrahieren.
- Store-Initialisierung und lokale `@State`-Properties unveraendert lassen.
- Keine neue Navigationsstruktur einfuehren.

Tests:
- Bestehende `OutputDashboardTests`.
- Manuell: alle Output-Sections oeffnen, Mode/Template editieren, Report
  auswaehlen und loeschen.

Risiko: niedrig, solange reine Datei-Extraktion.

## Phase B - AgentSessionStore In Rollen Trennen

Ziel: Persistenz, Lifecycle und UI-nahe Aktualisierung aus dem monolithischen
Store loesen.

### B1 - WorkspaceRepository Einfuehren

Dateien:
- `WhisperM8/Services/AgentSessionStore.swift`
- neu: `WhisperM8/Services/AgentWorkspaceRepository.swift`

Vorgehen:
- Load/Save/Migration/Backup in `AgentWorkspaceRepository` verschieben.
- `AgentSessionStore` behaelt vorerst dieselbe public API und delegiert.
- `mutateWorkspace` bleibt der atomare Mutationseinstieg.

Tests:
- Legacy workspace decode.
- Corrupt JSON erzeugt Backup.
- Migration schreibt aktuelle Schema-Version.

Risiko: mittel. Persistenzpfad ist kritisch, aber bereits gut getestet.

### B2 - Lifecycle Und Selection/Refresh Grenzen

Neue Typen:
- `AgentSessionLifecycleCoordinator`
- `AgentSessionRefreshCoordinator`
- optional `AgentSessionEnrichmentCoordinator`

Vorgehen:
- Create/Delete/Close/Launch-Metadata von Scan/Refresh und Auto-Enrichment
  trennen.
- Bestehende `AgentSessionStore`-Methoden als Facade erhalten, bis Views
  umgestellt sind.
- Keine sofortige globale Singleton-Architektur einfuehren.

Tests:
- Create/Rename/Delete/Reorder/Move.
- Concurrent-ish Load/Mutate/Save-Sequenzen.
- Stale IDs bei Move/Reorder bleiben No-op.

Risiko: mittel bis hoch. In kleinen Commits arbeiten.

## Phase C - Headless CLI Vollstaendig Vereinheitlichen

Ziel: Auto-Namer, Summarizer und kuenftige Headless-Aufrufe nutzen denselben
Process-Runner.

Dateien:
- `WhisperM8/Services/AgentSessionAutoNamer.swift`
- `WhisperM8/Services/AgentSessionSummarizer.swift`
- `WhisperM8/Services/AgentHeadlessCLI.swift`

Vorgehen:
- `AgentSessionSummarizer` explizit auf `AgentHeadlessCLI`/shared Runner
  ziehen, nicht nur indirekt ueber `AgentTitleGenerator`.
- Fehler-Mapping fuer Timeout, Non-zero Exit und Empty Output vereinheitlichen.
- Logging-Namen getrennt halten: `auto_namer_*` vs. `session_summary_*`.

Tests:
- Timeout.
- Non-zero Exit.
- Empty Output.
- Summary-Parsing bleibt tolerant.

Risiko: niedrig bis mittel.

## Phase D - RecordingCoordinator Schrittweise Teilen

Ziel: Den hoechsten Risiko-Bereich erst nach den aktuellen Sicherheitsnetzen
zerlegen.

### D1 - Recording State Machine Absichern

Dateien:
- `WhisperM8/Models/AppState.swift`
- `WhisperM8/Services/RecordingCoordinator.swift`

Vorgehen:
- `RecordingPhase` um interne Phasen erweitern: `preparing`, `stopping`,
  `delivering`, `failed`.
- UI-Kompatibilitaet erhalten: bestehende Icons/Status-Texte duerfen sich nur
  aendern, wenn ein Test die alte Prioritaet abbildet.
- Too-short Recording-Semantik als Test festhalten.

Tests:
- Start/Stop happy path mit Fakes, soweit moeglich.
- Too-short recording erzeugt keinen haengenden UI-State.
- PostProcessing cancel bleibt kein generischer Fehler.

Risiko: hoch. Erst Statusmodell, dann Extraktion.

### D2 - Boundaries Einfuehren

Protokolle nur dort einfuehren, wo Tests oder echte Plattform-Grenzen gewinnen:
- `AudioRecording`
- `OverlayControlling`
- `PasteDelivering`
- `Transcribing`
- `Clock/Sleeper`
- `ProcessRunning`

Vorgehen:
- Bestehende konkrete Services adaptieren, nicht ersetzen.
- Erst Constructor Injection fuer Tests, dann Logik verschieben.

Tests:
- Transcription failure.
- Overlay cleanup.
- Audio ducking restore.
- Auto-paste unveraendert.

Risiko: hoch.

### D3 - Pipeline-Services Extrahieren

Neue Typen:
- `RecordingLifecycleService`
- `ContextCaptureService`
- `TranscriptionPipeline`
- `TranscriptDeliveryService`

Vorgehen:
- Kleine Extraktionen entlang bestehender Funktionsgrenzen.
- Keine Aenderung an UserDefaults, Keychain oder Provider-Auswahl.

Tests:
- Voller manueller Recording-Smoke-Test nach jedem Commit.

Risiko: hoch.

## Phase E - AppKit, Window Und Theme Boundaries

Ziel: Imperative Desktop-Operationen enger kapseln.

Dateien:
- `WhisperM8/Views/AgentChatsWindowAccessor.swift`
- `WhisperM8/Services/WindowRequestCenter.swift`
- Window-/Panel-nahe Views und Services

Vorgehen:
- `WindowRequestCenter` weiter Richtung `AppRoute`/`AppCommand` strukturieren.
- `WindowRequestHandler` scene-nah halten, nicht in Feature-Views verstecken.
- Window-Background-Farben ueber eine kleine sRGB-AppKit-Bridge zentralisieren.
- Keine Rueckkehr zu `calibratedRed`.

Tests:
- Routing: settings, outputDashboard, agentChats, onboarding.
- Manuell: Theme Light/Dark/System, neue Claude/Codex-Terminals, Settings,
  Output Dashboard.

Risiko: mittel.

## Phase F - Report Retention Produktseitig Aktivieren

Ziel: Die vorhandene Cleanup-API bewusst in den Produktfluss einhaengen.

Dateien:
- `WhisperM8/Services/TranscriptRunReportStore.swift`
- `WhisperM8/Views/OutputDashboardView.swift` bzw. extrahierte Report-Views
- ggf. Settings/Preferences

Offene Produktentscheidung:
- Default nur `maxCount`?
- Kombination aus `maxAge` und `maxBytes`?
- Sichtbarer Settings-Schalter oder stiller konservativer Default?

Empfohlener Default:
- Keine aggressive Loeschung im ersten Schritt.
- Zunaechst manueller Cleanup-Button oder konservativer `maxCount`, der alte
  Runs loescht, aber nie aktuelle Reports.

Tests:
- Missing attachment.
- Orphan cleanup.
- Retention loescht nur erwartete Runs.
- Alte Report-JSONs bleiben lesbar.

Risiko: mittel, weil Daten geloescht werden koennen.

## Phase G - Build-Pfad Und Xcode-Projekt Entscheiden

Ziel: Keine zweite, stale Build-Wahrheit.

Dateien:
- `Package.swift`
- `Makefile`
- `scripts/build.sh`
- `scripts/run.sh`
- `WhisperM8.xcodeproj` falls vorhanden/aktiv

Vorgehen:
- Entscheiden: Xcode-Projekt synchronisieren oder aus aktivem Dev-Pfad
  dokumentiert entfernen.
- Falls behalten: pruefen, ob Sources/Resources/Entitlements mit SwiftPM
  uebereinstimmen.
- Falls entfernen: README/AGENTS/Docs klar auf SwiftPM/Makefile verweisen.

Tests:
- `make build`
- `make dev`
- optional Xcode-Open/Build, falls Projekt behalten wird.

Risiko: niedrig bis mittel.

## Empfohlene Commit-Reihenfolge

1. `Extract agent chats sidebar views`
2. `Extract agent chat header and menus`
3. `Extract project inspector and git status service`
4. `Extract output dashboard sections`
5. `Introduce agent workspace repository`
6. `Split agent session lifecycle responsibilities`
7. `Unify session summarizer headless runner`
8. `Harden recording phase state machine`
9. `Introduce recording coordinator boundaries`
10. `Extract recording pipeline services`
11. `Tighten window and theme boundaries`
12. `Wire report retention policy`
13. `Resolve Xcode project build drift`

## Manueller Smoke-Test Nach UI-/Recording-Phasen

- App startet via `make dev`.
- Es laeuft nur eine WhisperM8-Instanz.
- Settings oeffnet und Theme-Umschaltung funktioniert.
- Output & Templates oeffnet direkt den Output-Bereich.
- Agent Chats oeffnet.
- Sidebar: Projekt auswaehlen, expandieren, filtern.
- Session auswaehlen, Tab schliessen, Restart-Menue pruefen.
- Neuer Claude-Chat und neuer Codex-Chat starten.
- Terminal-Farben sind in neuen Child-Prozessen sichtbar.
- DnD: Projekt-Reorder, Session-Reorder, Session-Move.
- Recording Start/Stop.
- Auto-paste bleibt unveraendert.
- PostProcessing abbrechen erzeugt keinen haengenden Fehlerstatus.

## Stop-Kriterien

Eine Phase wird nicht weiter ausgebaut, wenn:

- `swift test` fehlschlaegt.
- `make build` fehlschlaegt.
- Eine Persistenzmigration nicht durch Legacy-Tests abgesichert ist.
- Ein UI-Split mehr als reine Extraction benoetigt und keine passende Smoke-
  Test-Route existiert.
- Recording/Terminal/Window-Verhalten nur noch manuell geraten statt
  beobachtet wird.
