# Architecture & module structure

Snapshot of 58 Swift files in `WhisperM8/`. Line refs are file:line. Inferences marked **(inf)**.

## Module dependency map

```
                       ┌──────────────────────────────┐
                       │   WhisperM8App.swift (@main) │
                       └─────────────┬────────────────┘
                                     │ owns
        ┌────────────────────────────┼──────────────────────────────┐
        ▼                            ▼                              ▼
   Views/ (~20)             Models/AppState (singleton)       MenuBarExtra
        │                            │
        │ reads AppState.shared      │ holds @ObservationIgnored
        │ reads AppPreferences.shared│ RecordingCoordinator
        │ instantiates Services      │
        ▼                            ▼
   Services/ (~25)  ◄──────────  RecordingCoordinator
        │                            │
        ├──► Support/AppPreferences (struct singleton)
        ├──► Support/ThemeManager   (ObservableObject singleton)
        ├──► Support/AppearanceOverride / TextNormalizer
        └──► Windows/RecordingPanel + OverlayController
             (NSPanel, ownership by Coordinator — Service layer
              imports AppKit & owns a window — see leak section)
```

External deps: KeyboardShortcuts, Defaults, LaunchAtLogin, ISSoundAdditions, SwiftTerm. SwiftTerm only consumed in `Views/AgentTerminalView.swift:2`.

## Critical data flows

**Recording flow.** Hotkey is registered in `WhisperM8App.setupHotkeys()` (`WhisperM8App.swift:69–81`). Key-down/up route to `AppState.shared.startRecording()` / `stopRecording()` on `@MainActor`. `AppState` is a thin facade (`Models/AppState.swift:59–65`) — all logic is delegated to `RecordingCoordinator` which `AppState` instantiates in its private init (`Models/AppState.swift:55–57`). `RecordingCoordinator` owns `AudioRecorder`, `OverlayController`, `PasteService`, `RecordingTimer`, `PostProcessingService`, `SelectedContextService`, `VisualContextCaptureService`, `VisualAttachmentDeliveryBuilder`, `TranscriptRunReportStore` (`Services/RecordingCoordinator.swift:17–35`) and writes back into `AppState` via a `weak var appState` reference (`Services/RecordingCoordinator.swift:32`, used `RecordingCoordinator.swift:85–96`). Audio is captured by `AudioRecorder` (AVAudioEngine, 16 kHz mono PCM/M4A, `Services/AudioRecorder.swift:507–535`). After stop the file is handed to `TranscriptionService` (protocol-based, `Services/TranscriptionService.swift:1119–1153`), result is copied via `PasteService` (`Services/PasteService.swift:783–795`), optionally auto-pasted via CGEvent, and an artifact is persisted to `TranscriptRunReportStore`.

**Agent-chat flow.** `Views/AgentChatsView.swift:16` owns `@State store = AgentSessionStore()`; the same struct is re-instantiated in `AgentChatsView.swift:928`, `AgentChatsView.swift:2722`, `Services/AgentChatLaunchService.swift:11`, and `Services/RecordingCoordinator.swift:595` — there is no central store, so persistence races between callers are possible **(inf — none of these instantiations share state in memory; each call re-reads/re-writes the JSON file)**. `AgentTerminalRegistry` (`Views/AgentTerminalView.swift:5–48`) lives in `AgentChatsView` as `@StateObject` and produces `AgentTerminalController` instances (`AgentTerminalView.swift:187–315`) that wrap `SwiftTerm.LocalProcessTerminalView` and spawn the Codex/Claude CLI subprocess. Live JSONL tailing is done by `AgentSessionRuntimeWatcher` (file polling, `Services/AgentSessionRuntimeWatcher.swift:262+`) which feeds `AgentSessionRuntimeStatusStore` (an `@StateObject` again in `AgentChatsView`).

