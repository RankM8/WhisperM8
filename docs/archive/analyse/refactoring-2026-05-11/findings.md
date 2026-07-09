# Findings — WhisperM8 Refactoring-Analyse

Konsolidierte Findings aus den 8 Subagent-Reports. Jede Zeile hat:
- **Severity** `hoch` / `mittel` / `niedrig`
- **Datei:Line**-Referenz
- **Warum es wartungsrelevant ist**
- **Empfohlener Refactoring-Ansatz** (ohne Breaking Changes wo möglich)

Cross-Referenz: A1 = Architektur · A2 = AgentChatsView · A3 = Stores · A4 = Session-Services · A5 = Drag-Drop · A6 = Theme · A7 = Recording · A8 = Tests.

---

## H1 · Hohe Severity

### H1.1 — `AgentChatsView.swift` ist 3208 LOC mit 17 inline-structs und 35 helpers
- **Quelle**: A2
- **Wartungsrelevant**: jede Änderung an Sidebar/Tab-Strip/Inspector zwingt zur Navigation durch das gesamte File; SwiftUI-Compiler bekommt bereits "unable to type-check this expression in reasonable time" auf der `ProjectChatGroup`-Aufrufstelle (290:9).
- **Refactor**: schrittweise Extraktion ohne Verhaltensänderung. Reihenfolge:
  1. `AgentTheme`, `Color.dynamic`, `Color(hex:)`, `String.nilIfEmpty` → `Support/` (low risk).
  2. `ProjectChatGroup` (1705-1959, 255 LOC) → `Views/AgentChats/Sidebar/ProjectChatGroup.swift`.
  3. `AgentSessionDetailView` + `ClosedSessionSummaryView` (2701-3017) → `Views/AgentChats/Workspace/`.
  4. `ProjectDetailPanel` + atoms (2510-2699) → `Views/AgentChats/Inspector/`.
  5. `GitProjectStatus` (3019-3067) → `Services/GitProjectStatus.swift`.
  - Nach 1-4: File schrumpft auf ~2 200 LOC.
  - Mit Coordinator-Extraktion (siehe H1.4) am Ende: ~300-400 LOC reine Orchestration.

### H1.2 — `AgentSessionStore` Concurrency-Race
- **Quelle**: A3 §"Concurrency model", A1, A5 §"Concurrency"
- **Belege**: `AgentSessionStore` ist `struct` (AgentSessionStore.swift:3), jeder Mutator: `loadWorkspace → mutate → saveWorkspace`. Atomic write (`.atomic` AgentSessionStore.swift:50) schützt nur vor *partiellen* Reads, **nicht vor Lost-Updates**. Background-Writer aus AutoNamer + Summarizer + Watcher (`lastTurnAt`) racen mit UI-Mutationen.
- **Refactor**:
  - **Phase 1 (low risk)**: serielle `DispatchQueue` *innerhalb* der Store-Klasse als minimaler Wechsel; alle Mutatoren via `queue.sync` serialisieren.
  - **Phase 2 (middle term)**: Store zu `actor` umbauen, Aufrufer awaiten. Erfordert Test-Refactor.
  - **Vorher Tests**: zwei parallele `updateSession` müssen beide überleben; Reader darf nie Half-State sehen.

### H1.3 — Non-optionale Felder brechen Decode alter Workspaces
- **Quelle**: A3 §"Schema evolution"
- **Belege**: `AgentChatSession.imagePaths: [String]` (AgentChat.swift:185) und `hasLaunchedInitialPrompt: Bool` (AgentChat.swift:186) sind **nicht** optional. Wenn ein Workspace JSON ohne diese Felder geladen wird, scheitert `JSONDecoder` und `AgentSessionStore.loadWorkspace` (AgentSessionStore.swift:30-33) **swallowt den Error und gibt `.empty` zurück**. → User verliert kompletten Workspace silent.
- **Refactor**:
  - Sofort: beide Felder auf Optional umstellen + `init` mit Default für API-Compat.
  - Alternativ: custom `init(from:)` der fehlende Felder mit Defaults füllt.
  - **Vorher Tests**: Decode-Test mit v1-Workspace-JSON, das diese Felder nicht enthält — muss durchgehen, Sessions müssen sichtbar bleiben.
  - Zusätzlich: bei Decode-Failure `.bak`-Backup statt silent `.empty`.

