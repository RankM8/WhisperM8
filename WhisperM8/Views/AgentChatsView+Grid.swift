import AppKit
import SwiftUI

/// Split-Grid: zeigt die ersten N offenen Tabs gleichzeitig als Panes
/// (Presets 1 · 1×2 · 2×1 · 2×2, fixe 50%-Splits). Reine Präsentation der
/// Tab-Liste — Sidebar und Tab-Strip bleiben unverändert, es gibt keinen
/// zusätzlichen Slot-Zustand. Fokus-Pane = `selectedSessionID` (Akzent-
/// Rahmen); nur sie bekommt Auto-Launch/Auto-Fokus, Klick in eine Pane
/// verschiebt die Selektion. Plan: docs/plans/split-grid-agenten.md (V1).
extension AgentChatsView {
    var gridPreset: AgentGridPreset {
        get { windowStore.gridPreset(in: windowID) }
        nonmutating set { windowStore.setGridPreset(newValue, in: windowID) }
    }

    /// Die sichtbaren Panes: Präfix der Tab-Bar-Reihenfolge.
    var gridSessions: [AgentChatSession] {
        Array(headerTabs.prefix(gridPreset.paneCount))
    }

    // MARK: - Preset-Umschalter (Titelzone)

    var gridPresetSwitcher: some View {
        HStack(spacing: 2) {
            gridPresetButton(.single, icon: "rectangle", help: "Einzelansicht")
            gridPresetButton(.cols2, icon: "rectangle.split.2x1", help: "2 Chats nebeneinander")
            gridPresetButton(.rows2, icon: "rectangle.split.1x2", help: "2 Chats übereinander")
            gridPresetButton(.grid2x2, icon: "square.split.2x2", help: "4 Chats im 2×2-Grid")
        }
    }

    private func gridPresetButton(_ preset: AgentGridPreset, icon: String, help: String) -> some View {
        TitlebarIconButton(systemImage: icon, help: help, isActive: gridPreset == preset) {
            gridPreset = preset
        }
    }

    // MARK: - Grid-Container