**Theme flow.** `ThemeManager.shared` (`Support/ThemeManager.swift:11`) KVOs `NSApp.effectiveAppearance` (`ThemeManager.swift:42–52`), reads/writes `AppPreferences.shared.appearanceOverride`, and on change (a) posts a `Notification.Name("AgentTerminalController.themeDidChange")` (`ThemeManager.swift:75–79`) so `NSViewRepresentable` terminals can repaint, and (b) calls `ClaudeThemeWriter.shared.syncIfNeeded(...)` (`ThemeManager.swift:82`) which mutates `~/.claude.json`. SwiftUI scenes read `themeManager.override.preferredColorScheme` for `.preferredColorScheme` modifiers (`WhisperM8App.swift:32, 41, 54, 63`).

## Singletons / shared state

- `AppState.shared` — `Models/AppState.swift:6`. `@MainActor @Observable`. Holds 18+ mutable properties + `RecordingCoordinator`. Reached by ~31 sites in `Views/` (grep). Risk: god object; impossible to test recording flow in isolation.
- `AppPreferences.shared` — `Support/AppPreferences.swift:4`. `static var` (mutable!) — could be reassigned at runtime. Reached from Views, Services, Models. ~40+ usages.
- `ThemeManager.shared` — `Support/ThemeManager.swift:11`. Posts a string-named Notification (`ThemeManager.swift:76`) — typo-prone.
- `ClaudeThemeWriter.shared` — `Services/ClaudeThemeWriter.swift:26`. Writes to `~/.claude.json`. Side-effect on disk from a singleton.
- `WindowRequestCenter.shared` — `Services/WindowRequestCenter.swift:24`. ObservableObject + `DistributedNotificationCenter`. Used by `WhisperM8App.swift:103, 107, 116` and `Services/AgentChatLaunchService.swift:35`.
- `LoginShellEnvironment.shared` — `Services/LoginShellEnvironment.swift:23`. `@unchecked Sendable`.
- `AudioDeviceManager.shared` — `Services/AudioDeviceManager.swift:46`. Holds CoreAudio C-callback (`AudioDeviceManager.swift:432`).
- `AudioDuckingManager.shared` — `Services/AudioDuckingManager.swift:125`.
- `CodexProcessRegistry.shared` — `Services/PostProcessingService.swift:7`. Tracks `weak var current: Process?`. **(inf)** terminate-on-cancel races possible.
- `AgentCommandPathCache.shared` — `Services/AgentCommandBuilder.swift:218`.

## Cross-layer leaks

- **Service layer owns AppKit UI.** `RecordingCoordinator` (a Service) imports `AppKit` (`RecordingCoordinator.swift:1`) and owns `OverlayController` (`RecordingCoordinator.swift:19, 45`), which in turn owns an `NSPanel`/`NSHostingView` (`Windows/RecordingPanel.swift:195–197`). The Service layer effectively presents UI.
- **Model imports AppKit.** `Models/TranscriptContextBundle.swift:1` imports `AppKit` — model layer reaches into UI types **(inf — used for NSImage/clipboard types)**.
- **Views instantiate Services directly.** `AgentChatsView` creates `AgentSessionStore()` three times (`AgentChatsView.swift:16, 928, 2722`), `AgentSessionRuntimeStatusStore`, `AgentTerminalRegistry`, `AgentTerminalController`, `AgentSessionAutoNamer`, `AgentSessionSummarizer` — no coordinator. (`AgentChatsView.swift:16–38`)
- **Views read singletons directly.** `AppPreferences.shared` read by Settings, RecordingOverlay, OutputDashboard, AgentChatsView (4 view files).
- **Logger reaches into Preferences.** `Services/Logger.swift:654` reads `AppPreferences.shared.isDebugFileLoggingEnabled` — cycle risk if Preferences ever logs.
- **String-typed cross-module notification.** `ThemeManager.swift:76` posts `"AgentTerminalController.themeDidChange"` — coupled by string, not type.
- **`AppPreferences.shared` is `static var`.** `Support/AppPreferences.swift:4` — could be reassigned (intended for tests, but no compiler guard).

