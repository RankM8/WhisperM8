import AppKit
import SwiftUI

/// Sidebar-Abschnitt WORKSPACES (Plan F5): einklappbare Sektion unter
/// GEPINNT mit voller Chat-Listen-Optik — Gruppen-Header (Farbe/Initial +
/// Name + Belegung + ⊞) und darunter `PinnedSessionRow`-Rows mit
/// Slot-Badge. Header-Klick öffnet das Grid (Single-Owner-Konflikte
/// fokussieren das Besitzerfenster), Row-Klick folgt der
/// quellenunabhängigen Klickregel (Bridge im `selectedSessionID`-Setter).
/// Unsichtbar bei null Workspaces.
extension AgentChatsView {
    // MARK: - Sektion

    @ViewBuilder
    var workspacesSidebarSection: some View {
        let workspaces = windowStore.gridWorkspaces
        if !workspaces.isEmpty {
            workspacesSectionHeader(count: workspaces.count)
            if !workspacesSectionCollapsed {
                ForEach(workspaces) { entity in
                    workspaceGroup(entity)
                }
            }
        }
    }

    private func workspacesSectionHeader(count: Int) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { workspacesSectionCollapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(workspacesSectionCollapsed ? 0 : 90))
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 8, weight: .bold))
                    Text("WORKSPACES")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                    if workspacesSectionCollapsed {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(workspacesSectionCollapsed ? "Workspaces einblenden" : "Workspaces ausblenden")

            Button {
                createWorkspaceFromSidebar()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Neuer Workspace")
            .accessibilityLabel("Neuen Workspace anlegen")
        }
        .foregroundStyle(AgentTheme.textTertiary)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - Gruppe

    @ViewBuilder
    private func workspaceGroup(_ entity: AgentGridWorkspace) -> some View {
        let isActiveHere = windowStore.window(for: windowID).activeWorkspaceID == entity.id && isGridActive
        VStack(alignment: .leading, spacing: 1) {
            workspaceGroupHeader(entity, isActiveHere: isActiveHere)
            ForEach(Array(entity.slots.enumerated()), id: \.offset) { index, slot in
                if let sessionID = slot,
                   let session = workspace.sessions.first(where: { $0.id == sessionID }) {
                    workspaceRow(session, entity: entity, slotIndex: index)
                }
            }
        }
        // Drop auf die Gruppe = aufnehmen (erster freier Slot/Auto-Wachsen);
        // Ablehnungen (volle Endstufe, archiviert) laufen sichtbar über den
        // gemeinsamen Drop-Pfad statt still `true` zu melden.
        .dropDestination(for: DraggableSession.self) { items, _ in
            guard let dropped = items.first else { return false }
            return handleGridGroupDrop(dropped, workspaceID: entity.id)
        }
    }

    private func workspaceGroupHeader(_ entity: AgentGridWorkspace, isActiveHere: Bool) -> some View {
        Button {
            activateWorkspaceFromSidebar(entity)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: entity.colorHex))
                    .frame(width: 15, height: 15)
                    .overlay {
                        Text(String(entity.name.prefix(1)).uppercased())
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                Text(entity.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("\(entity.occupiedSessionIDs.count)/\(entity.capacity)")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActiveHere ? AgentTheme.accent : AgentTheme.textTertiary)
                    .help("Als Grid öffnen")
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(
                isActiveHere ? AgentTheme.accentTint : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Workspace „\(entity.name)“ als Grid öffnen")
        .contextMenu { workspaceContextMenu(entity) }
        // Sidebar-Reorder: Gruppen-Header ziehen, auf einen anderen Header
        // fallen lassen = davor einsortieren (reorderGridWorkspaces kann
        // durch stale Drags nie Entities verlieren).
        .draggable(DraggableWorkspace(workspaceID: entity.id))
        .dropDestination(for: DraggableWorkspace.self) { items, _ in
            guard let dropped = items.first, dropped.workspaceID != entity.id else { return false }
            reorderWorkspace(dropped.workspaceID, before: entity.id)
            return true
        }
    }

    private func workspaceRow(
        _ session: AgentChatSession,
        entity: AgentGridWorkspace,
        slotIndex: Int
    ) -> some View {
        let rowOrder = entity.occupiedSessionIDs
        return PinnedSessionRow(
            session: session,
            project: workspace.projects.first { $0.id == session.projectID },
            isSelected: selectedSessionID == session.id,
            isMultiSelected: multiSelection.contains(session.id),
            statusStore: runtimeStatusStore,
            isMissingTranscript: missingTranscriptIDs.contains(session.id),
            slotBadge: "S\(slotIndex + 1)",
            onSelect: {
                handleSidebarRowClick(session.id, order: rowOrder) {
                    // Quellenunabhängige Klickregel via Bridge: im sichtbaren
                    // Workspace → Pane-Fokus, sonst Einzelansicht.
                    selectedSessionID = session.id
                }
            },
            onClose: { requestArchive([session]) }
        )
        .padding(.leading, 10)
        .contextMenu {
            Button("Aus Workspace „\(entity.name)“ entfernen", systemImage: "minus.circle") {
                removeSessionFromWorkspace(session.id, workspaceID: entity.id)
            }
            // Ohne Entfernen-Teil — der Eintrag für DIESE Gruppe steht schon
            // direkt darüber (Review-Finding: doppelte Einträge).
            workspaceMembershipMenu(for: session, includeRemoval: false)
        }
        // Sidebar-Quelle = Add/Place-Semantik: bewusst OHNE Slot-Herkunft
        // (die trägt nur der Pane-Header — sonst würde ein Row-Drag im
        // eigenen Grid als Move/Swap statt als Sidebar-Drop aufgelöst).
        .draggable(DraggableSession(
            sessionID: session.id,
            sourceProjectID: session.projectID,
            sourceWindowID: windowID
        ))
    }

    @ViewBuilder
    private func workspaceContextMenu(_ entity: AgentGridWorkspace) -> some View {
        Button("Als Grid öffnen", systemImage: "square.grid.2x2") {
            activateWorkspaceFromSidebar(entity)
        }
        Divider()
        Button("Umbenennen…", systemImage: "pencil") {
            renameWorkspaceDraft = entity.name
            renameWorkspaceTargetID = entity.id
        }
        Menu {
            ForEach(AgentProjectColor.palette, id: \.self) { hex in
                Button {
                    windowStore.setGridWorkspaceColor(entity.id, colorHex: hex)
                } label: {
                    Label(hex == entity.colorHex ? "Aktiv" : hex, systemImage: "circle.fill")
                }
            }
        } label: {
            Label("Farbe", systemImage: "paintpalette")
        }
        Divider()
        Button("Löschen…", systemImage: "trash", role: .destructive) {
            workspacePendingDeletion = entity
        }
    }

    // MARK: - Aktionen

    /// Header-/⊞-Klick: Workspace als Grid öffnen. Single-Owner-Konflikte
    /// werden als Werte gemeldet — kein stilles Stehlen.
    func activateWorkspaceFromSidebar(_ entity: AgentGridWorkspace) {
        beginGridBuildMeasurement()
        switch windowStore.activateGridWorkspace(entity.id, in: windowID) {
        case .activated, .alreadyActiveHere:
            multiSelection = []
        case .alreadyActive(let owner):
            // Ein anderes Fenster zeigt den Workspace bereits — dieses
            // Fenster nach vorn holen statt Terminals zu stehlen.
            focusWindow(owner)
        case .blockedByWindowOwnership(let conflicts):
            errorMessage = "Workspace „\(entity.name)“ kann hier nicht öffnen: \(conflicts.count) \(conflicts.count == 1 ? "Chat läuft" : "Chats laufen") als Tab in einem anderen Fenster."
        case .rejected:
            break
        }
    }

    /// ＋ im Sektions-Header: leeren Workspace anlegen und sofort öffnen —
    /// die sichtbaren leeren Slots sind die Drop-Ziele fürs Befüllen.
    func createWorkspaceFromSidebar() {
        let name = nextFreeWorkspaceName()
        beginGridBuildMeasurement()
        windowStore.createGridWorkspace(name: name, activateIn: windowID)
    }

    /// Multi-Select-Aktion „Neuer Workspace aus Auswahl" (max. 9 —
    /// Überzählige werden benannt abgelehnt). Die Slot-Reihenfolge folgt
    /// der Tab-Reihenfolge (Multi-Selection ist eine ungeordnete Menge).
    func createWorkspaceFromSelection(_ sessionIDs: [UUID]) {
        guard !sessionIDs.isEmpty else { return }
        let tabOrder = openTabIDs
        let ordered = sessionIDs.sorted {
            (tabOrder.firstIndex(of: $0) ?? Int.max) < (tabOrder.firstIndex(of: $1) ?? Int.max)
        }
        let accepted = Array(ordered.prefix(9))
        if sessionIDs.count > 9 {
            errorMessage = "Ein Workspace zeigt höchstens 9 Chats — die ersten 9 der Auswahl wurden aufgenommen, \(sessionIDs.count - 9) nicht."
        }
        beginGridBuildMeasurement()
        windowStore.createGridWorkspace(
            name: nextFreeWorkspaceName(),
            capacity: AgentGridWorkspace.smallestCapacity(fitting: accepted.count),
            slots: accepted.map { $0 },
            activateIn: windowID
        )
        multiSelection = []
    }

    /// Kontextmenü-Eintrag (Tabs + Sidebar, count-abhängiges Label).
    @ViewBuilder
    func newWorkspaceFromSelectionButton(for session: AgentChatSession) -> some View {
        Button(
            bulkLabel("Neuer Workspace mit diesem Chat", "Neuer Workspace aus %d Chats", for: session),
            systemImage: "plus.square.on.square"
        ) {
            createWorkspaceFromSelection(actionGroup(for: session))
        }
    }

    private func nextFreeWorkspaceName() -> String {
        let used = Set(windowStore.gridWorkspaces.map(\.name))
        if !used.contains("Workspace") { return "Workspace" }
        var suffix = 2
        while used.contains("Workspace \(suffix)") { suffix += 1 }
        return "Workspace \(suffix)"
    }

    private func reorderWorkspace(_ movedID: UUID, before targetID: UUID) {
        var order = windowStore.gridWorkspaces.map(\.id).filter { $0 != movedID }
        let insertAt = order.firstIndex(of: targetID) ?? order.endIndex
        order.insert(movedID, at: insertAt)
        windowStore.reorderGridWorkspaces(orderedIDs: order)
    }

    // MARK: - Umbenennen-Sheet

    var renameWorkspaceSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace umbenennen")
                .font(.system(size: 13, weight: .semibold))
            TextField("Name", text: $renameWorkspaceDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commitWorkspaceRename() }
            HStack {
                Spacer()
                Button("Abbrechen") { renameWorkspaceTargetID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Umbenennen") { commitWorkspaceRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameWorkspaceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private func commitWorkspaceRename() {
        if let targetID = renameWorkspaceTargetID {
            windowStore.renameGridWorkspace(targetID, to: renameWorkspaceDraft)
        }
        renameWorkspaceTargetID = nil
    }
}
