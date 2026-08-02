import SwiftUI

/// Der Workspace als Flächen-Ansicht.
///
/// **Was sich mit Schema v5 geändert hat:** Es gibt keine festen Plätze mehr,
/// keine Kapazität und keine Löcher. Ein Workspace ist eine Liste von Zellen;
/// wo sie landen, rechnet `LayoutGeometry` aus. Alles, was früher an Slots
/// hing — Kapazitäts-Picker, Growzone, Shrink-Auswahl, leere Slots — ist damit
/// ersatzlos entfallen und nicht ersetzt worden.
///
/// Die Ansicht selbst steckt in `WorkspaceLayoutView`; hier wird nur
/// verdrahtet: Inhalt je Session, Züge an den Store, Fokus.
extension AgentChatsView {

    /// Der Workspace, den dieses Fenster zeigt (Grid ODER Rücksprungziel).
    var activeGridWorkspaceEntity: WorkspaceLayout? {
        windowStore.activeGridWorkspace(in: windowID)
    }

    /// Control für die Chat-Statuszeile der Einzelansicht — nur sichtbar,
    /// wenn ein Rücksprungziel existiert.
    @ViewBuilder
    var returnToWorkspaceButton: some View {
        if !isGridActive, let entity = activeGridWorkspaceEntity {
            HeaderIconButton(
                systemImage: "square.grid.2x2",
                help: "Zurück zum Workspace „\(entity.name)“"
            ) {
                returnToWorkspace()
            }
        }
    }

    /// Bringt ein anderes Agent-Chats-Fenster nach vorn (Konflikt-Routing
    /// der Single-Owner-Politik) — reiner Fenster-Fokus über die
    /// Fenster-ID, OHNE die Ansicht des Besitzers zu mutieren.
    func focusWindow(_ ownerWindowID: UUID) {
        WindowRequestCenter.shared.requestWindowFocus(windowID: ownerWindowID)
    }

    // MARK: - perf.grid

    /// perf.grid: Aufbau-Messung am ÜBERGANG starten (vor dem Mount — die
    /// Panes attachen während `makeNSView`).
    func beginGridBuildMeasurement(for entity: WorkspaceLayout? = nil) {
        let target = entity ?? activeGridWorkspaceEntity
        let expected = target?.visibleSessions
            .filter { terminalRegistry.controller(for: $0) != nil } ?? []
        GridPerformanceTracker.shared.beginBuild(expectedPaneIDs: Set(expected))
    }

    // MARK: - Container

    @ViewBuilder
    var gridWorkspace: some View {
        if let entity = activeGridWorkspaceEntity {
            gridWorkspaceContent(entity: entity)
        } else {
            Color.clear
        }
    }

