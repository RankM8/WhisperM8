import AppKit
import SwiftUI

/// Split-Grid (Maximize/Minimize-Konzept, docs/plans/grid-maximize-minimize-konzept.html):
/// `showsGrid` zeigt ALLE offenen Tabs als bündige Panes — Layout automatisch
/// aus der Tab-Anzahl (`AgentGridAutoLayout`), 1-px-Divider, kein Padding,
/// keine Rundungen. Jede Pane trägt ein Maximize-Control (→ Einzelansicht),
/// die Chat-Statuszeile der Einzelansicht das Minimize-Control (→ Grid).
/// Manuelle Raster-Presets gibt es nicht mehr. Fokus-Pane = `selectedSessionID`
/// (2-px-Inset-Akzent); nur sie bekommt Auto-Launch/Auto-Fokus, Klick in eine
/// Pane verschiebt die Selektion.
extension AgentChatsView {
    var showsGrid: Bool {
        get { windowStore.showsGrid(in: windowID) }
        nonmutating set { windowStore.setShowsGrid(newValue, in: windowID) }
    }

    /// Grid nur sinnvoll ab 2 Tabs — bei einem Tab zeigt `mainWorkspace`
    /// weiterhin die Einzelansicht, auch wenn `showsGrid` true ist.
    var isGridActive: Bool { showsGrid && headerTabs.count > 1 }

    var gridAutoLayout: AgentGridAutoLayout {
        AgentGridAutoLayout.forTabCount(headerTabs.count)
    }

    /// Die sichtbaren Panes: Präfix der Tab-Bar-Reihenfolge.
    var gridSessions: [AgentChatSession] {
        Array(headerTabs.prefix(gridAutoLayout.paneCount))
    }

    // MARK: - Maximize / Minimize

    /// Pane-Maximize: dieser Chat groß in der Einzelansicht.
    func maximizePane(_ sessionID: UUID) {
        selectedSessionID = sessionID
        multiSelection = []
        showsGrid = false
    }

    /// Minimize aus der Einzelansicht: zurück ins Grid mit allen offenen
    /// Tabs. Selektion/Fokus bleiben unangetastet.
    func minimizeToGrid() {
        showsGrid = true
    }

    /// Minimize-Control für die Chat-Statuszeile der Einzelansicht — nur
    /// sichtbar, wenn ein Grid überhaupt etwas zeigen würde (≥ 2 Tabs).
    @ViewBuilder
    var minimizeToGridButton: some View {
        if headerTabs.count > 1, !isGridActive {
            HeaderIconButton(
                systemImage: "square.grid.2x2",
                help: "Alle Chats im Grid zeigen"
            ) {
                minimizeToGrid()
            }
        }
    }

    // MARK: - Grid-Container (bündig, 1-px-Divider)

