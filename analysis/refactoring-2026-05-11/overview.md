# WhisperM8 — Architektur- und Refactoring-Überblick

**Stand**: 2026-05-11 · Branch `codex/agent-chats-session-hub` @ `eddb0c6`
**Codebase**: 58 App-Swift-Files (~18 000 LOC) + 6 Test-Files (~2 500 LOC)
**Plattform**: nativ macOS 14+ Swift 5.9 / SwiftUI + AppKit-Interop, SwiftTerm für eingebettete CLI-Subprocesses
**Ziel dieses Dokuments**: hochauflösender Architekturüberblick als Grundlage für `findings.md` und `refactoring-plan.md`. **Keine Implementierungs-Empfehlungen** hier — nur Karte.

---

## 1. Modul-Layout (Ist-Zustand)

```
WhisperM8/
├── WhisperM8App.swift            (Entry-Point, Scene-Defs, AppDelegate, Hotkey-Setup)
├── Models/                       (5 Files) — Datentypen, sollten plain Codable sein
│   ├── AgentChat.swift           (355 LOC — Project + Session + Workspace + Refs)
│   ├── AppState.swift            (Singleton @Observable, 18+ Properties — god-object)
│   ├── TranscriptContextBundle.swift (211 LOC — importiert AppKit ⚠)
│   ├── PostProcessingTemplate.swift (428 LOC — incl. Render-Logic)
│   └── OutputMode.swift          (kleine Enum-/Struct-Sammlung)
├── Services/                     (25 Files) — Business-Logic + Persistenz + Subprocesses
│   ├── AgentSessionStore.swift          (561 LOC — JSON-Store, 22 public methods)
│   ├── AgentSessionIndexer.swift        (474 LOC — JSONL-Scanner für Claude/Codex)
│   ├── AgentSessionAutoNamer.swift      (448 LOC — claude -p / codex exec → titles)
│   ├── AgentSessionSummarizer.swift     (~400 LOC — closed-session summaries)
│   ├── AgentSessionRuntimeWatcher.swift (235 LOC — JSONL-Tail-Polling für Status)
│   ├── AgentSessionTranscript.swift     (276 LOC — pure JSONL-Parser + Locator)
│   ├── RecordingCoordinator.swift       (884 LOC — Orchestrator, importiert AppKit ⚠)
│   ├── AudioRecorder.swift              (490 LOC — AVAudioEngine)
│   ├── TranscriptionService.swift       (309 LOC — OpenAI/Groq HTTP)
│   ├── PostProcessingService.swift      (539 LOC — Codex CLI + cancel registry)
│   ├── VisualContextCaptureService.swift (530 LOC — ScreenCaptureKit)
│   ├── TranscriptRunReportStore.swift   (263 LOC — Reports/, keine Retention ⚠)
│   ├── ClaudeThemeWriter.swift          (atomic write zu ~/.claude.json)
│   ├── PromptPackageBuilder.swift, AgentCommandBuilder.swift, LoginShellEnvironment.swift,
│   │   PasteService.swift, KeychainManager.swift, AudioDuckingManager.swift,
│   │   AudioDeviceManager.swift, SelectedContextService.swift, PermissionService.swift,
│   │   WindowRequestCenter.swift, AgentChatLaunchService.swift, Logger.swift, …
├── Support/                      (4 Files) — App-weite Utilities
│   ├── AppPreferences.swift     (255 LOC — UserDefaults, 30 keys, ad-hoc migration)
│   ├── ThemeManager.swift       (Singleton @ObservableObject, KVO auf NSApp)
│   ├── AppearanceOverride.swift (enum system/light/dark)
│   └── TextNormalizer.swift
├── Views/                        (~20 Files) — SwiftUI
│   ├── AgentChatsView.swift     (3208 LOC ⚠ — hostet 17 private structs)
│   ├── OutputDashboardView.swift (1332 LOC)
│   ├── SettingsView.swift       (765 LOC)
│   ├── RecordingOverlayView.swift (630 LOC — 11 structs in einem File)
│   ├── OnboardingView.swift     (615 LOC)
│   ├── AgentTerminalView.swift  (447 LOC — SwiftTerm-Wrapper, AgentTerminalController)
│   ├── AgentTerminalPalette.swift (Light/Dark ANSI-16-Paletten)
│   ├── AgentDragDropTypes.swift (Transferable + UTType-Defs)
│   └── …
└── Windows/
    └── RecordingPanel.swift     (357 LOC — non-activating NSPanel + OverlayController)

Tests/WhisperM8Tests/             (6 Files, 148 Tests)
├── AgentChatsTests.swift        (1750 LOC ⚠ — eine Klasse, 110 Tests)
├── OutputDashboardTests.swift   (509 LOC, 25 Tests)
├── PreferencesTests.swift, AudioDuckingManagerTests.swift,
│   TranscriptionUtilityTests.swift, WindowAndOverlayTests.swift
└── (keine Helpers/, keine UI-Tests)
```