### H1.4 — `AppState` god-object (18+ Properties, 31 View-Reads)
- **Quelle**: A1 §"Top 5 risks"
- **Belege**: Models/AppState.swift:5-106, `@MainActor @Observable`, hält 18 mutable Properties + `RecordingCoordinator`. Reached aus ~31 Views via grep.
- **Refactor**: schrittweise Split.
  1. `RecordingState` (isRecording, isTranscribing, isPostProcessing, audioLevel, recordingDuration, lastError, isScreenClipRecording).
  2. `ContextState` (selectedContext, contextBundle, activeAgentChat, …).
  3. `PostProcessingState` (lastTranscription, lastRawTranscription, lastFinalTranscription, lastOutputMode, lastSelectedContext, lastTranscriptRunReport, postProcessingStatusText).
  - AppState.shared bleibt als Façade mit deprecated re-exports während Migration.
  - **Risiko mittel**: viele Call-Sites, aber rein mechanisch.

### H1.5 — `RecordingCoordinator` = 884 LOC mit 5 Verantwortungen
- **Quelle**: A7 §"Split opportunities", A1
- **Belege**: RecordingCoordinator.swift owned NSPanel via OverlayController (`:19, :45`), mutiert AppState an 94 Stellen, hat fünf disjunkte Concerns (Lifecycle, ContextBundle, Pipeline, ReportBuilder, ErrorMapping).
- **Refactor**: 3-Way-Split (`RecordingLifecycleController`, `ContextBundleEditor`, `TranscriptionPipeline`) + `TranscriptRunReportBuilder` als free function.
  - **Vorher Tests dringend nötig**: 0 Tests heute. Beginne mit Snapshot-Tests + Integration-Tests gegen Mock-Subprocess-Wrapper.
  - **Risiko hoch ohne Tests, mittel mit Tests**.

### H1.6 — `<0.3 s` early-return leakt `isProcessing = true`
- **Quelle**: A7 §"Audio state machine"
- **Belege**: RecordingCoordinator.swift:151-154 — Recording unter 0.3s gibt zurück ohne `isProcessing = false`. Nächster Stop-Call hits Guard at :142 und bailed silent.
- **Refactor**: einzeiliger Bugfix — `isProcessing = false` vor jedem Return-Pfad. **Konkretester Bug der Analyse, sofort fixbar**.

### H1.7 — Service-Layer importiert AppKit und besitzt UI
- **Quelle**: A1 §"Cross-layer leaks", A7
- **Belege**: `Services/RecordingCoordinator.swift:1` importiert AppKit; owned `OverlayController` (`:19, :45`), der einen `NSPanel` hält (`Windows/RecordingPanel.swift:195-197`).
- **Refactor**: `OverlayController` aus `Services/` in eine `Presentation/` oder `Coordinators/` Schicht verschieben. Coordinator exposiert Protocol, Presentation injiziert konkrete Implementation.
- Erst nach H1.5 sinnvoll machbar.

### H1.8 — `AgentTheme` + `Color.dynamic` + `Color(hex:)` sind `private` in AgentChatsView
- **Quelle**: A2 §"Top 10 ROI" Position #1, A6 §"Token placement"
- **Belege**: AgentChatsView.swift:3074-3208 — drei `private` extensions + ein `private enum AgentTheme`. Blockiert Reuse, daher 26 ad-hoc `Color.white.opacity(...)`-Calls in `OnboardingView`, 12 in `RecordingOverlayView`, 4× hardcoded violet RGB in `BranchTag`.
- **Refactor** (höchster ROI, niedrigstes Risiko):
  1. `Support/AgentTheme.swift` (22 Tokens, internal visibility).
  2. `Support/Color+Dynamic.swift` (+ `NSAppearance.isDark` extension).
  3. `Support/Color+Hex.swift`.
  4. `Support/String+NilIfEmpty.swift`.
  - **Zero Verhaltensänderung**: identische Token-Werte.

### H1.9 — `AgentSessionStore` wird 5× instanziiert
- **Quelle**: A1 §"Top 5 risks" Position #3
- **Belege**: AgentChatsView.swift:16 + :928 + :2722, AgentChatLaunchService.swift:11, RecordingCoordinator.swift:595. Kein shared in-memory state — jede Instanz hits Disk neu.
- **Refactor**: `AgentSessionStore` → `@MainActor ObservableObject`-Singleton (oder als environment-Object in WhisperM8App) mit single instance. Kombiniert mit H1.2-Locking gibt das eine echte single source of truth.
- Voraussetzung: H1.2 (Concurrency-Lock).

