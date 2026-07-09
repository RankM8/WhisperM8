# Executive Summary — WhisperM8 Refactoring-Analyse

**Stand**: 2026-05-11 · Branch `codex/agent-chats-session-hub` @ `eddb0c6`
**Scope**: nicht-destruktive Analyse + Refactoring-Plan. Keine Code-Änderungen.
**Methode**: 8 Opus-Subagents parallel, jeweils auf einen klar abgegrenzten Bereich. Ergebnisse in `subagent-notes/01-*.md` bis `08-*.md` konsolidiert.
**Cross-Check (v2)**: Plan wurde gegen den parallelen Plan unter `analysis-refactoring/` gespiegelt. Übernahmen sind im `refactoring-plan.md` mit `[v2]` markiert (siehe Cross-Check-Sektion am Ende). 2 neue Phasen (13a Window-Routing, 13b Build-Drift) ergänzt; Gesamtaufwand 15-19 → 17-21 Tage.

---

## 1. Codebase in Zahlen

- **58 App-Swift-Files** (~18 000 LOC) + **6 Test-Files** (~2 500 LOC) — Test:Code-Ratio ~1:7.
- **148 Tests**, alle deterministisch (kein Network, keine echten Subprocesses).
- **Kein CI**, keine Snapshot-Tests, keine UI-Tests.
- **Größte Files**: AgentChatsView.swift (**3 208 LOC**), OutputDashboardView.swift (1 332), RecordingCoordinator.swift (884), SettingsView.swift (765), RecordingOverlayView.swift (630), OnboardingView.swift (615), AgentSessionStore.swift (561), PostProcessingService.swift (539).

---

## 2. Top 5 Befunde

### 1. **AgentChatsView.swift ist ein Monolith (hoch)**
3 208 LOC mit 17 inline-`private struct`s und 35 Helpers. SwiftUI-Compiler gibt bereits "unable to type-check this expression in reasonable time" auf einer Aufrufstelle. Das File hostet Sidebar, Tab-Strip, Inspector, alle Drag-Drop-Coordinators, das Theme, drei Color-Helpers und das `GitProjectStatus`-Shell-out. Empfehlung: schrittweise Extraktion in `Views/AgentChats/{Sidebar,TabStrip,Workspace,Inspector,Components,Resources}/` plus 3 Theme/Color-Helpers nach `Support/`. **Nach Phase 3 schrumpft das File auf ~1500 LOC, am Ende auf ~300 LOC Orchestration.**

### 2. **Silent-Data-Loss-Bug bei alten Workspace-JSONs (hoch)**
Zwei Felder auf `AgentChatSession` (`imagePaths`, `hasLaunchedInitialPrompt`) sind **nicht** optional. Workspace-JSONs aus früheren Versionen failen JSONDecoder, der Catch-Block (`AgentSessionStore.swift:30-33`) swallowt den Error und gibt `.empty` zurück → **User verliert kompletten Workspace stillschweigend**. Es gibt weder eine `.bak`-Rotation noch eine sichtbare Fehlermeldung. **Fix ist ein Einzeiler pro Feld + Backup-Recovery beim Decode-Fail.**

### 3. **AgentSessionStore-Concurrency-Race (hoch)**
Store ist `struct`, jeder Mutator macht `load → mutate → save`. Atomic-Write schützt nur Reader vor Half-State, **nicht** vor Lost-Updates. Background-Writer aus AutoNamer + Summarizer + RuntimeWatcher (`lastTurnAt`) racen mit UI-Mutationen. Zusätzlich wird der Store **5× separat instantiiert** (3× in AgentChatsView, 1× in AgentChatLaunchService, 1× in RecordingCoordinator). **Fix**: NSLock im Store + single-instance via Environment-Object.

### 4. **RecordingCoordinator (884 LOC) hat 5 Verantwortungen + besitzt NSPanel aus Service-Layer (hoch)**
Mutiert AppState an 94 Stellen, owned NSPanel über OverlayController, importiert AppKit aus dem Service-Layer. Hat einen konkreten Bug (`<0.3 s` early-return leakt `isProcessing = true`, blockiert nachfolgende Stops). Audio-State-Machine ist implicit aus 5 Booleans über 3 Owner. **Fix**: 3-Way-Split (Lifecycle / ContextBundle / TranscriptionPipeline) + `RecordingPhase`-Enum + OverlayController raus aus Services/.

### 5. **AppState god-object + 10 Singletons (hoch/mittel)**
`AppState.shared` hat 18+ mutable observable Properties + Coordinator, wird aus ~31 View-Sites gelesen. Insgesamt **10 Singletons** in der App, einer davon (`AppPreferences.shared`) sogar `static var` (mutable!) statt `let`. **Fix**: AppState in `RecordingState` / `ContextState` / `PostProcessingState` splitten; AppState bleibt als Façade während Migration.