    private func gridWorkspaceContent(entity: WorkspaceLayout) -> some View {
        // Snapshot GENAU EINMAL pro Body-Eval — die Inhalts-Closure darf die
        // Session-Map nicht je Fläche neu berechnen.
        let sessionsByID = Dictionary(
            workspace.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return WorkspaceLayoutView(
            layout: entity,
            focusedSessionID: selectedSessionID,
            zoomedSessionID: zoomedGridSessionID,
            titleForSession: { sessionsByID[$0]?.title ?? "Chat" },
            onFocus: { sessionID in
                guard sessionID != selectedSessionID else { return }
                GridPerformanceTracker.shared.beginFocusSwitch(target: sessionID)
                selectedSessionID = sessionID
            },
            onActivate: { sessionID in
                windowStore.activateInStack(sessionID, inGridWorkspace: entity.id)
                selectedSessionID = sessionID
            },
            onDrop: { sessionID, target in
                windowStore.applyDrop(sessionID, target: target, inGridWorkspace: entity.id)
            },
            onDividerMoved: { handle, offset in
                windowStore.moveDivider(
                    inGridWorkspace: entity.id,
                    leadingCellID: handle.leadingCellID,
                    trailingCellID: handle.trailingCellID,
                    offset: offset,
                    available: handle.available
                )
            },
            content: { sessionID in
                gridPane(for: sessionID, sessionsByID: sessionsByID)
            }
        )
        .onChange(of: selectedSessionID) { _, selected in
            guard let selected else { return }
            // F11: alter Fokus wird Hintergrund (drosselt), neuer Fokus
            // flusht seinen Rückstand VOR dem Tastatur-Fokus.
            applyGridOutputPriorities(entity: entity, focused: selected)
            terminalRegistry.controller(for: selected)?.focusTerminal()
        }
        .onChange(of: entity.cells) { _, _ in
            hoveredGridPaneID = nil
            applyGridOutputPriorities(entity: entity, focused: selectedSessionID)
        }
        .onAppear { applyGridOutputPriorities(entity: entity, focused: selectedSessionID) }
        .onDisappear {
            hoveredGridPaneID = nil
            resetGridOutputPriorities()
        }
    }

    // MARK: - Statuszeile

    func gridWorkspaceStatusRow(entity: WorkspaceLayout) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: entity.colorHex))
            Text(entity.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            // Es gibt keine Kapazität mehr — nur noch, wie viele Chats
            // tatsächlich drin sind.
            Text("\(entity.allSessions.count) Chats")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(AgentTheme.textTertiary)

            Spacer(minLength: 8)

            // Zurück zur automatischen Anordnung — der sichtbare Schalter aus
            // Entscheidung F6. Nur wenn überhaupt von Hand geteilt wurde.
            if !entity.arrangement.isAutomatic {
                Button("Automatisch anordnen") {
                    windowStore.resetArrangement(ofGridWorkspace: entity.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textSecondary)
                .help("Verwirft die von Hand gezogene Aufteilung")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Eine Fläche

    @ViewBuilder
    private func gridPane(
        for sessionID: UUID,
        sessionsByID: [UUID: AgentChatSession]
    ) -> some View {
        if let session = sessionsByID[sessionID] {
            let isFocused = sessionID == selectedSessionID
            let project = workspace.projects.first { $0.id == session.projectID }

            VStack(spacing: 0) {
                if let project {
                    sessionDetailContent(
                        for: session,
                        project: project,
                        // Nur die Fokus-Pane darf Prozesse starten und den
                        // Tastatur-Fokus ziehen — sonst spawnt der Aufbau
                        // mehrere PTYs und die Panes kämpfen um den Fokus.
                        suppressesAutoActivation: !isFocused
                    )
                    .id(session.id)
                    .padding(.top, 14)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                } else {
                    ContentUnavailableView("Projekt fehlt", systemImage: "questionmark.folder")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onHover { hovering in
                if hovering {
                    hoveredGridPaneID = session.id
                } else if hoveredGridPaneID == session.id {
                    hoveredGridPaneID = nil
                }
            }
        } else {
            Color.clear
        }
    }

    // MARK: - Ausgabe-Drosselung (Plan F11)

    func applyGridOutputPriorities(entity: WorkspaceLayout, focused: UUID?) {
        let shouldThrottle = Set(entity.visibleSessions.filter { $0 != focused })
        for sessionID in throttledGridPaneIDs.subtracting(shouldThrottle) {
            terminalRegistry.controller(for: sessionID)?.setOutputPriority(.focusedVisible)
        }
        for sessionID in shouldThrottle {
            terminalRegistry.controller(for: sessionID)?.setOutputPriority(.backgroundVisible)
        }
        throttledGridPaneIDs = shouldThrottle
    }

    /// Grid verschwindet: ALLE gedrosselten Panes zurück auf sofortige
    /// Verarbeitung (Registry-basiert — nicht nur die aktuellen Zellen).
    func resetGridOutputPriorities() {
        for sessionID in throttledGridPaneIDs {
            terminalRegistry.controller(for: sessionID)?.setOutputPriority(.focusedVisible)
        }
        throttledGridPaneIDs = []
    }
}