---

## H2 · Mittlere Severity

### H2.1 — Drei duplizierte Session-Context-Menus
- **Quelle**: A2 §"Duplicated patterns"
- **Belege**: AgentChatsView.swift:756-784, :1386-1417, :1783-1812 — identische "Umbenennen / Titel automatisch generieren / Tab-Farbe / Schließen"-Menus.
- **Refactor**: `SessionMenuItems(session:onRename:onAutoName:onSetColor:onClose:)` View-Builder. Auch "Tab-Farbe"-Palette-Loop 3× dupliziert → `TabColorMenu`.

### H2.2 — `dropDestination`-Wiring 4× kopiert
- **Quelle**: A2 §"Duplicated patterns"
- **Belege**: AgentChatsView.swift:579, :1757, :1778, :1892 — vier near-identische `.dropDestination(for: DraggableSession.self)`-Closures.
- **Refactor**: `View.onSessionDrop(_:)` Modifier-Wrapper.

### H2.3 — `if isSelected ... else if isHovered ... else Color.clear`-Ladder 7×
- **Quelle**: A2 §"Duplicated patterns"
- **Belege**: AgentChatsView.swift:1549, 1931, 2097, 2185, 2264, 2446, 2503.
- **Refactor**: `AgentTheme.rowBackground(isSelected:isHovered:)` helper.

### H2.4 — Drag-Drop: `isTargeted:` fehlt überall außer am Project-Header
- **Quelle**: A5 §"UX gaps vs macOS HIG"
- **Belege**: AgentChatsView.swift:1778 (session row), :579 (tab button), :1757 (trailing spacer) — keine `isTargeted:`-Closure → kein Hover-Highlight.
- **Refactor**:
  1. Sofort: `isTargeted:` mit `@State var dropTargetID: UUID?` an alle drei Drop-Targets.
  2. Optional: Insertion-Line via Overlay-Pattern.

### H2.5 — String-typed Notification für Theme-Wechsel
- **Quelle**: A1, A6 §"Notification vs Combine"
- **Belege**: ThemeManager.swift:75-79 postet `Notification.Name("AgentTerminalController.themeDidChange")` als rohen String; Konsument in AgentTerminalView.swift:267 definiert die Konstante. userInfo cast `["scheme"] as? ColorScheme` failt silent.
- **Refactor**: `AgentTerminalController` subscribet via Combine auf `ThemeManager.shared.$resolvedColorScheme`. Cancellable in `init`, automatisches Cleanup in `deinit`.

### H2.6 — `TranscriptRunReportStore` ohne Retention/Rotation
- **Quelle**: A3 §"TranscriptRunReportStore"
- **Belege**: Services/TranscriptRunReportStore.swift:46-53 schreibt pro Run einen `Reports/<UUID>/`-Ordner mit kopierten Attachments. **Keinerlei Pruning**. Heavy User mit Screenshots/Clips akkumulieren GB.
- **Refactor**:
  - Add `cleanup(maxAge:maxCount:maxBytes:)` policy
  - Aufruf nach jedem `save`
  - Default: 30 Tage / 200 Reports / 2 GB
  - Tests: pin retention behavior

### H2.7 — Headless CLI ohne Timeout
- **Quelle**: A4 §"CLI invocation"
- **Belege**: `AgentTitleGenerator.defaultRunner` (AgentSessionAutoNamer.swift:273-310) hat keinen Wallclock-Timeout. Hängende `claude -p` / `codex exec` pinnen UUID in `inFlight` für immer.
- **Refactor**: `withTimeout(_:operation:)` async helper. Default 30s, configurable. Surface stderr in Error.

### H2.8 — `AgentHeadlessCLI`-Duplikation (AutoNamer + Summarizer)
- **Quelle**: A4 §"Duplication map", §"CLI invocation plumbing"
- **Belege**: argv-Assembly byte-identisch an AgentSessionAutoNamer.swift:216-222 und AgentSessionSummarizer.swift:216-222. `inFlight`-Set-Pattern verdoppelt: `:320, :409-419` vs `:31, :64-75`. JSONL-tail-readers (`BoundedJSONLReader` im Indexer, `readTail` im Watcher) reinventen einander.
- **Refactor**:
  1. `AgentHeadlessCLI` (single Process-Runner mit Timeout).
  2. `ThrottledOnceTask<Key: Hashable>` helper für in-flight tracking.
  3. `JSONLReader` unified namespace (`firstLine`, `firstNLines`, `tail(bytes:)`).
  - `AgentTitleGenerator` wird thin wrapper, Rename in `Models/`.