---

## 3. Risiko-Matrix Kurzfassung

| Severity | Count | Beispiele |
|---|---|---|
| **hoch** | 9 | AgentChatsView-Monolith, AgentSessionStore-Race, non-optional Fields, AppState god-object, RecordingCoordinator, <0.3s-Bug, Service-AppKit-Coupling, AgentTheme `private`, 5× Store-Instanzen |
| **mittel** | 22 | Drag-Drop-UX-Gaps, string-typed Theme-Notification, TranscriptRunReportStore ohne Retention, CLI-Timeout, AgentHeadlessCLI-Duplikation, AppPreferences-Boilerplate, Schema-Version fehlt, User-Cancel = Error, RecordingOverlayView-Größe, dropSession-Branch-Logic, fehlende Tests, kein CI, AgentChatsTests-Monolith, `make install` ohne `lsregister`, … |
| **niedrig** | 15 | Dead Code (Defaults-dep, BranchTag, HeaderIconButton, overlayPositionX/Y), Magic Numbers, hardcoded PHPStorm-Pfad, Indexer-Cache-Eviction, Info.plist-Polish, … |

Vollständige Liste mit File:Line-Belegen: `findings.md`.

---

## 4. Was am System gut ist (NICHT anfassen)

- `AgentTranscriptParser` + `AgentTranscriptStatusDecider` — pure + getestet.
- `ClaudeThemeWriter` — atomic-rename, debounced, idempotent, fail-closed.
- `AgentCommandBuilder`, `LoginShellEnvironment` — gut getestet.
- `AgentSessionStore`-API — 25+ Tests decken Persistenz, Sort, Drag-Drop, Migration ab.
- `AppearanceOverride` + `ThemeManager` — sauber gelöst.
- Drag-Drop UTI-Registrierung via Info.plist + Makefile `lsregister` — funktioniert.
- `AgentTerminalPalette` — sRGB explizit, Light/Dark separat.

---

## 5. Refactoring-Roadmap in 13 Phasen / 4 Sprints

(Details: `refactoring-plan.md`)

### Sprint A — Foundation (1 Woche, niedrig-Risiko)
- **Phase 0**: Test-Helpers, AgentChatsTests-Split in 12 Files, minimaler CI-Workflow.
- **Phase 1**: Bug-Fixes (`<0.3s`-Leak, non-optional Fields + Backup-Recovery, User-Cancel-Differentiation, `make install` `lsregister`).
- **Phase 2**: AgentTheme + Color-Helpers nach `Support/` (höchster ROI, niedrigstes Risiko).

### Sprint B — Strukturelle Säuberung (1 Woche, niedrig-mittel-Risiko)
- **Phase 3**: 11 View-Extraktionen aus AgentChatsView (ProjectChatGroup, DetailView, Inspector, GitProjectStatus, Tab-Strip, Components, Resource-Popover, SessionMenuItems, AgentLayout, editorAppPath-Pref).
- **Phase 4**: AgentSessionStore-Concurrency-Lock + Single-Instance + schemaVersion.
- **Phase 5**: Theme-Notification → Combine; ClaudeThemeWriter retry.

### Sprint C — UX & Services (1 Woche, niedrig-mittel-Risiko)
- **Phase 6**: Drag-Drop `isTargeted:` + DragDropCoordinator + Cross-Project-Cue.
- **Phase 7**: AgentHeadlessCLI mit Timeout, ThrottledOnceTask, JSONLReader, StatusDeciderConfig, Indexer-Cache-Eviction.
- **Phase 8**: AppState-Split + AgentRuntimeServices + AgentWorkspaceCoordinator + AgentSelectionModel + RenameSheetModel.

### Sprint D — Risk-Last + Polish (1 Woche, hoch-Risiko)
- **Phase 9**: RecordingCoordinator 3-Way-Split (braucht alle Vorphasen).
- **Phase 10**: RecordingOverlayView-Extraktionen.
- **Phase 11**: AppPreferences → Defaults.
- **Phase 12**: TranscriptRunReportStore Retention.
- **Phase 13**: Polish-Cleanup (Info.plist-Keys, Magic-Numbers, Debounces, etc.).

**Gesamt-Aufwand**: ~15-19 Tage / 4 Wochen für einen einzelnen Engineer.

---

## 6. Was als Erstes — wenn nur eine Woche zur Verfügung steht