    var gridWorkspace: some View {
        Group {
            switch gridAutoLayout {
            case .single:
                // Von mainWorkspace nie mit 1 Tab aufgerufen (isGridActive) —
                // defensiver Fallback.
                EmptyView()
            case .cols2:
                HStack(spacing: 1) {
                    gridSlot(0)
                    gridSlot(1)
                }
            case .twoPlusOne:
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        gridSlot(0)
                        gridSlot(1)
                    }
                    gridSlot(2)
                }
            case .grid2x2:
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        gridSlot(0)
                        gridSlot(1)
                    }
                    HStack(spacing: 1) {
                        gridSlot(2)
                        gridSlot(3)
                    }
                }
            }
        }
        // Der 1-px-„Gap" zwischen den Panes IST die Trennlinie — gleiche
        // Farbe wie die übrigen Chrome-Divider. Kein Außen-Padding, keine
        // Karten: die Panes nutzen die volle Fläche.
        .background(AgentTheme.border)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Selektion außerhalb des Sichtfensters (Tab-Klick, ⌘1–9, Sidebar):
        // den Tab per Identity-Swap ins Grid holen — er übernimmt den Slot
        // des zuvor fokussierten Tabs (pure Logik, AgentGridLayout).
        .onChange(of: selectedSessionID) { previous, selected in
            guard let selected else { return }
            bringSelectionIntoGrid(selected, previous: previous)
            // Fokus-Wechsel remountet die Pane-DetailView NICHT (stabile
            // .id) — deren onAppear-Fokus feuert also nicht erneut. Die
            // Tastatur explizit in die neue Fokus-Pane geben, sonst folgt
            // nur der Akzent-Rahmen, das Tippen bliebe im alten Terminal.
            terminalRegistry.controller(for: selected)?.focusTerminal()
        }
        // Layout-Wechsel (Tab-Anzahl) entfernt Panes ohne onHover(false) —
        // Flag räumen, sonst selektiert ein Klick ins Leere eine
        // unsichtbare Session.
        .onChange(of: headerTabs.count) { _, _ in hoveredGridPaneID = nil }
        // Grid-EINTRITT (Minimize-Klick, Launch-Restore): die Selektion ins
        // Sichtfenster holen — der onChange-Swap oben greift nur bei
        // SelektionsWECHSELN, nicht wenn der fokussierte Tab beim Aufbau
        // schon außerhalb der ersten N liegt.
        .onAppear {
            if let selected = selectedSessionID {
                bringSelectionIntoGrid(selected, previous: nil)
            }
        }
        .onDisappear { hoveredGridPaneID = nil }
    }

    @ViewBuilder
    private func gridSlot(_ index: Int) -> some View {
        let sessions = gridSessions
        if index < sessions.count {
            gridPane(for: sessions[index])
        } else {
            // Nur erreichbar, wenn Tabs zwischen Body-Evals schließen —
            // das Auto-Layout passt die Slot-Zahl im nächsten Tick an.
            Rectangle()
                .fill(AgentTheme.background)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                    // Tastatur-Fokus ziehen — sonst spawnt der Grid-Aufbau
                    // bis zu 4 PTYs und die Panes kämpfen um den Fokus.
                    suppressesAutoActivation: !isFocused
                )
                .id(session.id)
            } else {
                ContentUnavailableView("Projekt fehlt", systemImage: "questionmark.folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentTheme.background)
        // Fokus als 2-px-Inset auf der bündigen Pane — dauerhaft sichtbar,
        // kein Karten-Rahmen (Divider kommen aus dem 1-px-Gap).
        .overlay {
            if isFocused {
                Rectangle()
                    .strokeBorder(AgentTheme.accent.opacity(0.8), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
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
                maximizePane(session.id)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Diesen Chat maximieren")
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
        // Doppelklick auf den Header = schneller Maximize-Weg. Der einfache
        // Klick (Fokus) läuft über den leftMouseDown-Monitor — bewusst KEIN
        // zusätzliches Single-Tap-Gesture, das würde den Doppelklick um die
        // Erkennungs-Verzögerung ausbremsen.
        .onTapGesture(count: 2) { maximizePane(session.id) }
    }

    // MARK: - Selektion

    /// leftMouseDown-Hook (siehe Monitor in +Shortcuts): Klick in eine
    /// nicht-fokussierte Pane verschiebt die Selektion dorthin. Beobachtend —
    /// das Event läuft unverändert weiter ans Terminal.
    func handleGridPaneMouseDown(_ event: NSEvent) {
        guard let hostWindow, event.window === hostWindow,
              isGridActive,
              let hovered = hoveredGridPaneID,
              hovered != selectedSessionID else { return }
        selectedSessionID = hovered
        // Wie Tab-/Sidebar-Klick: einfacher Klick verwirft die Mehrfach-Auswahl.
        multiSelection = []
    }

    private func bringSelectionIntoGrid(_ selected: UUID, previous: UUID?) {
        guard isGridActive else { return }
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