### H2.9 — Schema-Version fehlt komplett
- **Quelle**: A3 §"Schema evolution"
- **Belege**: AgentWorkspace, AgentSessionIndexCache und alle Models haben **kein** `version`-Feld. Inkompatible Feldänderung = silent fail via failed decode + `.empty` Rückgabe.
- **Refactor**: Add `schemaVersion: Int = 1` field in `AgentWorkspace`; bei Decode prüfen, bei höher als bekannt → `.bak` rotation + Default. Vorbereitung für Modell-Gruppierung (H3.5).

### H2.10 — RecordingCoordinator: User-Cancel = Error
- **Quelle**: A7 §"Error handling matrix"
- **Belege**: `cancelPostProcessing` (RecordingCoordinator.swift:222-226) callt `CodexProcessRegistry.shared.cancel()`, was SIGTERM sendet. Resultat: `appState.postProcessingStatusText = "Abgebrochen…"` aber gleichzeitig `process(...)` wirft `codexUnavailable("Codex wurde abgebrochen.")` → wird `appState.lastError` an :564.
- **Refactor**: Differentiation in `PostProcessingError`: `.userCancelled` vs `.codexUnavailable`. Coordinator ignoriert `.userCancelled` als Fehler.

### H2.11 — RecordingOverlayView 630 LOC mit 11 Sub-Views
- **Quelle**: A7 §"RecordingOverlayView extraction list"
- **Belege**: Views/RecordingOverlayView.swift — `ContextMenuContent` ist 170 LOC, lädt `NSImage(contentsOf:)` synchron im Main-Thread bei jedem Menu-Render.
- **Refactor**: extrahiere `ContextMenuContent`, `AudioLevelBars`, `VisualContextActionButtons`, `OutputModePicker`, `RecordingStatusIndicator` in eigene Files. Cache attachment thumbnails.

### H2.12 — `dropSession` 49 LOC im View mit 2 Branches
- **Quelle**: A2, A5 §"Tab-strip vs sidebar contract"
- **Belege**: AgentChatsView.swift:963-1011. Cross-Project-Move ist **silent** — User dragd Tab von Project A auf Tab von Project B → Session wandert ohne UI-Hinweis.
- **Refactor**:
  1. `DragDropCoordinator.swift` als testbare struct mit pure logic.
  2. Visual cue für Cross-Project-Move (icon/badge auf Header-Overlay).
  3. Unit-Tests für branch-decision.

### H2.13 — `AppPreferences` = 200 LOC manual UserDefaults wrappers
- **Quelle**: A3 §"AppPreferences", A8 §"Dependencies"
- **Belege**: Support/AppPreferences.swift:222-253 30 keys, jeweils 3-8-LOC computed properties. Inkonsistente Default-Handling. **`Defaults` SPM-dep ist deklariert aber laut grep nirgends benutzt** — dead dependency.
- **Refactor**: graduelle Migration zu `sindresorhus/Defaults`. RawRepresentable-Keys nativ, Boilerplate -150 LOC. Migration-Logic für `migrateScreenshotLimitDefaultIfNeeded` bleibt. Während Übergang: dual access.

### H2.14 — Audio State-Machine implicit aus 5 Booleans
- **Quelle**: A7 §"Audio state machine"
- **Belege**: 3 booleans auf AppState (`isRecording`, `isTranscribing`, `isPostProcessing`), 1 auf AudioRecorder (`isRecording`), 1 lokal im Coordinator (`isProcessing`). Mehrere konkrete Race-Conditions:
  - Bluetooth-config-change-fail (AudioRecorder.swift:290-296): `AudioRecorder.isRecording = false` aber `appState.isRecording` bleibt true → Timer läuft weiter, Overlay zeigt "Recording…" ewig.
  - Cancel-during-restart-window.
- **Refactor**: `RecordingPhase` enum als single source. AppState mirror als computed.