---

## 2. Kritische Datenflüsse

### 2.1 Recording → Transcription → Output

```
Hotkey (KeyboardShortcuts) ──► AppState.shared.startRecording()
                                       │ delegates
                                       ▼
                          RecordingCoordinator ◄─ owns:
                            AudioRecorder, OverlayController (NSPanel ⚠ in Services!),
                            PasteService, RecordingTimer, PostProcessingService,
                            SelectedContextService, VisualContextCaptureService,
                            VisualAttachmentDeliveryBuilder, TranscriptRunReportStore
                                       │
                            ┌──────────┼──────────┐
                            ▼          ▼          ▼
                   AudioRecorder   ScreenCapture  SelectedContext
                   (AVAudio)        Kit            (NSPasteboard / accessibility)
                            │
                            ▼ (stop)
                   TranscriptionService ──► OpenAI/Groq HTTP
                            │
                            ▼ (raw text)
                   PostProcessingService ──► Codex CLI Process
                            │                  (with idle-timeout watchdog)
                            ▼
                   PasteService ──► Clipboard + CGEvent Cmd+V (auto-paste)
                            │
                            ▼
                   TranscriptRunReportStore (Reports/<UUID>/, kein TTL)
```

Schreibt in `AppState.shared` an **17 verschiedenen Slots**, `isRecording`/`isTranscribing`/`isPostProcessing`/`isScreenClipRecording`/`isProcessing` (3 davon auf AppState, 1 auf AudioRecorder, 1 lokal) bilden zusammen eine **implizite Audio-State-Machine** ohne single source of truth.

### 2.2 Agent-Chat

```
AgentChatsView (16 @State + 5 @StateObject)
   │
   ├── AgentSessionStore (struct, instantiiert 5× ⚠)
   │    └─► persistiert AgentSessions.json (atomic write, kein Lock)
   │
   ├── AgentTerminalRegistry → AgentTerminalController(s)
   │    └─► SwiftTerm.LocalProcessTerminalView ──► Claude/Codex CLI Subprocess
   │         ◄── string-keyed Notification "AgentTerminalController.themeDidChange"
   │
   ├── AgentSessionRuntimeStatusStore + AgentSessionRuntimeWatcher
   │    └─► polls ~/.claude/projects/...jsonl + ~/.codex/sessions/...jsonl @ 1.5s
   │
   ├── AgentSessionAutoNamer  ──► claude -p / codex exec  (kein Timeout ⚠)
   ├── AgentSessionSummarizer ──► claude -p / codex exec  (kein Timeout ⚠)
   └── AgentSessionIndexer    ──► CodexSessionIndexer + ClaudeSessionIndexer
```

**Konkurrierende Writer auf `AgentSessions.json`**: UI-Mutationen, AutoNamer-Background-Tasks, Summarizer-Background-Tasks, RuntimeWatcher (für `lastTurnAt`). Kein NSLock, kein actor — Lost-Update-Race möglich.

### 2.3 Theme

```
NSApp.effectiveAppearance ── KVO ──► ThemeManager.shared
                                       │ publishes
                                       ▼
                              @Published resolvedColorScheme
                                       │
                          ┌────────────┼────────────────┐
                          ▼            ▼                ▼
                AgentTheme           NSApp.appearance  ClaudeThemeWriter
                (private im         (set on override)  (atomic write zu
                AgentChatsView.swift ⚠)                ~/.claude.json,
                = 22 Color-Tokens                       debounced)
                          │
                          │ Color.dynamic(light:dark:) (private extension ⚠)
                          │
                          ▼
                Views (SwiftUI)
                          │
                          │ + string-keyed Notification.Name(
                          │     "AgentTerminalController.themeDidChange") ⚠
                          ▼
                AgentTerminalController.applyTheme(for:)
                  → SwiftTerm.installColors + nativeBackgroundColor
```

---

## 3. Singletons & Shared State (10 Stück)

