# Refactoring-Plan — WhisperM8

Priorisierte Roadmap. Jede Phase ist als **eigenständiger PR/Commit** durchführbar und schließt mit grünem Test-Lauf. Findings-IDs (`H1.x`/`H2.x`/`H3.x`) referenzieren `findings.md`. Reihenfolge respektiert Abhängigkeiten — frühere Phasen ermöglichen spätere.

**Gesamt-Prinzipien**:
- Keine Breaking Changes für End-User (Workspace-JSON, AppPreferences, Hotkey-Bindings, TCC-Permissions bleiben unangetastet).
- Jede Phase einzeln revertierbar.
- Vor jeder mittel-/hoch-Risiko-Phase: Tests, die das Soll-Verhalten festnageln.

> **`[v2]`-Marker**: Alle Punkte mit `[v2]` wurden nach der Gegenprüfung gegen den parallelen Refactoring-Plan unter `/Users/giulianocosta/repos/whisperm8/analysis-refactoring/` ergänzt oder geschärft. Cross-Check-Zusammenfassung am Ende dieses Dokuments.

---

## Phase 0 · Test-Fundament & CI (1–2 Tage, niedrig-Risiko)

**Ziel**: Sicherheitsnetz, das alle weiteren Phasen ermöglicht. Keine Verhaltensänderungen.

### Schritte
1. `Tests/WhisperM8Tests/Helpers/` anlegen mit:
   - `TempFiles.swift` (`tempStoreURL()`, `tempProjectDirectory()`).
   - `PreferenceIsolation.swift` (`withIsolatedPreferences { … }` generic).
   - `MockPostProcessor.swift` (aktuell inline in OutputDashboardTests).
2. **AgentChatsTests-Split** (H2.20): die 13 `MARK:`-Sektionen in 12 separate Files trennen:
   - `AgentCommandBuilderTests.swift`, `AgentSessionIndexerTests.swift`, `AgentSessionStoreTests.swift`, `AgentResourceMonitorTests.swift`, `AgentSessionAutoNamerTests.swift`, `AgentSessionSummarizerTests.swift`, `AgentTranscriptTests.swift`, `TerminalShortcutTests.swift`, `LoginShellEnvironmentTests.swift`, `TranscriptContextBundleTests.swift`, `AgentProjectIconResolverTests.swift`, `ThemeManagerTests.swift`.
   - Mechanisches Cut-and-Paste, keine Logik-Änderung.
3. **Minimaler CI-Workflow** (H2.21): `.github/workflows/test.yml`:
   ```yaml
   name: test
   on: [push, pull_request]
   jobs:
     test:
       runs-on: macos-14
       steps:
         - uses: actions/checkout@v4
         - uses: maxim-lobanov/setup-xcode@v1
           with: { xcode-version: latest-stable }
         - run: swift build
         - run: swift test --parallel
   ```
4. **`make test`** und **`make ci`** Targets im Makefile.
5. **Brittle Tests fixen** (H3.7, H3.8):
   - `OutputDashboardTests.testTemplateRenderingReplacesPlaceholders` TZ-explizit.
   - `WindowAndOverlayTests` mit `setUp/tearDown` für `WindowRequestCenter.shared`.
6. **`[v2]` Test: UTI-Strings-Konsistenz** (Cross-Check L1 verifiziert):
   - `AgentDragDropTypes.swift:37-39` definiert `"com.whisperm8.app.agent-chat-session"` / `…agent-project`.
   - `WhisperM8/Info.plist:34-60` deklariert dieselben Strings nochmal als `UTExportedTypeDeclarations`.
   - Test parst Info.plist und vergleicht gegen die Swift-Konstanten → fängt jedes Drift sofort ab.
7. **`[v2]` Test: DnD Self-Drop No-op** (Cross-Check M1 verifiziert):
   - Drop einer Session auf sich selbst muss eine No-op sein (heute überschreibt sie wahrscheinlich die Reihenfolge — `AgentChatsView.swift:963-1011` filtert das nicht raus).
   - Test gegen `dropSession`-Coordinator (nach Extraktion in Phase 6).
8. **`[v2]` Test: DnD stale-IDs und unvollständige `orderedIDs`**:
   - `reorderSessions` mit IDs, die nicht (mehr) im Projekt sind → silent skip.
   - `reorderProjects` mit nur-partieller-Liste während archived Projekte existieren.

### Tests nötig
Vorher: keine. Diese Phase IST der Test.
Nachher: alle 148 bestehenden Tests grün, neue Helpers funktional.

### Risiko
**niedrig**. Pure Test-/CI-Arbeit, kein App-Code.

### Abhängigkeiten
keine.

### Erfolgskriterien
- `swift test --parallel` läuft grün.
- GitHub-Actions-Workflow durchläuft auf einem Test-PR.
- AgentChatsTests-Datei < 250 LOC.

---

## Phase 1 · Korrektheits-Bugs (1 Tag, niedrig-Risiko)

**Ziel**: isolierte Bug-Fixes, die User-sichtbar sind oder Silent-Data-Loss verhindern.

### Schritte
1. **H1.6** `<0.3 s isProcessing` Leak fixen (RecordingCoordinator.swift:151-154).
   - Einzeiler: `isProcessing = false` vor jedem Return-Pfad.
2. **H1.3** Non-optional Fields auf Optional umstellen.
   - `AgentChatSession.imagePaths: [String]?` mit Default `[]` im `init`.
   - `hasLaunchedInitialPrompt: Bool?` mit Default `false`.
   - Custom `init(from:)` falls Default-Injection auf Decode-Seite gewünscht.
   - **Backup-Recovery in `AgentSessionStore.loadWorkspace`** bei Decode-Fail: alte Datei nach `AgentSessions.json.bak` rotieren, **dann** `.empty` zurückgeben + Log + (optional) `appState.lastError` setzen.
3. **H2.10** User-Cancel-Differentiation in `PostProcessingService`:
   - Neuer Error-Case `.userCancelled`.
   - `cancelPostProcessing` setzt `Flag` der vom Awaiter geprüft wird; Coordinator behandelt `.userCancelled` nicht als Fehler.