## Initialization order at launch

1. `WhisperM8App.init()` — duplicate-instance check, on duplicate posts distributed notification + `NSApp.terminate(nil)` (`WhisperM8App.swift:11–24`).
2. `setupHotkeys()` registers two global hotkey listeners synchronously (`WhisperM8App.swift:23, 69–81`).
3. `@StateObject ThemeManager.shared` is read → `ThemeManager.init()` runs: loads `AppPreferences.shared.appearanceOverride`, computes initial color scheme, sets `NSApp.appearance`, installs KVO (`ThemeManager.swift:24–52`). This touches `NSApp` before any window exists — works only because `NSApp` is available pre-scene **(inf)**.
4. SwiftUI builds the scene list. The first `Window("Agent Chats")` becomes the default window.
5. `AppDelegate.applicationDidFinishLaunching` fires: requests `UNUserNotificationCenter` permission, schedules `ThemeManager.performInitialClaudeThemeSync()` and either `WindowRequestCenter.shared.request(.onboarding)` or `.agentChats` after a 0.5 s `DispatchQueue.main.asyncAfter` (`WhisperM8App.swift:87–110`).
6. When the Agent-Chats `Window` is rendered, `AgentChatsView` instantiates `AgentSessionStore`, `AgentTerminalRegistry`, `AgentSessionRuntimeStatusStore`, and lazily `AgentSessionRuntimeWatcher`/`AutoNamer`/`Summarizer` (`AgentChatsView.swift:16–38`).
7. First access to `AppState.shared` lazily creates `RecordingCoordinator` (`Models/AppState.swift:55–57`).

Concern: step 3 (KVO + theme write) runs synchronously on the main thread before paint; step 5 includes a 0.5 s artificial delay before window routing — Onboarding never appears until 500 ms after launch.

## Top 5 architectural risks

1. **God-object `AppState`** (`Models/AppState.swift:5–106`) — 18 mutable observable properties + a coordinator, reached directly from ~31 sites in Views. Severity **hoch**. Refactor: split into `RecordingState`, `ContextState`, `PostProcessingState`, expose via environment objects.
2. **Service layer owns UI** (`Services/RecordingCoordinator.swift:1, 19, 45` + `Windows/RecordingPanel.swift:195`) — Services import AppKit and manage `NSPanel`. Severity **hoch**. Refactor: move `OverlayController` out of Services into a Presentation/Coordinator module; pass overlay events via a protocol the coordinator exposes.
3. **`AgentSessionStore` instantiated 5× with no shared in-memory state** (`AgentChatsView.swift:16, 928, 2722`; `AgentChatLaunchService.swift:11`; `RecordingCoordinator.swift:595`) — every call hits disk, no single source of truth, concurrent writes from `AutoNamer`/`Summarizer`/UI race on the same JSON file. Severity **hoch**. Refactor: make it `@MainActor` ObservableObject with a single instance in an environment.
4. **`AppPreferences.shared` is `static var` and read everywhere** (`Support/AppPreferences.swift:4`; used in 40+ sites, including `Logger.swift:654`). Severity **mittel**. Risk: mutable singleton + Logger cycle on launch if logging ever happens before `AppPreferences` is fully initialized **(inf)**. Refactor: `static let` or inject.
5. **String-typed cross-module Notification for theme** (`ThemeManager.swift:75–79` ↔ `AgentTerminalController` consumer) — silent break if either side changes the string. Severity **mittel**. Refactor: typed `Notification.Name` extension in a shared file, or replace with Combine `@Published`.

Honorable mention (niedrig): `AppDelegate.applicationDidFinishLaunching` uses a hardcoded `0.5 s` `asyncAfter` before opening the initial window (`WhisperM8App.swift:102, 106`) — should hook into a SwiftUI lifecycle event instead.