| Singleton | Datei:Line | Typ | Risiko |
|---|---|---|---|
| `AppState.shared` | Models/AppState.swift:6 | `@MainActor @Observable` god-object, 18+ properties, gelesen von ~31 View-Sites | **hoch** |
| `AppPreferences.shared` | Support/AppPreferences.swift:4 | `static var` (mutable!) — Tests können es swappen, aber kein Compiler-Guard | mittel |
| `ThemeManager.shared` | Support/ThemeManager.swift:11 | `ObservableObject`, KVO + Combine | niedrig |
| `ClaudeThemeWriter.shared` | Services/ClaudeThemeWriter.swift:26 | Side-effect auf Disk aus Singleton | niedrig |
| `WindowRequestCenter.shared` | Services/WindowRequestCenter.swift:24 | DistributedNotificationCenter + @Published | mittel (parallel-test-hazard) |
| `LoginShellEnvironment.shared` | Services/LoginShellEnvironment.swift:23 | `@unchecked Sendable`, einmaliger Login-Shell-Aufruf | niedrig |
| `AudioDeviceManager.shared` | Services/AudioDeviceManager.swift:46 | CoreAudio C-Callback | niedrig |
| `AudioDuckingManager.shared` | Services/AudioDuckingManager.swift:125 | — | niedrig |
| `CodexProcessRegistry.shared` | Services/PostProcessingService.swift:7 | `weak var current: Process?`, terminate-race | mittel |
| `AgentCommandPathCache.shared` | Services/AgentCommandBuilder.swift:218 | — | niedrig |

---

## 4. Cross-Layer-Leaks (Architektur-Smells)

1. **Service-Layer importiert AppKit und besitzt UI**
   `RecordingCoordinator.swift:1` importiert AppKit. Owns `OverlayController` (`RecordingCoordinator.swift:19, 45`), das einen `NSPanel`/`NSHostingView` hält (`Windows/RecordingPanel.swift:195-197`). Services präsentieren effektiv Windows.

2. **Model importiert AppKit**
   `Models/TranscriptContextBundle.swift:1` und `Models/AppState.swift:1`. Models reichen in UI-Typen.

3. **Views instanziieren Services direkt — keine DI**
   `AgentChatsView` erstellt `AgentSessionStore()` 3× selbst (`AgentChatsView.swift:16, 928, 2722`), `AgentChatLaunchService.swift:11` und `RecordingCoordinator.swift:595` jeweils nochmal. **5 separate Instanzen ohne shared in-memory state**, alle synchronisieren nur über die JSON-Datei.

4. **Views greifen direkt auf Singletons zu**
   `AppPreferences.shared` aus 4 View-Files (Settings, RecordingOverlay, OutputDashboard, AgentChatsView).

5. **Logger.swift:654 liest `AppPreferences.shared`** — Zyklen-Risiko falls AppPreferences je loggt.

6. **String-typed cross-module Notification**
   `ThemeManager.swift:75-79` postet `"AgentTerminalController.themeDidChange"` als rohen String; Konsument in `AgentTerminalView.swift:267` definiert die Konstante — beide Seiten müssen synchron bleiben.

7. **`GitProjectStatus` shellt `/usr/bin/git` aus einer View-Datei aus** (`AgentChatsView.swift:3019-3067`).

8. **`AgentTheme`, `Color.dynamic`, `Color(hex:)`, `String.nilIfEmpty` sind `private` im 3208-LOC-View-File** — können von keinem anderen View wiederverwendet werden, daher 26 ad-hoc `Color.white/.black.opacity(...)`-Sites in `OnboardingView` und 12 in `RecordingOverlayView`.

---

## 5. Initialisierungs-Reihenfolge beim Launch

1. `WhisperM8App.init()` — Single-instance-Check (`WhisperM8App.swift:11-24`).
2. `setupHotkeys()` (synchron, `WhisperM8App.swift:23, 69-81`).
3. `@StateObject ThemeManager.shared` → `ThemeManager.init()`:
   - lädt `AppPreferences.shared.appearanceOverride`
   - berechnet `resolvedColorScheme`
   - setzt `NSApp.appearance`
   - installiert KVO auf `effectiveAppearance` (`ThemeManager.swift:24-52`)
4. SwiftUI baut Scene-Liste; erstes `Window("Agent Chats")` wird zum Default.
5. `AppDelegate.applicationDidFinishLaunching`:
   - `UNUserNotificationCenter` permission request
   - schedule `ThemeManager.performInitialClaudeThemeSync()`
   - **hardcoded `0.5s asyncAfter`** vor `WindowRequestCenter.shared.request(.onboarding/.agentChats)` (`WhisperM8App.swift:87-110`)
6. Agent-Chats-Window rendert → AgentChatsView instanziiert `AgentSessionStore`, `AgentTerminalRegistry`, `AgentSessionRuntimeStatusStore`, lazy `RuntimeWatcher`/`AutoNamer`/`Summarizer`.
7. Erster Zugriff auf `AppState.shared` erzeugt lazily `RecordingCoordinator`.