4. **H2.16** `make install` ruft `lsregister -f` (Makefile shared recipe).
5. **H3.1** Dead-Code löschen nach Verify:
   - `BranchTag` (wenn ProjectDetailPanel nicht mehr nutzt).
   - `HeaderIconButton`.
   - `overlayPositionX/Y` Keys.
   - `Defaults` SPM-dep raus, falls grep nichts findet.
   - CLAUDE.md `ISSoundAdditions`-Eintrag.
   - **`[v2]` `Transcribing` protocol + `TranscriptionRequest` struct entfernen** (Cross-Check L2 verifiziert). `TranscriptionService.swift:9-13` definiert beide, **kein einziger Use-Site außer der Definition selbst** (grep verifiziert).
6. **`[v2]` `PostProcessingService.didTimeout` thread-safe machen** (Cross-Check L3 verifiziert): `PostProcessingService.swift:198, 207, 231` — lokales Bool wird vom Watchdog-Task gesetzt und vom Main-Task gelesen ohne Lock. Race-Window ist real. Fix: NSLock oder DispatchQueue.sync um beide Zugriffe. Trivialer 5-Zeilen-Fix.
7. **`[v2]` Force-Cast in SelectedContextService.swift:61 entfernen** (Cross-Check L5 verifiziert): `focusedElement as! AXUIElement` — Crash-Risiko bei unerwarteten AX-Werten. Auf `guard let … as? AXUIElement else { return nil }` ändern. Wahrscheinlich nie geknallt, aber free-lunch-fix.
8. **`[v2]` `AGENTS.md` syncen** (Cross-Check L7 verifiziert): existiert neben `CLAUDE.md` als Codex-Variante derselben Doku, beide listen weiterhin `ISSoundAdditions` u. ä. — beide updaten oder eine zur Quelle der Wahrheit erklären (Symlink).

### Tests nötig
- **Decode-Test** für v1-JSON ohne `imagePaths`/`hasLaunchedInitialPrompt` (H4.1).
- **Backup-Rotation-Test** bei corrupted JSON (H4.2).
- **`<0.3 s` early-return-Test** mit Mock-AudioRecorder (snapshot des AppState).
- **`cancelPostProcessing` Test**: `appState.lastError` muss nach Cancel `nil` bleiben.

### Risiko
**niedrig**. Bugs ohne API-Bruch; Tests pinning Verhalten.

### Abhängigkeiten
Phase 0 (für Test-Helpers).

### Erfolgskriterien
- Neue Tests grün, alle bisherigen grün.
- Manuell: Recording <0.3s → nächster Stop funktioniert.
- Manuell: Cancel-Codex → kein roter Error-Banner.

---

## Phase 2 · Theme + Color-Helpers nach Support/ (½ Tag, niedrig-Risiko)

**Ziel**: H1.8 — der höchste-ROI-Refactor. Identische Token-Werte, nur Verschiebung.

### Schritte
1. **Verschieben** (alles `internal`, kein `private`):
   - `Support/AgentTheme.swift` — 22 Tokens aus AgentChatsView.swift:3074-3176.
   - `Support/Color+Dynamic.swift` — `Color.dynamic(light:dark:)` + `NSAppearance.isDark` extension.
   - `Support/Color+Hex.swift` — `Color.init(hex:)`.
   - `Support/String+NilIfEmpty.swift`.
2. **`AgentChatsWindowAccessor`-Background** auf `AgentTheme.background.nsColor` umstellen (eliminiert duplicate RGB-Triple, H2.x).
3. **AgentTheme erweitern um**:
   - `accentBranch` (violet, von BranchTag).
   - `overlayGlass` (light/dark) — Vorbereitung für RecordingOverlayView-Migration in Phase 7.
   - `rowBackground(isSelected:isHovered:)` static helper (H2.3 — 7 Stellen).

### Tests nötig
- Snapshot-Test in beiden Themes (Phase 0-Helper).
- Sichtbar manuell: System/Hell/Dunkel-Toggle in Settings.

### Risiko
**niedrig**. Compiler sichert Visibility-Wechsel ab; Tokens unverändert.

### Abhängigkeiten
Phase 0.

### Erfolgskriterien
- Build clean, Tests grün.
- AgentChatsView.swift verkleinert um ~150 LOC.
- Sichtbar: keine Farb-Drift.

---

## Phase 3 · AgentChatsView-Extraktionen (2–3 Tage, niedrig-mittel-Risiko)

**Ziel**: mechanische Extraktion der 17 inline-structs. Schrittweise, jedes Stück eigener Commit.

### Schritte (jeder = ein PR)

3.1 **`ProjectChatGroup` → `Views/AgentChats/Sidebar/ProjectChatGroup.swift`** (1705-1959, 255 LOC).
3.2 **`SessionListButton` → `Views/AgentChats/Sidebar/SessionListButton.swift`** (1961-2102).
3.3 **`AgentSessionDetailView` + `ClosedSessionSummaryView` → `Views/AgentChats/Workspace/`** (2701-3017).
3.4 **`ProjectDetailPanel` + atoms → `Views/AgentChats/Inspector/`** (2510-2699).
3.5 **`GitProjectStatus` → `Services/GitProjectStatus.swift`** (3019-3067) — Service-Layer, async API. H2.15.
3.6 **Tab-Strip-Components → `Views/AgentChats/TabStrip/`**: `ChatTabButton`, `ProviderTab`, `TitlebarIconButton`.
3.7 **Shared atoms → `Views/AgentChats/Components/`**: `ProviderIcon`, `ProjectAvatar`, `SidebarCommandRow`, `SidebarRowButtonStyle`, `colorSwatchImage`.
3.8 **`AgentResourceSummaryButton` + `AgentResourcePopover` + `AgentResourceFormat`** → `Views/AgentChats/Resources/`.
3.9 **`SessionMenuItems` + `TabColorMenu` Builder** (H2.1) — kollabiert 3 duplizierte Menüs.
3.10 **`AgentLayout` Konstanten-Enum** (H3.2) — 30 magic numbers in benannte Tokens.
3.11 **`AgentChatsView.editorAppPath`-Pref** (H3.3) — Hardcoded PHPStorm-Pfad in `AppPreferences`.