    var gridWorkspace: some View {
        Group {
            switch gridPreset {
            case .single:
                EmptyView()
            case .cols2:
                HStack(spacing: 8) {
                    gridSlot(0)
                    gridSlot(1)
                }
            case .rows2:
                VStack(spacing: 8) {
                    gridSlot(0)
                    gridSlot(1)
                }
            case .grid2x2:
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        gridSlot(0)
                        gridSlot(1)
                    }
                    HStack(spacing: 8) {
                        gridSlot(2)
                        gridSlot(3)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
        // Selektion außerhalb des Sichtfensters (Tab-Klick, ⌘1–9, Sidebar):
        // den Tab per Identity-Swap ins Grid holen — er übernimmt den Slot
        // des zuvor fokussierten Tabs (pure Logik, AgentGridLayout).
        .onChange(of: selectedSessionID) { previous, selected in
            guard let selected else { return }
            bringSelectionIntoGrid(selected, previous: previous)
        }
        .onDisappear { hoveredGridPaneID = nil }
    }

    @ViewBuilder
    private func gridSlot(_ index: Int) -> some View {
        let sessions = gridSessions
        if index < sessions.count {
            gridPane(for: sessions[index])
        } else {
            gridEmptySlot
        }
    }

    private var gridEmptySlot: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(AgentTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .background(AgentTheme.background)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(AgentTheme.textTertiary)
                    Text("Kein weiterer Tab offen")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gridPane(for session: AgentChatSession) -> some View {
        let isFocused = session.id == selectedSession?.id
        let project = workspace.projects.first { $0.id == session.projectID }
        return VStack(spacing: 0) {
            gridPaneHeader(session, project: project, isFocused: isFocused)
            if let project {
                sessionDetailContent(
                    for: session,
                    project: project,
                    // Nur die Fokus-Pane darf Prozesse starten und den
                    // Tastatur-Fokus ziehen — sonst spawnt ein Preset-Wechsel
                    // bis zu 4 PTYs und die Panes kämpfen um den Fokus.
                    suppressesAutoActivation: !isFocused
                )
                .id(session.id)
                .padding(6)
            } else {
                ContentUnavailableView("Projekt fehlt", systemImage: "questionmark.folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isFocused ? AgentTheme.accent.opacity(0.8) : AgentTheme.border,
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Hover-Flag fürs Klick-Routing (Muster `isHoveringTabStrip`): der
        // leftMouseDown-Monitor setzt die Selektion auf die gehoverte Pane,
        // ohne das Event zu schlucken — der Klick erreicht das Terminal.
        .onHover { hovering in
            if hovering {
                hoveredGridPaneID = session.id
            } else if hoveredGridPaneID == session.id {
                hoveredGridPaneID = nil
            }
        }
    }

    private func gridPaneHeader(_ session: AgentChatSession, project: AgentProject?, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            SessionLiveStatusDot(
                sessionID: session.id,
                isProcessRunning: terminalRegistry.controller(for: session.id)?.isRunning == true,
                statusStore: runtimeStatusStore
            )
            Text(session.title)
                .font(.system(size: 12, weight: isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let project {
                ProjectAvatar(project: project, size: 13)
                    .help(project.name)
            }
            Spacer(minLength: 6)
            Button {
                closeTab(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Tab schließen")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isFocused ? AgentTheme.header : AgentTheme.header.opacity(0.55))
        .contentShape(Rectangle())
        .onTapGesture { selectedSessionID = session.id }
    }

    // MARK: - Selektion

    /// leftMouseDown-Hook (siehe Monitor in +Shortcuts): Klick in eine
    /// nicht-fokussierte Pane verschiebt die Selektion dorthin. Beobachtend —
    /// das Event läuft unverändert weiter ans Terminal.
    func handleGridPaneMouseDown(_ event: NSEvent) {
        guard let hostWindow, event.window === hostWindow,
              gridPreset != .single,
              let hovered = hoveredGridPaneID,
              hovered != selectedSessionID else { return }
        selectedSessionID = hovered
    }

    private func bringSelectionIntoGrid(_ selected: UUID, previous: UUID?) {
        guard gridPreset != .single else { return }
        if let newOrder = AgentGridLayout.orderBringingIntoView(
            selected: selected,
            openTabIDs: openTabIDs,
            visibleIDs: gridSessions.map(\.id),
            previousSelected: previous
        ) {
            openTabIDs = newOrder
        }
    }

    // MARK: - Geteilter Session-Detail-Pfad

    /// Detail-Ansicht einer Session (Subagent-Job-View bzw. PTY-DetailView) —
    /// aus `mainWorkspace` extrahiert, damit Grid-Panes und Einzelansicht
    /// EXAKT denselben Pfad nutzen (gleiches Verhalten, gleiche Hook-Wiring).
    @ViewBuilder
    func sessionDetailContent(
        for session: AgentChatSession,
        project: AgentProject,
        suppressesAutoActivation: Bool = false
    ) -> some View {
        // Subagent-Jobs rendern die Job-Detail-View (Report + Live-Transcript
        // + Composer) — bis zur Übernahme, dann übernimmt der PTY-Pfad.
        if session.isSubagentJob && !jobRuntimeModel.isTakenOver(session.id) {
            SubagentJobDetailView(
                session: session,
                project: project,
                jobRuntimeModel: jobRuntimeModel,
                onTakeOver: { takeOverSubagentJob(session) },
                onAppearClearUnread: { windowStore.clearSubagentUnread(session.id) }
            )
        } else {
            AgentSessionDetailView(
                project: project,
                session: session,
                terminalRegistry: terminalRegistry,
                actionRequest: sessionActionRequest,
                suppressesAutoActivation: suppressesAutoActivation,
                onStateChanged: loadWorkspaceFast,
                onSessionLaunched: { sessionID in
                    AgentSessionStatusCoordinator.shared.sessionLaunched(sessionID: sessionID)
                },
                onSessionTerminated: { sessionID, exitCode in
                    AgentSessionStatusCoordinator.shared.sessionTerminated(sessionID: sessionID, exitCode: exitCode)
                },
                onExternalSessionIDBound: { sessionID in
                    AgentSessionStatusCoordinator.shared.externalSessionIDBound(sessionID: sessionID)
                },
                onPrepareClaudeHookArguments: { sessionID in
                    AgentSessionStatusCoordinator.shared.prepareLaunchArguments(localSessionID: sessionID)
                },
                onClaudeHookLaunched: { sessionID in
                    AgentSessionStatusCoordinator.shared.hookLaunchDidStart(sessionID: sessionID)
                }
            )
        }
    }
}