### H2.15 — `currentGitBranch` shellt synchron aus `upsertProject`
- **Quelle**: A3 §"AgentSessionStore API surface"
- **Belege**: AgentSessionStore.swift:477-495 spawnt `/usr/bin/git` blocking innerhalb `upsertProject`. Mis-belongs in der Persistenz-Schicht.
- **Refactor**: async `GitMetadataService.branch(at:)` außerhalb des Stores. Auf MainActor cachen.

### H2.16 — `make install` ruft `lsregister -f` nicht
- **Quelle**: A8 §"Makefile review"
- **Belege**: Makefile — `dev` (L65-68) hat `lsregister -f`-Step, `install` (L102-107) macht den gleichen rsync **ohne** den Re-Register-Step. Info.plist-Änderungen (z.B. UTIs) propagieren bei `make install` nicht.
- **Refactor**: rsync + lsregister in `_install_bundle`-Recipe extrahieren, `dev` und `install` beide nutzen sie.

### H2.17 — Drag-Drop Tests fehlen für View-Coordinator-Logic
- **Quelle**: A5 §"Test coverage gaps"
- **Belege**: Store-APIs (`reorderProjects`, `reorderSessions`, `moveSessionToProject`) getestet (AgentChatsTests.swift:1620-1683). **Aber** die `dropSession`/`dropProject`-Branch-Decision in der View ist nicht testbar — eingebettet in struct.
- **Refactor**: `DragDropCoordinator` als pure value type, Tests für `same-project / cross-project / stale-IDs / out-of-bounds-index`.

### H2.18 — `ClaudeThemeWriter` retry-on-parse-fail fehlt
- **Quelle**: A6 §"ClaudeThemeWriter correctness"
- **Belege**: bei Parse-Fail (Claude schreibt mid-write) skippt Writer silent, kein Retry. Theme stays out-of-sync bis zum nächsten User-Toggle.
- **Refactor**: bei `parse_failed` einen einmaligen Retry nach 1s scheduln.

### H2.19 — Test-Setup-Duplikation in AgentChatsTests + 3 Files
- **Quelle**: A8 §"Test setup duplication"
- **Belege**: `makeTempStoreURL` / `makeTempProjectDirectory` 17× in einem File + 6× in `OutputDashboardTests`. `withIsolatedPreferences*` 3× in PreferencesTests/AudioDuckingManagerTests/OutputDashboardTests dupliziert.
- **Refactor**: `Tests/WhisperM8Tests/Helpers/TempFiles.swift` + `PreferenceIsolation.swift` + `MockPostProcessor.swift`.

### H2.20 — `AgentChatsTests.swift` = 1750 LOC, 110 Tests, eine Klasse
- **Quelle**: A8 §"AgentChatsTests organization"
- **Belege**: 13 `// MARK:`-Sections, aber alles in einer Klasse → kein selektives Ausführen pro Service, Parallel-Test-unfreundlich.
- **Refactor**: Split in 12 separate Files (siehe A8 für vollständige Liste), Shared-Helpers in `Helpers/`.

### H2.21 — Kein CI
- **Quelle**: A8 §"CI gap"
- **Belege**: kein `.github/workflows/`, kein Bitrise. 18k LOC + 148 Tests aber niemand verifiziert PRs automatisch.
- **Refactor**: minimaler `swift build` + `swift test --parallel` GitHub-Actions-Workflow auf `macos-14`. ~5 min/Run. Bedingt direkt H1.1-H1.9 (mehr Refactor-Sicherheit).

### H2.22 — Status-Decider config nicht injectable, kein `.errored` aus FS
- **Quelle**: A4 §"Status state-machine"
- **Belege**: AgentSessionTranscript.swift:148-213 — `awaitingInputAfterSeconds = 8`, `idleAfterSeconds = 30` als magic numbers. `.errored` wird nur via `markTerminated`-Subprocess-Exit gesetzt — silent crashes (z.B. user kills parent terminal) bleiben permanent auf `.working`/`.idle`.
- **Refactor**: `StatusDeciderConfig` struct injectable. Add `.staleSinceTooLong → .errored` rule.

---

## H3 · Niedrige Severity

### H3.1 — Dead/stale Code
- **Quelle**: A2 §"#if DEBUG", A8 §"Dependencies", A3 §"AppPreferences"
- **Belege**:
  - `BranchTag` (AgentChatsView.swift:2454-2477): Comment :611-614 sagt "removed from titlebar", aber Type bleibt — verify ob in ProjectDetailPanel noch genutzt.
  - `HeaderIconButton` (:2479-2508): kein Caller in File.
  - `overlayPositionX/Y` Keys (AppPreferences.swift:230-231) — declared, nirgends gelesen.
  - `Defaults` SPM-dep — laut grep kein call site.
  - `ISSoundAdditions` in CLAUDE.md gelistet, aber aus Package.swift schon entfernt.
