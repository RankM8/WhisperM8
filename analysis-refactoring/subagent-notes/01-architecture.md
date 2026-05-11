# Subagent 01 - Architektur- und Modulstruktur

## Kurzbefund

WhisperM8 ist ein einzelnes SwiftPM-App-Target. Die Ordner `Models`, `Services`, `Views`, `Windows` und `Support` geben eine fachliche Struktur vor, aber es gibt keine Modulgrenzen auf Swift-Ebene. Die wichtigsten Datenfluesse laufen ueber globale Singletons und grosse Koordinatoren.

## Zentrale Module

- `WhisperM8/WhisperM8App.swift`: App-Shell mit `Window`, `MenuBarExtra`, Settings, Onboarding, Hotkeys und AppDelegate-Routing.
- `WhisperM8/Models/AppState.swift`: `@Observable` Singleton-Fassade fuer UI-State und Recording-Aktionen.
- `WhisperM8/Services/RecordingCoordinator.swift`: Aufnahme, Kontext, Overlay, Transkription, Postprocessing, Paste Delivery und Reports.
- `WhisperM8/Services/TranscriptionService.swift` und `WhisperM8/Models/TranscriptionProvider.swift`: STT-Provider, Multipart-Upload und Model/Provider-Migration.
- `WhisperM8/Models/OutputMode.swift`, `WhisperM8/Services/PostProcessingService.swift`, `WhisperM8/Services/PromptPackageBuilder.swift`: Output-Modi, Templates, Codex-CLI, visuelle Inputs und Fallbacks.
- `WhisperM8/Services/SelectedContextService.swift`, `WhisperM8/Services/VisualContextCaptureService.swift`, `WhisperM8/Models/TranscriptContextBundle.swift`: selektierter Text, Screenshots, ScreenCaptureKit-Clips und Visual Frames.
- `WhisperM8/Models/AgentChat.swift`, `WhisperM8/Views/AgentChatsView.swift`, `WhisperM8/Services/AgentSessionStore.swift`, `WhisperM8/Views/AgentTerminalView.swift`: Agent-Chats, Projekte, Sessions, SwiftTerm, Indexing, Runtime-Watcher, Auto-Naming und Summaries.

## Datenfluesse

- Hotkey -> `AppState.startRecording()` -> `RecordingCoordinator.startRecording()`.
- Recording Start -> Frontmost App/Context erfassen -> `AudioRecorder.startRecording()` -> `OverlayController.show()`.
- Recording Stop -> `AudioRecorder.stopRecording()` -> STT-Service -> `TextNormalizer` -> optional `PostProcessingService`.
- Delivery -> Clipboard -> optional Auto-Paste -> `TranscriptRunReportStore`.
- Agent Chat Context -> `AgentChatsView.syncActiveAgentChat()` schreibt `AppState.activeAgentChat`; `RecordingCoordinator` uebernimmt nur, wenn WhisperM8 beim Start frontmost ist.
- Agent Sessions -> UI mutiert `AgentSessionStore` JSON -> `AgentTerminalRegistry` startet SwiftTerm -> `AgentSessionRuntimeWatcher` pollt JSONL-Transcripts.

## Risiken

- `RecordingCoordinator` ist ein God Coordinator mit vielen Verantwortlichkeiten.
- `AgentChatsView.swift` enthaelt View-State, Persistenzaufrufe, Indexing, Drag-and-Drop, Auto-Naming, Summary-Trigger und Prozesssteuerung.
- Globale Singletons (`AppState.shared`, `AppPreferences.shared`, `ThemeManager.shared`, `CodexProcessRegistry.shared`) erschweren Isolation und nebenlaeufige Tests.
- Viele Services lesen direkt `AppPreferences.shared` und `FileManager.default`.
- Dateibasierte Persistenz nutzt synchrone Read-Modify-Write-Pfade ohne Locking.
- `docs/ARCHITECTURE.md` ist wahrscheinlich veraltet gegenueber Agent Chats, Output Dashboard, Visual Context, SwiftTerm und `RecordingCoordinator`.
