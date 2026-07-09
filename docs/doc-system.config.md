---
status: aktiv
stand: 2026-07-09
---

# doc-system-Konfiguration: Pfad→Feature-Mapping

Diese Datei steuert, welcher Code-Pfad zu welchem Doku-Bereich unter
`docs/features/` gehört (genutzt von den `/DOC:*`-Workflows des
doc-system-Plugins). Spezifischere Pfade gewinnen gegen allgemeinere.

| Code-Pfad | Feature-Doku |
|---|---|
| `WhisperM8/Services/Dictation/RecordingCoordinator*`, `AudioRecorder*`, `Audio*`, `RecordingTimer*`, `CoreAudioVolumeController*`, `PasteService*`, `FailedRecordingsStore*` | `docs/features/dictation/recording/` |
| `WhisperM8/Windows/`, `WhisperM8/Views/Recording*`, `Views/OverlayPhase.swift`, `Views/MenuBarView.swift` (Recording-Teile) | `docs/features/dictation/recording/` |
| `WhisperM8/Services/Dictation/Transcription*`, `MultipartTranscriptionClient*`, `WhisperM8/Models/TranscriptionProvider.swift` | `docs/features/dictation/transcription/` |
| `WhisperM8/Services/Dictation/PostProcessing*`, `CodexPostProcessor*`, `CodexSupport*`, `CodexStatusCache*`, `CodexErrorSummary*`, `OutputModeStore*`, `PromptPackageBuilder*`, `TranscriptRunReportStore*`, `ProjectPathResolver*` | `docs/features/dictation/ai-output/` |
| `WhisperM8/Models/OutputMode.swift`, `PostProcessingTemplate.swift`, `TranscriptRunReport*.swift`, `CodexPostProcessingModel.swift`, `OutputHistoryFilter.swift` | `docs/features/dictation/ai-output/` |
| `WhisperM8/Views/Settings/Pages/AIOutput*`, `Views/Settings/Models/Output*`, `TemplateEditorModel.swift`, `Views/OutputReportComponents.swift`, `TranscriptReportDetailView.swift` | `docs/features/dictation/ai-output/` |
| `WhisperM8/Services/Dictation/Visual*`, `SelectedContextService*`, `ContextCaptureMerge*`, `ManualScreenClipSession*`, `WhisperM8/Models/SelectedContext.swift`, `TranscriptContextBundle.swift`, `CodexVisualInputMode.swift` | `docs/features/dictation/visual-context/` |
| `WhisperM8/Services/AgentChats/AgentSession*`, `AgentWorkspace*`, `*SessionIndexer*`, `AgentScanCoordinator*`, `AgentDirectoryEventMonitor*`, `*TranscriptReader*`, `BoundedJSONLReader*`, `AgentChatTailExtractor*`, `AgentChatLaunchService*`, `AgentCommandBuilder*`, `AgentPromptRoutingService*`, `AgentHeadlessCLI*`, `AgentSessionNotifier*`, `GitProjectStatus*`, `AgentProjectIconResolver*`, `AgentProjectPath*` | `docs/features/agent-chats/sessions/` |
| `WhisperM8/Models/AgentChat.swift`, `AgentChatTranscript.swift`, `AgentUIState.swift` | `docs/features/agent-chats/sessions/` |
| `WhisperM8/Views/AgentChats*`, `AgentTab*`, `TabSwitcherModel*`, `TabNav*`, `AgentTerminal*`, `TerminalLinkResolver*`, `Views/Transcript/`, `AgentChatTranscriptView*`, `AgentSessionDetailView*`, `AgentStatusIndicator*`, `ProjectDetailPanel*`, `ProjectPickerKeyboard*` | `docs/features/agent-chats/ui/` |
| `WhisperM8/Services/AgentChats/AgentWindowStore*`, `AgentSidebarModelBuilder*`, `AgentDragDropPlanner*`, `AgentResourceMonitor*` | `docs/features/agent-chats/ui/` |
| `WhisperM8/Services/AgentChats/AgentJob*`, `AgentSupervisorLauncher*`, `SubAgentDiscovery*`, `ProcessAncestry*`, `AgentWorktreeManager*`, `WhisperM8/Views/SubagentJobDetailView.swift`, `Views/BackgroundDispatchModal.swift` | `docs/features/agent-chats/sub-agents/` |
| `WhisperM8/Services/AgentChats/BackgroundAgent*`, `ClaudeHook*`, `SupervisorJobReader*`, `ActiveBackgroundSessionTracker*`, `ClaudeActiveSessionTracker*`, `SummaryStartupPlanner*`, `ClaudeThemeWriter*`, `ExternalClaudeHooksInspector*` | `docs/features/agent-chats/background-agents/` |
| `WhisperM8/Services/AgentChats/CodexExec*`, `CodexTurnExecutor*`, `CodexReportSchema*`, `CodexAgentPreflight*`, `WhisperM8/Models/CodexReasoningEffort.swift`, `CodexServiceTier.swift`, `Views/Settings/Models/CodexConnectionModel.swift` | `docs/features/agent-chats/codex-exec/` |
| `WhisperM8/CLI/`, `WhisperM8/Services/Shared/CLISymlinkInstaller.swift`, `CLISkillExporter.swift` | `docs/features/cli/` |
| `WhisperM8/Views/Settings/` (Pages, Kit, Models — außer oben zugeordneten), `Views/SettingsView.swift`, `Support/AppPreferences.swift` | `docs/features/settings/` |
| `WhisperM8/Views/OnboardingView.swift`, `AppUpdateViews.swift`, `WhisperM8/Models/AppUsageProfile.swift`, `Services/Shared/AppProfileActivator.swift`, `AppUpdateChecker.swift`, `WhisperM8App.swift`, `Views/MenuBarView.swift` (Quick-Actions) | `docs/features/app-shell/` |
| `WhisperM8/Services/Shared/` (Rest: LoginShellEnvironment, PermissionService, KeychainManager, PerformanceSignposts, FileEventSource, WindowRequestCenter, Logger, …), `WhisperM8/Support/`, `WhisperM8/Models/AppState.swift` | `docs/ARCHITECTURE.md` (Querschnitt) |

## Konventionen

- Neue Feature-Doku folgt dem Muster `README.md` (fachlich, mit `## Keywords`) + `ARCHITECTURE.md` (Komponenten, Datenflüsse, Invarianten, Test-Cluster); Vorbild: `docs/features/agent-chats/sub-agents/`.
- Historisches nach `docs/archive/`, offene Vorhaben nach `docs/plans/`, externe Referenzen nach `docs/referenz/`.
- Doku auf Deutsch; Schlüsseldateien als Pfad + Rolle, ohne Zeilennummern.