- **Refactor**: löschen nach Verify (grep-Suche überall).

### H3.2 — `AgentChatsView` magic numbers (~30 hardcoded values)
- **Quelle**: A2 §"Magic numbers worth theming"
- **Belege**: Sidebar-Width `276` (:120), Inspector-Width `292` (:138), Min-Window `920×700` (:141), Tab-Heights `28/22/24`, Row-Heights `36/26`, etc.
- **Refactor**: `AgentLayout` enum mit benannten Konstanten, parallel zu `AgentTheme`.

### H3.3 — Hardcoded `/Applications/PhpStorm.app`
- **Quelle**: A2
- **Belege**: AgentChatsView.swift:1470 — `openSelectedProjectInPHPStorm` hat Pfad fest verdrahtet.
- **Refactor**: `AppPreferences.editorAppPath` mit Picker im Settings-Bereich.

### H3.4 — Indexer-Cache evictet gelöschte Files nie
- **Quelle**: A3 §"Indexer cache"
- **Belege**: AgentSessionIndexer.swift:74-103 — Cache-Entries für inzwischen gelöschte JSONLs werden nie entfernt. Langsamer Disk-Leak bei Users mit tausenden historischen Sessions.
- **Refactor**: in `save` einen Sweep-Step der nicht-mehr-existente Pfade dropped.

### H3.5 — `AgentChatSession` und `AgentProject` Feld-Bloat
- **Quelle**: A3 §"Data-type ergonomics"
- **Belege**: AgentChatSession 19 Properties, AgentProject 12 Properties.
- **Refactor**: nur sinnvoll nach Schema-Version (H2.9). Dann Sub-Strukturen wie `SessionDisplay`, `SessionLaunchState`, `SessionTitleState`, `ProjectIcon`.

### H3.6 — `AgentTerminalPalette` Light amber yellow Contrast Ratio
- **Quelle**: A6 §"AgentTerminalPalette quality"
- **Belege**: Light ANSI Yellow `0xb4 0x6a 0x00` auf Weiß = ~3.7:1, nur AA-large.
- **Refactor**: dunkler tune oder `#if DEBUG`-Assertion via `contrastRatio(_:_:)` helper.

### H3.7 — Date-of-epoch test brittle
- **Quelle**: A8 §"Brittle tests"
- **Belege**: `OutputDashboardTests.testTemplateRenderingReplacesPlaceholders` (L121-147) asserts `"1970-01-01"` — TZ-sensitiv, in non-UTC CI failed.
- **Refactor**: TZ-explizit oder regex.

### H3.8 — `WindowRequestCenter.shared` mutation in Tests
- **Quelle**: A8 §"Brittle tests"
- **Belege**: WindowAndOverlayTests.testWindowRequestCenterStoresLatestRequest mutiert globalen Singleton ohne restore. Parallel-test-hazard.
- **Refactor**: `setUp`/`tearDown` restoren oder DI-fähigen Konstruktor.

### H3.9 — `_bundle` Makefile-Target listet Resources hardcoded
- **Quelle**: A8 §"Makefile review"
- **Belege**: Makefile `_bundle` hat each PNG by name. Bei neuem Asset: 2 Stellen ändern (Makefile + Package.swift).
- **Refactor**: `for f in WhisperM8/Resources/*.png` loop.

### H3.10 — `AppPreferences.shared` ist `static var`
- **Quelle**: A1 §"Top 5 risks", A3
- **Belege**: Support/AppPreferences.swift:4. Tests können swappen (gewollt), aber kein Compiler-Guard gegen versehentliche Mutation in Production.
- **Refactor**: `static let` sobald Tests DI-fähig sind (z.B. via Defaults-Library).

### H3.11 — Info.plist fehlen Polish-Keys
- **Quelle**: A8 §"Info.plist completeness"
- **Belege**: `NSAccessibilityUsageDescription`, `LSApplicationCategoryType`, `CFBundleDevelopmentRegion`, `NSHumanReadableCopyright`, `ITSAppUsesNonExemptEncryption` fehlen.
- **Refactor**: hinzufügen — kein Verhaltensimpakt.

