# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WhisperM8 is a native macOS app (Swift 5.9, SwiftUI, macOS 14+, pure SwiftPM — no .xcodeproj) with two halves:

1. **Dictation** — hotkey-driven speech-to-text via OpenAI Whisper or Groq, with optional Codex-CLI post-processing and configurable output modes (rewrite, email, Slack, …).
2. **Agent Chats** — a session manager for Claude Code and Codex CLI: foreground PTY terminals, background agents (`claude --bg`), project organization, live status tracking, and transcript browsing.

Code comments are largely written in German — match that style when editing existing files.

## Build Commands

```bash
make dev          # Recommended: build, in-place sync to /Applications (preserves TCC permissions), launch
make run          # Quick debug build, runs from project dir (separate TCC entry)
make build        # Release build only (creates local .app)
make clean-install # Full reset (removes all app data + reinstall) — use to test onboarding/migrations
make kill         # Kill running instances
make dmg          # Create distributable DMG
```

`make dev` uses `rsync` into the existing bundle on purpose: deleting and recopying the bundle would make macOS TCC revoke mic/accessibility/screen permissions. Run `scripts/setup-codesign-cert.sh` once for a persistent local signing identity (otherwise ad-hoc signing re-prompts TCC on every rebuild).

### Tests

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                                    # full suite
swift test --filter AgentSessionStoreTests    # one test class
swift test --filter testLoginShellEnvironment # by test-name substring
```

`DEVELOPER_DIR` must point at the Xcode toolchain (SwiftUI macros); the Makefile sets it automatically, plain `swift build`/`swift test` does not.

Test convention: dependency injection via plain closures and small protocols (e.g. `commandResolver: { _ in "/path" }`, `ProcessRunner` spies) — no DI framework. Agent-Chats coverage is split across thematic files in `Tests/WhisperM8Tests/` (e.g. `AgentSessionStoreTests.swift`, `AgentCommandBuilderTests.swift`); shared helpers live in `AgentTestSupport.swift`.

## Debugging

```bash
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
```

### Performance-Signposts

Drei Hot-Paths sind mit `os_signpost`-Intervallen + Budgets instrumentiert
(`Services/Shared/PerformanceSignposts.swift`): Kategorien `perf.recording`
(Hotkey→Aufnahme 400 ms, Stop→Transkription 300 ms, Kontext-Teilschritte),
`perf.store` (Mutation 30 ms, Load 15 ms, Save 20 ms) und `perf.sidebar`
(Workspace-Load 50 ms, Status-Poll 100 ms, plus `sidebar.statusChanged`-Events
= Re-Render-Trigger). Budget-Überschreitungen erscheinen als
`perf_budget_exceeded`-Warnungen im `log stream`-Befehl oben; in Instruments
über das os_signpost-Template auswertbar. Budgets sind Startwerte — bei
Anpassungen `PerfBudgets` ändern.

## Architecture

### Code organization

`Services/` is split into three subfolders (Phase-1 refactor, 2026-06-27):
`Services/Dictation/` (audio, transcription, post-processing, recording, visual context),
`Services/AgentChats/` (session store/indexer, runtime watcher, background agents, hooks,
transcript readers, `AgentProjectPath`), and `Services/Shared/` (Logger,
LoginShellEnvironment, PerformanceSignposts, PermissionService, KeychainManager,
FileEventSource, WindowRequestCenter, CLISymlinkInstaller). SwiftPM discovers sources
recursively, so moving files between these folders is build-neutral. The same pass split
several god-files into per-type files (SettingsView → `Views/Settings/`, PostProcessingService,
TranscriptionService, AgentSessionIndexer) and pulled AgentChatsView's NSEvent monitors into
`Views/AgentChatsView+Shortcuts.swift`. A follow-up pass (Phase 2) decomposed `AgentChatsView`
further into thematic `extension` files (`+BackgroundAgents`, `+RuntimeServices`,
`+SessionLifecycle`, `+ProjectManagement`, `+Tabs`, `+DragDrop`), shrinking the main view from
~3684 to ~2426 LOC. The same `extension`-per-concern technique split `RecordingCoordinator`
(1385 → 450 LOC) into `+Transcription`/`+Clipboard`/`+Failure`/`+UI`/`+Context`. (Moved logic
methods/types are `internal` so sibling-file extensions can reach them.) Full roadmap + status:
`docs/refactor/REFACTORING-AUDIT.md`.

### App shell

Regular Dock app (`LSUIElement=false`) plus a `MenuBarExtra` for recording toggle and quick actions. Scenes in `WhisperM8App.swift`: Agent Chats main window, Settings, Onboarding. Closing the last window does not quit (menu bar extra stays alive). `WindowRequestCenter` routes window-open requests between scenes (e.g. menu bar → Agent Chats).

### Dictation pipeline

```
Hotkey (KeyboardShortcuts) → AppState/RecordingCoordinator → AudioRecorder (AVAudioEngine, M4A 16kHz mono)
  → context capture (SelectedContextService, screenshots, active agent-chat tail → TranscriptContextBundle)
  → TranscriptionService (OpenAI/Groq)
  → optional PostProcessingService (spawns codex CLI with OutputMode + template)
  → clipboard / auto-paste (PasteService, CGEvent) or routed into an Agent Chat