**Risiken**:
- Schritt 3 läuft **synchron** vor First-Paint und macht KVO + atomic-write-Vorbereitung.
- Schritt 5 hat ein artifizielles 500-ms-Delay vor Window-Routing → Onboarding flackert verzögert auf.

---

## 6. Zentrale Risiken — TL;DR

| Risiko | Severity | Belege |
|---|---|---|
| **AgentChatsView.swift = 3208 LOC mit 17 inline-structs + 35 helpers** | hoch | A2 vollständige Aufstellung |
| **AgentSessionStore concurrency-race** (5 Instanzen, kein Lock, Background-Writer von AutoNamer/Summarizer/Watcher parallel zur UI) | hoch | A3 §"Concurrency model", A1 |
| **`AgentChatSession.imagePaths` + `hasLaunchedInitialPrompt` non-optional ab Version 2** — alte Workspace-JSONs failed silent zu `.empty` (kompletter Workspace-Verlust) | hoch | A3 §"Schema evolution" + AgentChat.swift:185-186 + AgentSessionStore.swift:30-33 |
| **`RecordingCoordinator` = 884 LOC mit 5 Verantwortungen, mutiert AppState an 94 Stellen, owned NSPanel aus Service-Layer** | hoch | A7 §"Split opportunities", A1 §"Cross-layer" |
| **AgentTheme + Color helpers `private` in AgentChatsView** → blockiert Reuse, 38+ ad-hoc Farb-Literale in anderen Views | hoch | A2 §"Top 10 ROI", A6 §"Token placement" |
| **AppState god-object** mit 18+ Properties, ~31 View-Reads | hoch | A1 §"Top 5 risks" |
| **Service-Layer importiert AppKit + owns NSPanel** | hoch | A1 + A7 |
| **TranscriptRunReportStore: keine Retention/Rotation** — unbegrenztes Disk-Wachstum | mittel | A3 §"TranscriptRunReportStore" |
| **`<0.3s` early-return leakt `isProcessing = true`** → blockierte Folge-Stops | hoch | A7 §"Audio state machine" + RecordingCoordinator.swift:151-154 |
| **Headless CLI ohne Timeout** → hängende `claude -p`/`codex exec` pinnen in-flight set ewig | mittel | A4 §"CLI invocation" |
| **String-typed Notification für Theme** zwischen ThemeManager und Terminal | mittel | A1 + A6 |
| **Drag-Drop UX**: `isTargeted:` nur am Project-Header, nicht an Sessions/Tabs/Trailer → keine Drop-Feedback | mittel | A5 §"UX gaps" |
| **Kein CI**, keine Snapshot-Tests, kein RecordingCoordinator/AudioRecorder/VisualCapture-Test | mittel | A8 §"CI gap" + Coverage-Matrix |
| **`Defaults` SPM-dep ist dead code**, AppPreferences rollt eigene UserDefaults-Wrapper (~150 LOC boilerplate) | niedrig | A3 + A8 |
| **`make install` läuft `lsregister -f` nicht**, nur `make dev` tut's | niedrig | A8 §"Makefile review" |
| **Indexer-Cache evictet gelöschte Files nie** → langsamer Disk-Leak | niedrig | A3 §"Indexer cache" |
| **`AppPreferences.shared` ist `static var`** | niedrig | A1, A3 |
| **Schema-Version fehlt** auf AgentWorkspace und Indexer-Cache — silent migration via failed decode | mittel | A3 §"Schema evolution" |

---

## 7. Was am System gut ist (was wir NICHT anfassen)

- `AgentTranscriptParser` + `AgentTranscriptStatusDecider` (pure, getestet) — saubere Funktional-Core-Architektur.
- `ClaudeThemeWriter` — atomic-rename, debounced, idempotent, fail-closed-on-parse — laut A6 *cleanstes File*.
- `AgentCommandBuilder` — 7 Tests, deterministisch.
- `LoginShellEnvironment` — gut isoliert, mit Tests.
- `AgentSessionStore` API-Tests — 25+ Tests decken Persistenz, Sortierung, Worktree-Migration, Drag-Drop, Summary, Icons ab.
- `AgentTerminalPalette` — sRGB explizit, Light/Dark separat kalibriert (mit kleiner Contrast-Lücke bei light amber).
- `AppearanceOverride` enum + `ThemeManager` — sauber gelöst, korrekte `nil`/`light`/`dark` Semantik.
- Drag-Drop-Custom-UTI-Registrierung via Info.plist + `lsregister` im Makefile — funktioniert, korrekt dokumentiert.

---

Weiterführend: siehe `findings.md` (alle Findings nach Severity) und `refactoring-plan.md` (priorisierte Phasen).