### H3.12 — `AgentChatsWindowAccessor` re-runs `configure` auf jedem updateNSView
- **Quelle**: A6 §"AgentChatsWindowAccessor pattern"
- **Belege**: AgentChatsView.swift `:2381` — wastful, aber idempotent.
- **Refactor**: nur einmal in `makeNSView` oder via `NSWindow.didBecomeKeyNotification`.

### H3.13 — `bindLatestIndexedSession` 5-Sekunden-Tolerance undokumentiert
- **Quelle**: A3 §"Tests needed"
- **Belege**: AgentSessionStore.swift:367 — magic `addingTimeInterval(-5)` ohne Test.
- **Refactor**: Test pinning des Window-Verhaltens, dann Konstante extrahieren.

### H3.14 — Auto-Scroll/Auto-Expand bei Drag fehlen
- **Quelle**: A5 §"Polish improvements"
- **Belege**: kein Auto-Scroll bei langer Project-Liste während Drag; kein Auto-Expand bei Hover über collapsed Group.
- **Refactor**: standard Finder behavior — 600ms hover trigger.

### H3.15 — RecordingPanel `windowDidMove` schreibt jedes Frame
- **Quelle**: A7 §"NSPanel quirks"
- **Belege**: RecordingPanel.swift:160-180 — `windowDidMove` postet `onMove` synchron, der pro Cursor-Delta in `AppPreferences` schreibt.
- **Refactor**: 100ms debounce.

---

## H4 · Tests die VOR Refactors fehlen (Cross-Cut aus allen Reports)

Alle aus A3 §"Tests needed" und A8 §"Coverage matrix":

1. **Decode v1-Workspace ohne `imagePaths`/`hasLaunchedInitialPrompt`** — pre-req für H1.3.
2. **Decode Workspace mit corrupted JSON / unknown field** — pre-req für `.bak`-Recovery.
3. **Concurrent mutators race** auf `AgentSessionStore` — pre-req für H1.2.
4. **`dropSession` branch-decision** (same-project, cross-project, stale-ID, out-of-bounds) — pre-req für H2.12, H2.17.
5. **`moveSessionToProject` Edge-Cases** (source==target, missing target).
6. **`TranscriptRunReportStore.save` mit vanished attachment** — pre-req für retention (H2.6).
7. **Indexer-cache eviction** (delete-file → cache-clean) — pre-req für H3.4.
8. **`AppPreferences.migrateScreenshotLimitDefaultIfNeeded` Idempotenz**.
9. **Headless CLI timeout** simuliert (mock runner mit `Task.sleep`) — pre-req für H2.7.
10. **`AgentSessionRuntimeWatcher` tail-read mit truncated last line** — pre-req für H2.22.
11. **`ClaudeThemeWriter` write-path** (atomic + POSIX-Mode + race-on-parse) — pre-req für H2.18.
12. **`RecordingCoordinator` lifecycle** — Snapshot-Tests + Mock-Audio-Recorder bevor H1.5.
13. **`AudioRecorder` Bluetooth-config-change-fail-Pfad** — pre-req für H2.14.
14. **Snapshot-Tests** für `AgentChatsView`-Right-Pane-States und `RecordingOverlayView`-3-States — pre-req für jegliche visuelle Änderung.

---

## H5 · Was als Erstes — Maximaler Hebel × Niedrigstes Risiko

1. **H1.6** Single-line `isProcessing` Bug-Fix → user-visible.
2. **H1.8** AgentTheme + Color helpers nach Support/ → unblockt 4+ Views, zero behavioural change.
3. **H2.19 + H2.20** Test-Helpers + AgentChatsTests-Split → ermöglicht alle weiteren Phasen.
4. **H2.21** Minimal CI → safety net.
5. **H1.3** Non-optional fields → silent-data-loss-Bug.
6. **H1.2** AgentSessionStore Concurrency-Lock → eliminates Lost-Update-Race.
7. **H1.1 step 2-5** Extract ProjectChatGroup / DetailView / Inspector / GitProjectStatus.
8. **H2.5** Combine instead of string Notification.
9. **H2.7 + H2.8** Headless CLI mit Timeout + DRY.
10. **H1.5** RecordingCoordinator Split — größtes Refactor, braucht alle vorigen.

Vollständige Roadmap mit Phasen-Reihenfolge: siehe `refactoring-plan.md`.
