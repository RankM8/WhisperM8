# Subagent 02 - SwiftUI Views und View-Komposition

## Kurzbefund

Der groesste Refactoring-Hebel liegt in `WhisperM8/Views/AgentChatsView.swift` mit 3208 Zeilen. Der Root-View ist inzwischen Shell, Sidebar, Header, Selection-State, Store-Mutation, Indexing, Runtime-Watcher, Auto-Naming, Summary-Generierung, Drag-and-Drop und AppKit-Aktionen zugleich.

## Konkrete Kandidaten

- `AgentChatsView` ab `WhisperM8/Views/AgentChatsView.swift:15`: Root/Shell plus `AgentChatsStateController` oder `AgentChatsViewModel` fuer `loadWorkspaceFast`, `refreshSessionsInBackground`, `syncActiveAgentChat`, `createSession`, `closeHeaderTab`, `requestSummary`.
- `hashboardSidebar`, `sidebarEmptyState`, `sidebarFooter`, `sidebarCommandRows`: nach `AgentChatsSidebarView`.
- `projectChatStrip` und `selectedSessionHeaderControls`: nach `AgentChatsHeaderView` und `SessionHeaderControls`.
- `renameSheet` und `renameProjectSheet`: nach `RenameSessionSheet` und `RenameProjectSheet`.
- `dropSession` und `dropProject`: aus der View in pure Drop/Ordering-Helper oder `AgentSessionDropCoordinator`.
- `ProjectChatGroup`: 20+ Callback-Parameter. Aufteilen in `ProjectGroupHeader`, `ProjectContextMenu`, `SessionContextMenu`; Aktionen als Struct buendeln.
- `sessionManagementMenu` dupliziert Teile des Kontextmenus in `ProjectChatGroup.sessionRow`; als wiederverwendbare `SessionManagementMenu` extrahieren.
- `AgentSessionDetailView`: mischt Detail-UI mit Terminal-Start, Store-Update, Session-Bind und Indexer-Aufruf. Kandidat fuer `AgentSessionLifecycleController`.
- `ProjectDetailPanel` und `GitProjectStatus`: Inspector-UI und Git-Process-Logik trennen; `GitProjectStatus` nach `Services/AgentGitStatusService.swift`.
- `AgentTheme`, `Color.dynamic`, `Color(hex:)`, `colorSwatchImage`: aus dem Feature-View-File nach `Support`/Theming verschieben.

## Weitere View-Dateien

- `WhisperM8/Views/OutputDashboardView.swift`: `OutputModesView` und `OutputTemplatesView` sind eigene Feature-Oberflaechen im selben File.
- `WhisperM8/Views/SettingsView.swift`: `PermissionsSettingsView` enthaelt UI plus Permission-Polling.
- `WhisperM8/Views/RecordingOverlayView.swift`: `ContextMenuContent` ist gross und stark mit Kontextaktionen verdrahtet.
- `WhisperM8/Views/OnboardingView.swift`: `APIKeyStep` ist ein isolierbarer Schritt.

## Dead-Code-Verdacht

- `ProjectChatGroup.groupedSessions` und `relativeTime` wirken ungenutzt.