3.12 **`[v2]` `OutputDashboardView.swift` Split** (Cross-Check verifiziert: 1332 LOC mit 6 Sub-Views in einer Datei). Der fremde Plan listet das als M5; ich hatte es zu schwach gewürdigt. Konkrete Sub-Views laut `OutputDashboardView.swift`:
  - `TranscriptReportsView` (`:138`)
  - `TaskReportsView` (`:254`)
  - `OutputModesView` (`:558`)
  - `OutputTemplatesView` (`:876`)
  - `CodexSettingsView` (`:1112`)
  - `OutputTestLabView` (`:1232`)

Extraktion in `Views/OutputDashboard/`. Plus: `OutputModesView`-Initialisierung über `reload()` vereinheitlichen (laut Cross-Check inkonsistent).

Risiko: niedrig (mechanisch). Aufwand: ½ Tag.

### Tests nötig
- **Snapshot-Tests** für jede extrahierte View einzeln (jeweils zwei Themes).
- Bestehende Tests müssen grün bleiben.

### Risiko
**niedrig pro Schritt**, akkumuliert mittel. Jeder Schritt ist mechanisch + isoliert.

### Abhängigkeiten
- Phase 0 (Snapshot-Test-Setup).
- Phase 2 (AgentTheme public, sonst Compile-Fehler).

### Erfolgskriterien
- AgentChatsView.swift: 3208 → ~2 200 LOC nach 3.1-3.4, dann ~1 500 LOC nach 3.5-3.10.
- Build clean, alle Tests grün, alle Snapshots stabil.

---

## Phase 4 · Concurrency-Hardening AgentSessionStore (1 Tag, mittel-Risiko)

**Ziel**: H1.2 + H1.9 + H2.9. Eliminiert Lost-Update-Race und konsolidiert auf eine Store-Instanz.

### Schritte
1. **NSLock im Store** als minimal-invasiver Lock:
   - private `NSLock` als Property.
   - jeder Mutator wraps `lock.lock() / defer lock.unlock()`.
   - Tests verifizieren: zwei parallele `updateSession(idA)` + `updateSession(idB)` → beide Updates überleben.
2. **`AgentSessionStore` als `@MainActor ObservableObject`** + `@Published var workspace`.
   - environment-Object in `WhisperM8App`.
   - alle 5 Instanzen-Sites refactoren auf injected store.
3. **`schemaVersion: Int = 1` Field** auf `AgentWorkspace` (H2.9).
   - bei Decode prüfen; bei höher als bekannt → `.bak`-Rotation + Default.
4. **Migrations-Manifest dokumentieren** in `Support/SchemaMigrations.md`.

### Tests nötig (H4.1, H4.3, H4.5):
- Parallel-write race (zwei Tasks).
- Reader während Writer (atomic-Test).
- Decode mit schemaVersion=2 → `.bak` + Default.
- `bindLatestIndexedSession` 5s-Window pinning (H3.13).

### Risiko
**mittel**. Viele Aufrufer; aber Tests pinning Verhalten.

### Abhängigkeiten
Phase 0 (Tests), Phase 1 (Decoder-Safety).

### Erfolgskriterien
- Race-Tests grün.
- Single store instance in der App (grep Bestätigung).
- Workspace-File hat `schemaVersion`-Feld; alte JSONs migrieren.

---

## Phase 5 · Theme + Notification → Combine (½ Tag, niedrig-Risiko)

**Ziel**: H2.5. Type-safety Theme-Bridge.

### Schritte
1. **`AgentTerminalController` subscribet via Combine** auf `ThemeManager.shared.$resolvedColorScheme`.
   - `AnyCancellable` in `init`, auto-cancel on `deinit`.
2. **Notification-Posting in `ThemeManager`** entfernen (jetzt redundant).
3. **`ClaudeThemeWriter` retry-on-parse-fail** (H2.18): bei `parse_failed` einen einmaligen Retry nach 1s scheduln.

### Tests nötig
- Theme-Switch propagiert zum Terminal: integration test mit Mock-Terminal.

### Risiko
**niedrig**. Notification → Combine ist semantisch äquivalent.

### Abhängigkeiten
Phase 0.

### Erfolgskriterien
- Theme-Wechsel im laufenden Terminal funktioniert.
- Notification-name-String existiert nicht mehr im Code (grep).

---

## Phase 6 · Drag-Drop UX + Coordinator (1 Tag, niedrig-Risiko)

**Ziel**: H2.4 + H2.12 + H2.17.

### Schritte
1. **`isTargeted:` Closures** an alle Drop-Targets:
   - `sessionRow`, `ChatTabButton`, Trailing-Spacer.
   - State: `@State var dropTargetID: UUID?`.
   - Visual: subtle background tint via `AgentTheme.selection.opacity(0.4)`.
2. **`DragDropCoordinator`-Struct** (Pure-Value-Type):
   - Methoden: `resolveDrop(droppedSession:in:beforeSessionID:current:) -> DropAction`.
   - View ruft Coordinator, `DropAction` triggert Store-Mutator.
3. **Cross-Project-Visual-Cue**: wenn `dropped.sourceProjectID != target.projectID`, kleine Arrow-Icon auf Header-Overlay.
4. **Tests** für branch-decision (H4.4): same-project, cross-project, stale-IDs, out-of-bounds-index.

### Tests nötig
- Drop-coordinator unit tests.
- Snapshot-Test: targeted-row mit isTargeted-overlay.

### Risiko
**niedrig**. View-only-Änderungen + neue Testbarkeit.

### Abhängigkeiten
Phase 0, Phase 3 (ProjectChatGroup extrahiert).

### Erfolgskriterien
- Sichtbares Hover-Highlight pro Row.
- Cross-Project-Move zeigt sichtbaren Cue.
- Drop-Coordinator-Tests grün.

