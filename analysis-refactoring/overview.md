# WhisperM8 Refactoring Overview

Stand: 2026-05-11

## Scope

Diese Analyse bewertet die komplette macOS-App statisch und mit Subagent-Unterstuetzung. Es wurden keine funktionalen App-Aenderungen vorgenommen. Neu erstellt wurden nur Analyse-Artefakte unter `analysis-refactoring/`.

## Architekturueberblick

WhisperM8 ist ein SwiftPM-basiertes macOS-14+-App-Target mit SwiftUI, AppKit-Interop und SwiftTerm. Die Ordnerstruktur (`Models`, `Services`, `Views`, `Windows`, `Support`) ist fachlich sinnvoll, aber alle Typen leben in einem einzigen Swift-Modul. Die App kombiniert eine normale Dock-App mit Menu Bar Extra, globalem Recording-Hotkey, Transkription, Postprocessing, visuellen Kontext-Anhaengen und einem Agent-Chat-Hub fuer Codex/Claude.

## Wichtigste Module

- App Shell: `WhisperM8/WhisperM8App.swift`
  - `Window("Agent Chats")`, `MenuBarExtra`, Settings, Onboarding, AppDelegate-Routing, Hotkeys.
- Global State: `WhisperM8/Models/AppState.swift`
  - `@Observable` Singleton-Fassade fuer Recording/UI-State, delegiert an `RecordingCoordinator`.
- Recording Pipeline:
  - `WhisperM8/Services/RecordingCoordinator.swift`
  - `WhisperM8/Services/AudioRecorder.swift`
  - `WhisperM8/Windows/RecordingPanel.swift`
  - Verantwortlich fuer Audio, Overlay, Kontext, Transkription, Postprocessing, Clipboard, Auto-Paste und Reports.
- Transcription:
  - `WhisperM8/Services/TranscriptionService.swift`
  - `WhisperM8/Models/TranscriptionProvider.swift`
- Output/Postprocessing:
  - `WhisperM8/Models/OutputMode.swift`
  - `WhisperM8/Services/PostProcessingService.swift`
  - `WhisperM8/Services/PromptPackageBuilder.swift`
  - `WhisperM8/Views/OutputDashboardView.swift`
- Context Capture:
  - `WhisperM8/Services/SelectedContextService.swift`
  - `WhisperM8/Services/VisualContextCaptureService.swift`
  - `WhisperM8/Models/TranscriptContextBundle.swift`
- Agent Chats:
  - `WhisperM8/Views/AgentChatsView.swift`
  - `WhisperM8/Models/AgentChat.swift`
  - `WhisperM8/Services/AgentSessionStore.swift`
  - `WhisperM8/Services/AgentSessionIndexer.swift`
  - `WhisperM8/Services/AgentSessionRuntimeWatcher.swift`
  - `WhisperM8/Services/AgentSessionAutoNamer.swift`
  - `WhisperM8/Services/AgentSessionSummarizer.swift`
  - `WhisperM8/Views/AgentTerminalView.swift`

## Datenfluesse

### Recording

Hotkey -> `AppState.startRecording()` -> `RecordingCoordinator.startRecording()` -> Kontext erfassen -> `AudioRecorder.startRecording()` -> Overlay anzeigen -> Hotkey release -> `AudioRecorder.stopRecording()` -> STT -> optional Postprocessing -> Clipboard/Auto-Paste -> `TranscriptRunReportStore`.

### Agent Chat Context

`AgentChatsView` synchronisiert die aktuelle Auswahl via `syncActiveAgentChat()` in `AppState.activeAgentChat`. `RecordingCoordinator` uebernimmt diesen Kontext nur, wenn WhisperM8 beim Recording-Start frontmost ist.

### Agent Sessions

Agent-Chats-UI mutiert `AgentSessionStore` JSON-Datei. `AgentTerminalRegistry` startet SwiftTerm-Prozesse. `AgentSessionRuntimeWatcher` pollt Provider-Transcripts. Indexer importieren Codex/Claude-History. Auto-Namer und Summarizer schreiben Titel/Summaries zurueck in denselben Store.

## Zentrale Risiken

- `AgentChatsView.swift` ist der groesste Wartbarkeitsblock: 3208 Zeilen, viele UI- und Domain-Verantwortlichkeiten in einer Datei.
- `RecordingCoordinator.swift` ist ein God Coordinator mit hoher User-Journey-Relevanz und wenig Testseams.
- `AgentSessionStore` nutzt ungeschuetzte JSON-Read-Modify-Write-Pfade; Lost Updates sind bei parallelen Tasks moeglich.
- Globale Singletons (`AppState.shared`, `AppPreferences.shared`, `ThemeManager.shared`, `CodexProcessRegistry.shared`) machen Tests und Refactors indirekt.
- AppKit/Theming/Window-Chrome ist ueber `ThemeManager`, `AgentChatsWindowAccessor`, `AgentTerminalPalette` und Scene-Overrides verteilt.
- Build-Setup hat driftende Quellen: SwiftPM/Makefile ist aktuell, Xcode-Projekt und alte Skripte sind stale.
- Tests sind fuer pure Logik gut, aber kritische Recording-/Paste-/Overlay-/HTTP-Flows fehlen.

## Subagent-Abdeckung

Es wurden 10 Analysebereiche mit Subagents bzw. lokalen Ergaenzungen abgedeckt. Die Einzelergebnisse liegen in `analysis-refactoring/subagent-notes/`.