Phase 0 + 1 + 2 — in dieser Reihenfolge, jeweils mit grünem Test-Lauf:

1. **Test-Helpers + AgentChatsTests-Split + CI** (Phase 0)
2. **`<0.3s`-Leak fixen + non-optional Fields → Optional + Backup-Recovery** (Phase 1)
3. **AgentTheme + Color-Helpers nach Support/** (Phase 2)

Ergebnis nach einer Woche:
- Sicherheitsnetz für alle weiteren Phasen
- User-sichtbarer Bug behoben
- Silent-Data-Loss-Bug behoben
- AgentChatsView.swift schrumpft um ~150 LOC
- Andere Views können dieselben Theme-Tokens benutzen (kein 26-fache `Color.white.opacity(...)` mehr in OnboardingView)

---

## 7. Erfolgsmetriken nach allen 13 Phasen

| Metrik | Heute | Nach Refactor |
|---|---|---|
| Längstes File | 3 208 LOC (AgentChatsView.swift) | < 400 LOC |
| AppState Properties | 18+ | ≤ 5 (Façade) |
| AgentSessionStore-Instanzen | 5 | 1 (Environment-Object) |
| AgentChatsView `@State`/`@StateObject` | 24 | ≤ 6 (via Coordinators) |
| Duplizierte Context-Menus | 3 | 1 (`SessionMenuItems`) |
| String-typed Notifications | 1 (Theme) | 0 |
| Headless CLI ohne Timeout | 2 (AutoNamer, Summarizer) | 0 (shared `AgentHeadlessCLI`) |
| Test-Files | 6 | 12+ |
| CI | nein | ja (macos-14) |
| Service-Layer imports AppKit | 1 (RecordingCoordinator) | 0 |
| `AgentTheme` Visibility | `private` | `internal` (reusable) |
| Non-optional v1-incompat Felder | 2 | 0 |
| Concurrency-Race in Store | offen | NSLock / actor |
| Recording-State-Machine | 5 Booleans | 1 enum |

---

## 8. Verfügbare Dokumente

Im Ordner `/Users/giulianocosta/repos/whisperm8/analysis/refactoring-2026-05-11/`:

| Datei | Zweck |
|---|---|
| `overview.md` | Architekturüberblick, Modul-Layout, Datenflüsse, 10 Singletons, Cross-Layer-Leaks, Init-Order, zentrale Risiken |
| `findings.md` | Alle Findings nach Severity (hoch/mittel/niedrig), File:Line-Belege, Refactor-Vorschläge, Test-Pre-Requisites |
| `refactoring-plan.md` | 13 Phasen, Reihenfolge, Abhängigkeiten, Risiko, Tests, Erfolgskriterien, Aufwand |
| `executive-summary.md` | Diese Datei — kurze Zusammenfassung für Plan-Vergleich |
| `subagent-notes/01-architecture.md` | Architektur-Subagent-Output |
| `subagent-notes/02-agent-chats-view.md` | AgentChatsView-Subagent-Output (Extraktionsplan) |
| `subagent-notes/03-stores-persistence.md` | Stores-Subagent-Output |
| `subagent-notes/04-session-services.md` | Session-Services-Subagent-Output |
| `subagent-notes/05-drag-drop.md` | Drag-Drop-Subagent-Output |
| `subagent-notes/06-theme-appkit.md` | Theme/AppKit-Subagent-Output |
| `subagent-notes/07-recording-pipeline.md` | Recording-Pipeline-Subagent-Output |
| `subagent-notes/08-tests-build.md` | Tests + Makefile + Build-Subagent-Output |

---

## 9. Methodische Hinweise für Plan-Vergleich

Dieser Plan wurde so geschrieben, dass:
- **Jedes Finding hat File:Line-Belege** — nicht generische Aussagen.
- **Severity ist konservativ vergeben** — "hoch" nur wenn aktiv schädlich (Data-Loss-Bug, User-sichtbarer Bug, Race-Condition) ODER wenn Lese-Aufwand >2 Stunden pro Änderung.
- **Phasen-Reihenfolge folgt Risiko-Abhängigkeit** — niedrig-Risiko zuerst, hoch-Risiko zuletzt mit voller Test-Coverage.
- **Keine Breaking Changes auf User-sichtbarer Ebene** — Workspace-JSON, Preferences, Hotkeys, TCC bleiben unangetastet.
- **Refactor-Schritte sind einzeln revertierbar** — jeder PR steht für sich, Git-Tag pro Phase.

Ein paralleler Plan eines anderen Agents kann gegen die Phasen-Reihenfolge, gegen die Severities oder gegen die spezifischen File:Line-Belege gespiegelt werden.