```

- `Models/AppState.swift` — central `@Observable` state; recording lifecycle, clipboard, active-agent-chat ref
- `Windows/RecordingPanel.swift` — non-activating NSPanel overlay
- `Services/Dictation/PromptPackageBuilder.swift` — assembles transcript + context into the final prompt
- `Models/OutputMode.swift` / `Services/Dictation/OutputModeStore.swift` — user-defined output targets; modes can override Codex model/runtime settings
- `Services/Shared/KeychainManager.swift` — API keys

### Agent Chats subsystem

The other half of the codebase. Flow: **discovery → persistence → runtime tracking → UI**.

- **Persistence**: in-memory `AgentWorkspaceStore` core (one instance per file URL via `AgentWorkspaceStoreRegistry`; NSLock-serialized mutations, Equatable-diff-gated persistence, debounced 0.5s + atomic for the production URL with willTerminate flush) behind the `AgentSessionStore` facade, backed by `AgentWorkspaceRepository` for disk I/O. Mutation closures must never run subprocesses (they execute under the process-wide store lock — hoist git lookups etc. before the mutate call). SwiftUI observes via the `AgentWorkspaceUIModel` projection; never call `loadWorkspace()` to "refresh" the UI. UI state (open tabs, selection) is a separate sidecar so UI churn never invalidates session data.
- **Discovery/Indexing**: `AgentScanCoordinator` (singleton, scan on launch/foreground, 30s cooldown) drives `AgentSessionIndexer`, which parses external session JSONL from `~/.claude/projects/<encoded-cwd>/*.jsonl` and `~/.codex/sessions/YYYY/MM/DD/*.jsonl` (mtime+size cache).
- **Runtime status**: `AgentSessionRuntimeWatcher` is event-driven with a poll fallback — a vnode `FileEventSource` per active transcript file (write → debounced poll; delete/rename → re-arm), plus a 1.5s timer for URL resolution, stat-first time-based escalation (1 stat() syscall instead of a 64KB read), and missed-event fallback. Derives working/awaitingInput/idle into the ephemeral `AgentSessionRuntimeStatusStore` (per-item `statusPublisher(for:)` for the sidebar rows) and triggers auto-naming (`AgentSessionAutoNamer`). `AgentDirectoryEventMonitor` (FSEvents on `~/.claude/projects` + `~/.codex/sessions`) triggers scans for externally started sessions. Kill switch: `defaults write com.whisperm8.app agentEventDrivenWatchEnabled -bool NO`.
- **Foreground chats**: SwiftTerm `LocalProcessTerminalView` PTYs, managed by `AgentTerminalRegistry` (in `Views/AgentTerminalView.swift`). `AgentCommandBuilder` builds argv (claude/codex, resume vs. new session, keyboard profile per TUI type). **Link-Klicks** (Cmd-Klick, SwiftTerm-Default `.hoverWithModifier`) gehen NICHT an SwiftTerms Default-Handler (der `URL(string:)+NSWorkspace.open` macht und bei schemelosen Dateipfaden mit `-50` scheitert) — `AgentTerminalController.requestOpenLink` routet über den puren, getesteten `TerminalLinkResolver` (Views/): Web→Browser, Datei→Standard-App, Ordner→Finder, fehlend→klare `NSAlert`, Cmd+Alt→im Finder zeigen; relative Pfade gegen `command.workingDirectory` aufgelöst, `path:line`-Suffixe abgeschnitten.
- **Tabs, Multi-Select & Drag** (Chrome-artig): per-Fenster-UI im `AgentWindowStore` (`@Observable`, SSoT) — `openTabIDs`/`selectedSessionID` persistiert in `agent-ui-state.json`, dazu eine **ephemere, nicht persistierte** `multiSelection(in:)` pro Fenster (aktiver Tab = Anker; Menge leer = Einzel-Auswahl, sonst ≥2). `AgentChatsView` bridged via computed properties. Die Selektions-/Drag-*Logik* ist pur + unit-getestet: `TabSelectionResolver` (Click/Cmd/Shift + Pin-Normalisierung `shouldUnpinGroup`), `TabReorderGeometry` (Einfügelinie aus gemessenen Tab-Frames), `TabGroupReorder` (Gruppen-Block-Reorder). Reorder = SwiftUI `.draggable` + `TabReorderDropDelegate` (DropProposal `.move`, Einfügelinie, `.leftMouseUp`-Monitor setzt die Linie zurück); **Tear-off** = `.dropDestination` am Content („Loslassen für neues Fenster" → `detachDroppedToNewWindow`); Cross-Window-Drag liest die Quell-Auswahl live aus dem Store. Modifier-Klicks via `NSEvent.modifierFlags`. Bulk-Kontextmenü (Tabs + Sidebar, „N …"-Labels) in `AgentChatsView+BulkActions`. Die Drag/Drop/Menü-*Interaktionen* sind nicht unit-testbar (SwiftUI/NSEvent) → manuelle QA.
- **Background agents**: spawned via `claude --bg` (`BackgroundAgentSpawner`, parses the short ID from stdout), hosted by the Claude supervisor daemon, attached in a PTY via `claude attach <short-id>`. `SupervisorJobReader` reads `~/.claude/jobs/<short-id>/state.json`; `BackgroundAgentLifecycle` wraps logs/stop/respawn/rm.
- **Hook bridge** (event-driven, no polling): `ClaudeHookSettingsBuilder` writes a settings JSON with SessionStart/SessionEnd/Notification hooks that append to an event file; launched via `claude --settings <path>`. `ClaudeHookBridge` watches that file with `DispatchSourceFileSystemObject` — this is how WhisperM8 binds external session IDs and detects "needs input".
- **Transcripts**: `ClaudeTranscriptReader` / `CodexTranscriptReader` parse the provider JSONL into the unified `AgentChatTranscript` model (streamed line-by-line; files can be >50 MB).

Key persisted paths: `~/Library/Application Support/WhisperM8/AgentSessions.json` (workspace), `agent-ui-state.json`, `agent-index-cache.json`. Everything under `~/.claude/` and `~/.codex/` is external and read-only (except hook settings files WhisperM8 generates).

### Subprocess environment (important gotcha)

GUI apps get a minimal launchd `PATH`. All subprocess spawning must go through:

- `Services/Shared/LoginShellEnvironment.swift` — queries `zsh -l -c 'echo $PATH'` once, merges with a fallback list (includes `~/.local/bin`, where the native Claude Code installer lives), and supplies TERM/COLORTERM so TUIs render in color.
- `AgentCommandBuilder.commandPath(_:)` — central binary resolution (`which` with corrected env + fallback dirs).

Never spawn `claude`/`codex`/shell tools with the raw `ProcessInfo` environment — they won't find user-installed binaries.

## Dependencies (Package.swift)

- **KeyboardShortcuts** (exact 1.16.1) — global hotkeys
- **Defaults** — type-safe UserDefaults
- **LaunchAtLogin-Modern** — launch at startup
- **SwiftTerm** — PTY terminal views for Agent Chats