---

## Phase 7 · Session-Services Cleanup (1–2 Tage, niedrig-mittel-Risiko)

**Ziel**: H2.7 + H2.8 + H2.22 + Indexer-Cache-Eviction (H3.4).

### Schritte
1. **`AgentHeadlessCLI` extrahieren** (single Process-Runner mit Timeout).
   - argv-Builder zentralisieren.
   - `withTimeout(_:)` async helper.
   - default 30s, configurable via param.
2. **`ThrottledOnceTask<Key: Hashable>` helper** für in-flight tracking (AutoNamer + Summarizer).
3. **Unified `JSONLReader`** namespace mit `firstLine`, `firstNLines`, `tail(bytes:)`. Indexer's `BoundedJSONLReader` und Watcher's `readTail` ersetzen.
4. **`StatusDeciderConfig`** als injectable struct (H2.22).
5. **`AgentSessionIndexer`**: in `save` Sweep-Step für nicht-mehr-existente Pfade (H3.4).
6. **Rename `AgentTitleGenerator` → `AgentHeadlessCLI`** (cosmetic, after #1).
7. **`[v2]` `bindExternalSessionIDWhenAvailable` Retry statt fixer 1.5s-Sleep** (Cross-Check H4 verifiziert: `AgentChatsView.swift:2841` hat `Task.sleep(nanoseconds: 1_500_000_000)` als hartkodiertes Einmal-Polling).
   - Risiko: bei parallelen Session-Starts oder langsamen Provider-Writes kann die Single-Shot-Probe die externalSessionID nicht treffen → Session bleibt ohne Binding, Auto-Naming/Summary/Watcher hängen am Anfang.
   - Fix: exponential backoff (z.B. 300ms / 800ms / 1.8s / 3.5s, max 4 Versuche). Bei jedem Versuch `CodexSessionIndexer + ClaudeSessionIndexer` lookup; bei Treffer → bind; bei Final-Fail → soft-log, Session läuft trotzdem.
   - Wandert in den `AgentSessionLifecycleCoordinator` aus Phase 8.
   - Tests: parallele `prepareCommand`-Calls auf zwei Sessions; jeweils muss eine valide externalSessionID gefunden werden.

### Tests nötig
- Timeout-Test mit Mock-Runner.
- ThrottledOnceTask unit tests (re-entrant call, concurrent calls).
- Indexer eviction nach file-delete (H4.7).

### Risiko
**niedrig-mittel**. Service-Layer-Refactor; UI nicht betroffen.

### Abhängigkeiten
Phase 0.

### Erfolgskriterien
- `AgentHeadlessCLI` hat einen Use-Site pro CLI-Aufruf.
- Hängender Process → `inFlight` cleared nach timeout.
- Cache shrinks nach File-Delete.

---

## Phase 8 · AppState-Split & Runtime-Services-Coordinator (2 Tage, mittel-Risiko)

**Ziel**: H1.4 + Coordinator-Extraktion (A2 §"State variable groupings").

### Schritte
1. **`RecordingState`** struct (isRecording, isTranscribing, isPostProcessing, audioLevel, recordingDuration, lastError, isScreenClipRecording, postProcessingStatusText).
2. **`ContextState`** struct (selectedContext, contextBundle, activeAgentChat, lastContextBundle, lastSelectedContext).
3. **`PostProcessingState`** struct (lastTranscription, lastRawTranscription, lastFinalTranscription, lastOutputMode, lastTranscriptRunReport).
4. **AppState bleibt als Façade** mit deprecated re-exports während Migration; Views migrieren schrittweise auf die Sub-States als Environment-Objects.
5. **`AgentRuntimeServices`** Coordinator (bundle terminalRegistry + runtimeStatusStore + runtimeWatcher + autoNamer + summarizer; eliminiert `setupRuntimeServicesIfNeeded` workaround).
6. **`AgentWorkspaceCoordinator`** mit single Store-Reference (kombiniert mit Phase 4).
7. **`AgentSelectionModel`** (selectedProjectID, selectedSessionID, expandedProjectIDs, openTabIDs).
8. **`RenameSheetModel`** (renameTargetID, renameDraft, renameProjectTargetID, renameProjectDraft).

### Tests nötig
- Snapshot-Tests für AgentChatsView in 4 Right-Pane-States (no-selection, active-terminal, summary-of-closed, summary-loading).
- Recording-State-Mirror-Test: AppState.isRecording reflektiert RecordingState korrekt.

### Risiko
**mittel-hoch**. Viele Call-Sites, aber mit Phase 0-Tests + Snapshot-Coverage gut abgesichert.

### Abhängigkeiten
Phase 0, Phase 3, Phase 4.

### Erfolgskriterien
- AppState hat ≤ 5 Properties (rein Façade).
- AgentChatsView top-level State hat ≤ 6 `@State`/`@StateObject` (von 24).
- Tests grün.

---

## Phase 9 · RecordingCoordinator-Split (3 Tage, hoch-Risiko)

**Ziel**: H1.5 + H1.7. Service-Layer-AppKit-Coupling eliminieren.

### Vorab: braucht Tests aus Phase 0 + Snapshot-Coverage.

### Schritte
1. **`RecordingLifecycleController`** — owned AudioRecorder, RecordingTimer, ESC monitor, Ducking, OverlayController-Trigger. Exposes `start()/stop()/cancel()`.
2. **`ContextBundleEditor`** — alle `clearContextBundle`/`removeAgentChatFromContext`/`removeSelectedTextFromContext`/`removeAttachmentFromContext`/`addContextScreenshot`/`toggleScreenClip`-Methoden. Bindet `contextBundle` als Binding.
3. **`TranscriptionPipeline`** — nimmt URL, returnt `TranscriptResult { rawText, finalText, intent, prompt }`. Kein AppState-Wissen.
4. **`TranscriptRunReportBuilder`** als free function auf `TranscriptRunReportDraft.init(from:)`.
5. **`RecordingPhase` enum** (H2.14): `.idle / .recording / .transcribing / .postProcessing(intent) / .cancelling` als single source of truth.
6. **`OverlayController` → Presentation-Layer** (H1.7): aus `Services/` raus.
7. **Mode-Strategy-Protocol** (A7 §"Output modes"): `ModeRunner` mit `execute(rawText:bundle:) -> ModeResult` — zentralisiert `chatID`/`taskID`-Special-Cases.
8. **`cautiousFallbackText` → `OutputMode`-Property** (lokalisierbar).

### Tests nötig — **VOR Implementation**:
- Recording-Coordinator-Integration-Tests mit Mock-AudioRecorder, Mock-TranscriptionService, Mock-PostProcessingService.
- Bluetooth-config-change-fail-Pfad (H4.13).
- State-Machine-Übergänge (H2.14).

### Risiko
**hoch**. 884-LOC-Coordinator + 17 AppState-Mutations-Sites.

### Abhängigkeiten
Phase 0 dringend, Phase 1 (Bug-Fix), Phase 8 (RecordingState).

### Erfolgskriterien
- RecordingCoordinator < 200 LOC als Façade.
- `Services/` importiert kein AppKit mehr (grep).
- Integration-Tests grün.

---

## Phase 10 · RecordingOverlayView-Extraktionen (½ Tag, niedrig-Risiko)

**Ziel**: H2.11.

### Schritte
1. **`Views/Overlay/ContextMenuContent.swift`** (170 LOC) — größter Single-File-Shrink.
2. **`Views/Overlay/AudioLevelBars.swift`** (full + mini).
3. **`Views/Overlay/VisualContextActionButtons.swift`**.
4. **`Views/Overlay/OutputModePicker.swift`** (OutputModeMenu + MiniOutputModeChip).
5. **`Views/Overlay/RecordingStatusIndicator.swift`**.
6. **Thumbnail-Cache** in `ContextAttachment` (H2.11 ContextMenuContent.thumbnailImage(for:)).

### Tests nötig
- Snapshot-Tests für jedes der 3 Recording-Overlay-States.

### Risiko
**niedrig**. Pure View-Split.

### Abhängigkeiten
Phase 0.

### Erfolgskriterien
- RecordingOverlayView.swift < 200 LOC.

---

## Phase 11 · AppPreferences → Defaults (1 Tag, niedrig-mittel-Risiko)

**Ziel**: H2.13.

### Schritte
1. **`Defaults`-Library** real einbinden (war vorher dead dep).
2. **`Defaults.Keys`-Extension** mit allen 30 keys, RawRepresentable-Support für Enums.
3. **`AppPreferences`-Façade bleibt** für Migrationszeit; intern delegiert sie an Defaults.
4. **Migration-Step**: einmaliger Bulk-Read der alten UserDefaults-Keys + Schreibe auf neuen Defaults-Keys + Set `AppPreferences.didMigrateToDefaults = true`.

### Tests nötig
- Migrations-Test mit fake-UserDefaults: alte Keys vorhanden → neue Defaults korrekt befüllt.

### Risiko
**niedrig-mittel**. User-Preferences-Migration ist sensitive; aber mit Test gut absicherbar.

### Abhängigkeiten
Phase 0.

### Erfolgskriterien
- ~150 LOC Boilerplate raus aus AppPreferences.
- Compile + Tests + manueller Smoke-Test: User-Pref-Werte bleiben nach App-Restart erhalten.

---

## Phase 12 · TranscriptRunReportStore Retention (½ Tag, niedrig-Risiko)

**Ziel**: H2.6.

### Schritte
1. **`cleanup(maxAge:maxCount:maxBytes:)`-API**.
2. Aufruf in `save` nach jedem Write.
3. Default-Policy: 30 Tage, 200 Reports, 2 GB.
4. **AppPreferences-Keys** für die drei Limits.

### Tests nötig
- Save-21-Reports-mit-max-20 → ältester verschwindet.
- Save-mit-vanished-attachment (H4.6).

### Risiko
**niedrig**. Isolated Service.

### Abhängigkeiten
Phase 0.

### Erfolgskriterien
- Reports/-Ordner respektiert Caps.
- Tests grün.

---

## Phase 13a · `[v2]` Window-Routing + AppCommand-Konsolidierung (1 Tag, mittel-Risiko)

**Cross-Check-Quelle**: M2 + M3 im Fremd-Plan. Verifiziert:
- `WindowRequestHandler` lebt am `MenuBarIcon`-Background (`WhisperM8App.swift:45`) — wenn MenuBarExtra inaktiv ist, kann Routing-Handler nicht reagieren.
- `WindowRequest.outputDashboard` mappt auf **denselben `windowID = "settings"`** wie `WindowRequest.settings` (`WindowRequestCenter.swift:7-19`). Latenter Bug: `request(.outputDashboard)` öffnet das Settings-Window, nicht ein separates Output-Dashboard.
- Menüs sind 4× dupliziert (siehe H2.1) und kein zentraler `.commands { }` Block.

### Schritte
1. **`AppRoute` / `AppCommand`** als zentrale Enums in `WhisperM8App.swift`.
2. **`.commands { }` Block** in der App-Scene mit:
   - File → Neuer Chat (Cmd+N)
   - File → Sessions scannen
   - View → Sidebar toggle, Inspector toggle
   - Edit → Umbenennen
   - Window → Agent Chats, Output Dashboard, Settings
3. **`outputDashboard`-Route fixen** — eigenes Window oder explizit zur Settings-Tab routen.
4. **`WindowRequestHandler` aus dem MenuBarIcon-Background herausziehen** — explizit auf App-Shell-Ebene (z. B. via `.onReceive(...)` auf einer leeren Scene-Companion-View).
5. **Session-/Project-Context-Menus** als shared Builder (siehe Phase 3.9; hier nur verlinkt).

### Tests nötig
- `WindowRequestCenter` Reset/Isolation in Tests.
- `AppRoute`-Tests (welche Route öffnet welches Window).

### Risiko
**mittel**. Touch auf MenuBarExtra-Lifecycle-Verhalten.

### Abhängigkeiten
Phase 0, Phase 3 (Menu-Builder extrahiert).

### Erfolgskriterien
- `request(.outputDashboard)` öffnet tatsächlich ein Output-Dashboard, nicht Settings.
- Cmd+N etc. funktionieren in Menüleiste.

---

## Phase 13b · `[v2]` Build-Setup-Drift bereinigen (½ Tag, niedrig-mittel-Risiko)

**Cross-Check-Quelle**: H5 im Fremd-Plan. Verifiziert:
- `WhisperM8.xcodeproj/project.pbxproj` existiert (20 895 bytes, Stand Feb 8).
- `scripts/build.sh` + `scripts/run.sh` nutzen **`xcodebuild`** gegen das stale Projekt, **NICHT** SwiftPM/Makefile (der dokumentierte und tatsächliche Build-Pfad).
- Ergebnis: zwei divergierende Build-Quellen mit unklaren Bundle-ID-/Signing-/Dependency-Folgen.

### Schritte
1. **Entscheiden** (Stakeholder-Frage, dokumentieren):
   - Option A: `WhisperM8.xcodeproj` löschen oder `.gitignore`. `scripts/build.sh` + `scripts/run.sh` löschen oder auf `make build` / `make dev` umleiten.
   - Option B: Xcode-Projekt mit `Package.swift` synchron halten (z. B. via `xcodegen`).
2. **README + AGENTS.md + CLAUDE.md + docs/ARCHITECTURE.md** updaten, dass `make dev` kanonisch ist (CLAUDE.md sagt das bereits, AGENTS.md und ARCHITECTURE.md nicht).
3. **`make install` `lsregister`-Step** ergänzen (bereits in Phase 1.4 erledigt) — hier nur Dokumentations-Verweis.
4. **`make dmg` Pre-Step `kill`** ergänzen (laut A8 fehlt der heute).

### Tests nötig
- Manueller Smoke: `make build`, `make dev`, `make install`, `make dmg` durchlaufen ohne Fehler nach Cleanup.

### Risiko
**niedrig-mittel**. Wenn jemand sich auf `xcodebuild`-Scripts verlässt, brechen die. Vorab kommunizieren.

### Abhängigkeiten
keine direkte; jederzeit machbar.

### Erfolgskriterien
- Genau **eine** kanonische Build-Quelle.
- `scripts/`-Verzeichnis enthält keine xcodebuild-Aufrufe mehr.

---

## Phase 13 · Polish & Niedrig-Severity (1 Tag, niedrig-Risiko)

**Sammelschritt**: H3.1-H3.15.

### Schritte
1. **Info.plist Polish-Keys** (H3.11).
2. **Drag-Drop Auto-Scroll + Hover-Expand** (H3.14).
3. **RecordingPanel `windowDidMove` Debounce** (H3.15).
4. **AgentChatsWindowAccessor** Optimierung (H3.12).
5. **`AppPreferences.shared` → `static let`** (H3.10).
6. **AgentTerminalPalette Contrast-Test** (H3.6).
7. **Makefile `_bundle` für-Loop** (H3.9).
8. **Magic Numbers → AgentLayout** (H3.2 fertigstellen falls aus Phase 3 nicht komplett).
9. **`[v2]` Version aus `Bundle.main` lesen statt hardcoded in `SettingsView.swift:748`** (Cross-Check L6).
10. **`[v2]` Audio-Tap-Code dedup** (Cross-Check L4): `AudioRecorder.swift:141` und `:334` haben byte-identische `installTap(...)`-Aufrufe. Extrahiere `installRecordingTap(on:format:)`-Helper.

### Tests nötig
- bestehende Snapshots dürfen nicht regressieren.

### Risiko
**niedrig**. Polish.

### Abhängigkeiten
Phase 0.

---

## Phasen-Abhängigkeiten-Graph

```
Phase 0 (Test-Foundation)
  ├─► Phase 1 (Bug-Fixes)
  ├─► Phase 2 (Theme nach Support/)
  │     │
  │     └─► Phase 3 (View-Extraktionen, incl. [v2] 3.12 OutputDashboardView-Split)
  │           │
  │           ├─► Phase 6 (Drag-Drop UX)
  │           ├─► Phase 8 (Coordinator)
  │           ├─► Phase 10 (Overlay-Extraktionen)
  │           └─► [v2] Phase 13a (Window-Routing + Commands)
  │
  ├─► Phase 4 (Store-Concurrency)
  │     └─► Phase 8 (Coordinator)
  │
  ├─► Phase 5 (Theme-Combine)
  ├─► Phase 7 (Session-Services Cleanup, incl. [v2] Bind-Retry)
  ├─► Phase 11 (Defaults Migration)
  ├─► Phase 12 (Retention)
  ├─► [v2] Phase 13b (Build-Setup-Drift)
  └─► Phase 13 (Polish)

Phase 8 (Coordinator) ─► Phase 9 (RecordingCoordinator Split — hoch-Risiko)
```

---

## Aufwands-Schätzung gesamt

| Phase | Risiko | Aufwand |
|---|---|---|
| 0 — Test-Foundation & CI | niedrig | 1-2 Tage |
| 1 — Bug-Fixes | niedrig | 1 Tag |
| 2 — Theme nach Support/ | niedrig | ½ Tag |
| 3 — View-Extraktionen (11 Sub-Schritte) | niedrig-mittel | 2-3 Tage |
| 4 — Store-Concurrency + Single-Instance | mittel | 1 Tag |
| 5 — Theme-Combine | niedrig | ½ Tag |
| 6 — Drag-Drop UX | niedrig | 1 Tag |
| 7 — Session-Services Cleanup | niedrig-mittel | 1-2 Tage |
| 8 — AppState Split + Coordinator | mittel-hoch | 2 Tage |
| 9 — RecordingCoordinator Split | **hoch** | 3 Tage |
| 10 — Overlay-Extraktionen | niedrig | ½ Tag |
| 11 — AppPreferences → Defaults | niedrig-mittel | 1 Tag |
| 12 — Retention Policy | niedrig | ½ Tag |
| 13 — Polish | niedrig | 1 Tag |
| **`[v2]` 13a — Window-Routing + AppCommand** | mittel | 1 Tag |
| **`[v2]` 13b — Build-Drift-Cleanup** | niedrig-mittel | ½ Tag |
| **Σ** | | **17-21 Tage** |

**Empfohlene Sprint-Gruppierung**:
- **Sprint A** (1 Woche): Phase 0, 1, 2 — Foundation + Bug-Fixes + Theme-Win.
- **Sprint B** (1 Woche): Phase 3, 4, 5 — View-Extraktionen + Store-Hardening.
- **Sprint C** (1 Woche): Phase 6, 7, 8 — UX-Polish + Service-Cleanup + State-Split.
- **Sprint D** (1 Woche): Phase 9, 10, 11, 12, 13 — Risk-Last-Phase + Cleanup.

---

## Was wir explizit NICHT machen

(siehe `overview.md` §7)

- `ClaudeThemeWriter` — bereits clean.
- `AgentTranscriptParser` / `StatusDecider` — pure + getestet.
- `AgentCommandBuilder` — getestet.
- `LoginShellEnvironment` — getestet.
- `AgentTerminalPalette` — kalibriert, nur kleines Contrast-Tuning in Phase 13.
- `AppearanceOverride` + `ThemeManager` — sauber.
- Drag-Drop UTI-Registrierung — funktioniert.
- Makefile-rsync-Strategie — funktioniert (außer fehlendem lsregister in install).

---

## Verifikations-Strategie pro Phase

1. **Build**: `swift build` clean.
2. **Tests**: `swift test --parallel` grün (148 → wächst).
3. **Snapshot-Tests**: keine Visual-Regression.
4. **Smoke-Test**: `make dev` startet App ohne Crash, alle Tabs öffnen, Recording funktioniert.
5. **Git-Tag pro Phase**: `phase-N-complete` für leichte Reverts.

---

## Ausstiegskriterien

Eine Phase ist „done" wenn:
1. Tests grün
2. CI grün
3. Bewusster Manual-Smoke-Test
4. Commit + Push + Git-Tag

Wenn eine Phase mehr als +50% über Schätzung läuft → stop, Review, ggf. Phase splitten.

---

## `[v2]` Cross-Check gegen parallelen Plan

**Gegen-geprüft am 2026-05-11** gegen `/Users/giulianocosta/repos/whisperm8/analysis-refactoring/` (paralleler Plan von ChatGPT/Codex). Der fremde Plan wurde **nur gelesen, nicht verändert**.

### Was aus dem fremden Plan geprüft wurde

| Fremd-Finding | Code-Verify | Übernommen | Wohin |
|---|---|---|---|
| **H4** — `bindExternalSessionIDWhenAvailable` 1.5s-Race | ✅ `AgentChatsView.swift:2841` `nanoseconds: 1_500_000_000` bestätigt | ja | Phase 7 Schritt 7 (Bind-Retry mit backoff) |
| **H5** — Stale `WhisperM8.xcodeproj` + `scripts/build.sh/run.sh` mit `xcodebuild` | ✅ Dateien existieren, Scripts nutzen `xcodebuild` | ja | **Neue Phase 13b** (Build-Drift-Cleanup) |
| **M1** — DnD Self-Drop No-op fehlt | ✅ `dropSession` filtert das nicht | ja | Phase 0 Schritt 7 + Phase 6 (Coordinator) |
| **M2** — Menüs duplikate (4 Stellen), kein `.commands` | ✅ siehe H2.1 in `findings.md` | ja, plus AppCommand-Konsolidierung | Phase 3.9 + **neue Phase 13a** |
| **M3** — `WindowRequestHandler` am MenuBar-Icon | ✅ `WhisperM8App.swift:45 .background(WindowRequestHandler())` | ja | **Neue Phase 13a** |
| **M3-Bug** — `WindowRequest.outputDashboard` mappt auf `windowID = "settings"` | ✅ `WindowRequestCenter.swift:7-19` bestätigt | ja (echter Bug) | **Neue Phase 13a Schritt 3** |
| **M5** — `OutputDashboardView.swift` 1332 LOC, 6 Sub-Views | ✅ `wc -l` + grep bestätigt | ja | **Phase 3.12** neu |
| **M7** — Models lesen Preferences / liefern UI-Texte | ✅ `AgentChat.swift:18, 271, 319`, `TranscriptContextBundle.swift:1` importiert AppKit | teilweise; ich hatte AppKit-import schon in `overview.md` §"Cross-Layer Leaks" notiert, M7 ist eine Vertiefung | Phase 3 (Models bleiben rein, Presenter extrahieren) |
| **L1** — UTI-Strings doppelt gepflegt (Code + Info.plist) | ✅ `AgentDragDropTypes.swift:37-39` ≡ `Info.plist:34-60` | ja | Phase 0 Schritt 6 (Konsistenz-Test) |
| **L2** — `Transcribing` protocol + `TranscriptionRequest` struct ungenutzt | ✅ grep: nur die Definition selbst, kein anderer Use-Site | ja | Phase 1 Schritt 5 (Dead-Code-Liste) |
| **L3** — `PostProcessingService.didTimeout` thread-unsafe | ✅ `:198/207/231` ohne Lock | ja | Phase 1 Schritt 6 |
| **L4** — Audio-Tap-Code dupliziert | ✅ `AudioRecorder.swift:141` und `:334` byte-identisch | ja | Phase 13 Schritt 10 |
| **L5** — Force-Cast `as!` in `SelectedContextService.swift:61` | ✅ bestätigt | ja | Phase 1 Schritt 7 |
| **L6** — Version hardcoded in `SettingsView.swift:748` | ✅ bestätigt | ja | Phase 13 Schritt 9 |
| **L7** — Doku-Drift (AGENTS.md + ARCHITECTURE.md + CLAUDE.md) | ✅ AGENTS.md existiert als zweite Doku-Quelle | ja | Phase 1 Schritt 8 + Phase 13b Schritt 2 |

### Was bewusst NICHT übernommen wurde

| Fremd-Punkt | Warum nicht übernommen |
|---|---|
| **Fremd-Phasen 1 + 2 (mechanische Splits + Pure Helper) vor allem anderen** | Im Substanz **identisch** zu meinen Phasen 2 + 3, nur unter anderem Label gruppiert. Meine Reihenfolge (Test-Foundation → Bug-Fix → Theme → View-Splits) ist enger an Risiko-Vorbereitung gekoppelt. Strukturwechsel würde Lesbarkeit nicht erhöhen. |
| **Fremd-Phase 4 (RecordingCoordinator zerlegen) als vor-letzte Phase** | Ich plane das als Phase **9** mit voller Test-Coverage aus Phase 0 + Snapshot-Tests aus Phase 3 + State-Split aus Phase 8 als Voraussetzung. Der fremde Plan stellt es vor Phase 5/6/7 — meiner Ansicht zu früh ohne den State-Coordinator aus Phase 8. **Begründung am Code**: 884 LOC + 17 AppState-Mutations-Sites + 5 Booleans State-Machine sind ohne State-Split unangenehm zu trennen. |
| **Fremd-Plan-Aufwand: nicht explizit pro Phase ausgewiesen** | Mein Plan hat konkrete Tage-Schätzungen pro Phase + Sprint-Gruppierung. Beibehalten. |
| **Fremd-Phase 7 (kleine Hygiene-PRs als laufender Stream)** | Habe diese L-Findings in Phase 1 (sofortige Bug-Fixes mit User-Impact) und Phase 13 (Polish) verteilt, weil das pro Item klarere Risiko-Einordnung gibt. |
| **Fremd-Punkt: `M4 Theme/AppKit-Interop`** | Substanz schon in meinen Phasen 2 + 5 + 13.4 abgedeckt; ich habe konkretere File:Line-Referenzen. |

### Was MEIN Plan zusätzlich hat (Fremd-Plan fehlt das)

Diese Findings habe ich beibehalten, nicht im Fremd-Plan gefunden:

1. **`<0.3 s` `isProcessing` Leak-Bug** (H1.6) — konkreter user-sichtbarer Bug an `RecordingCoordinator.swift:151-154`.
2. **Non-optional Fields `imagePaths`/`hasLaunchedInitialPrompt` brechen Decode** (H1.3) — silent-data-loss-Bug, `AgentChat.swift:185-186` + `AgentSessionStore.swift:30-33`.
3. **5× `AgentSessionStore` instanziiert ohne shared in-memory state** (H1.9) — fremder Plan erwähnt Race, aber nicht das Multi-Instance-Problem.
4. **AgentTheme + Color.dynamic + Color(hex:) sind `private` im 3208-LOC-File** (H1.8) — höchster ROI, dringlichste Verschiebung.
5. **AgentHeadlessCLI-Duplikation zwischen AutoNamer + Summarizer** (H2.8) + Process-Timeout-Bug (H2.7).
6. **`AppState` god-object 18+ Properties** (H1.4) als explizites Refactor-Target.
7. **AppState/RecordingState/ContextState/PostProcessingState-Split-Plan** als konkrete Phase 8.
8. **Snapshot-Test-Strategie** (ViewInspector / swift-snapshot-testing) — Fremd-Plan sagt "UI-Tests sinnvoll" ohne Setup-Empfehlung.
9. **Schema-Version + `.bak`-Recovery** (H2.9) — Fremd-Plan hat Migration nicht so explizit.
10. **`TranscriptRunReportStore` ohne Retention/Rotation** (H2.6) — Fremd-Plan erwähnt das nicht.
11. **`User-Cancel = Error` Differentiation in PostProcessingService** (H2.10) — UX-Bug konkret.
12. **`ClaudeThemeWriter` als sauber gewürdigt** (overview.md §7) — Fremd-Plan sagt nichts über bereits-gute Files.

### Risiken/Phasen, die nach Cross-Check angepasst wurden

1. **Phase 0** erweitert um 3 Tests (UTI-Konsistenz, DnD Self-Drop, stale IDs).
2. **Phase 1** erweitert um 4 weitere Bug-Fixes (Transcribing-dead, didTimeout-Lock, Force-Cast, AGENTS.md-Sync).
3. **Phase 3** erweitert um Sub-Phase 3.12 (OutputDashboardView 6-Split).
4. **Phase 7** erweitert um Schritt 7 (Bind-Retry statt 1.5s-Sleep).
5. **Phase 13a** neu (Window-Routing + AppCommand) — adressiert `outputDashboard`-Route-Bug.
6. **Phase 13b** neu (Build-Drift-Cleanup) — Xcode-Projekt + scripts/.
7. **Phase 13** erweitert um Bundle-Version + Audio-Tap-Dedup.
8. **Gesamtaufwand**: 15-19 Tage → 17-21 Tage durch die zwei neuen Phasen.

### Offene Fragen für den finalen Plan

1. **Xcode-Projekt-Schicksal** (Phase 13b): löschen oder synchron halten? Stakeholder-Entscheidung; bis dahin Phase 13b nicht starten.
2. **`outputDashboard`-Route**: braucht es ein separates Window oder ist es immer Settings-Tab? UX-Frage.
3. **`AGENTS.md` vs `CLAUDE.md`**: Symlink auf eine Quelle oder beide separat pflegen? Konvention.
4. **Tab-Order vs Sidebar-Order**: aktuell ein gemeinsamer `sortIndex` (laut Drag-Drop-Analyse). Soll das so bleiben oder getrennt werden? UX-Frage.
5. **Defaults-Library**: tatsächlich entfernen (war dead) oder erst gemäß Phase 11 migrieren? Konsequenz: temporär bleibt Dead-Dep bestehen.
6. **Bind-Retry-Policy** (Phase 7 Schritt 7): exponential backoff vs. lineares Polling? Provider-spezifisch (Claude vs. Codex haben unterschiedliche Schreib-Latenzen) sinnvoll? Erst nach Tests entscheiden.
