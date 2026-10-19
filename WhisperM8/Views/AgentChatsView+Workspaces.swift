import AppKit
import SwiftUI

/// Trigger-Identität des Projekt-View-Live-Syncs (`.task(id:)` in
/// AgentChatsView): Aktiv-Mengen + Slot-Belegung der offenen Views — ändert
/// sich eins von beidem, läuft der Sync neu. Der Slot-Teil ist die
/// Selbstheilung: Mutiert eine Umgehung (CLI, künftige Pfade) die Slots ohne
/// Aktivmengen-Änderung, konvergiert der nächste Tick zurück zum
/// Live-Zustand.
struct ProjectViewSyncTrigger: Equatable {
    var activeByProject: [UUID: Set<UUID>]?
    var slotsFingerprint: [UUID: [UUID?]]
}

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
    func workspacesSidebarSection(
        subagentChildrenByParent: [UUID: [AgentChatSession]],
        workingSubagentIDs: Set<UUID>,
        erroredSubagentIDs: Set<UUID>
    ) -> some View {
        // Projekt-Views (⊞ am Projekt-Header, sourceProjectID gesetzt) sind
        // versteckte Entities — ihr Anker ist der Projekt-Header in CHATS,
        // hier erscheinen nur kuratierte Workspaces.
        let workspaces = windowStore.gridWorkspaces.filter { $0.sourceProjectID == nil }
        if !workspaces.isEmpty {
            workspacesSectionHeader(count: workspaces.count)
            if !workspacesSectionCollapsed {
                // ID→Session EINMAL für alle Workspaces der Sektion (LR-AU-018).
                let sessionsByID = Dictionary(
                    workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                ForEach(workspaces) { entity in
                    workspaceGroup(
                        entity,
                        sessionsByID: sessionsByID,
                        subagentChildrenByParent: subagentChildrenByParent,
                        workingSubagentIDs: workingSubagentIDs,
                        erroredSubagentIDs: erroredSubagentIDs
                    )
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
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
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
            .help("New workspace")
            .accessibilityLabel("Create new workspace")
        }
        .foregroundStyle(AgentTheme.textTertiary)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - Gruppe

    @ViewBuilder
    private func workspaceGroup(
        _ entity: AgentGridWorkspace,
        sessionsByID: [UUID: AgentChatSession],
        subagentChildrenByParent: [UUID: [AgentChatSession]],
        workingSubagentIDs: Set<UUID>,
        erroredSubagentIDs: Set<UUID>
    ) -> some View {
        let isActiveHere = windowStore.window(for: windowID).activeWorkspaceID == entity.id && isGridActive
        let isCollapsed = windowStore.isGridWorkspaceCollapsed(entity.id)
        VStack(alignment: .leading, spacing: 1) {
            workspaceGroupHeader(entity, isActiveHere: isActiveHere, isCollapsed: isCollapsed)
            if !isCollapsed {
                ForEach(Array(entity.slots.enumerated()), id: \.offset) { index, slot in
                    if let sessionID = slot,
                       let session = sessionsByID[sessionID] {
                        // Split EINMAL pro Parent (Muster ProjectChatGroup) —
                        // speist Chip UND Kinder-Aufteilung.
                        let children = subagentChildrenByParent[session.id] ?? []
                        let split = children.isEmpty ? nil : AgentSidebarModelBuilder.subagentChildSplit(
                            children: children,
                            erroredIDs: erroredSubagentIDs,
                            workingIDs: workingSubagentIDs,
                            unreadIDs: windowStore.unreadSubagentSessionIDs,
                            selectedID: selectedSessionID
                        )
                        workspaceRow(session, entity: entity, slotIndex: index, split: split)
                        if let split {
                            subagentChildrenRows(
                                parent: session,
                                children: children,
                                split: split,
                                extraLeadingInset: 10,
                                isFinishedExpanded: workspaceFinishedSubagentParentIDs.contains(session.id),
                                onToggleFinished: { toggleWorkspaceFinishedSubagents(session.id) }
                            )
                        }
                    }
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

    private func workspaceGroupHeader(
        _ entity: AgentGridWorkspace,
        isActiveHere: Bool,
        isCollapsed: Bool
    ) -> some View {
        HStack(spacing: 6) {
            // Chevron = NUR ein-/ausklappen (eigener Button — der Rest des
            // Headers öffnet das Grid; verschachtelte Buttons würden sich
            // die Klicks streitig machen).
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    windowStore.toggleGridWorkspaceCollapsed(entity.id)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? String(localized: "Show chats") : String(localized: "Hide chats"))
            .accessibilityLabel(isCollapsed
                ? String(localized: "Show chats of \(entity.name)")
                : String(localized: "Hide chats of \(entity.name)"))

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: entity.colorHex))
                    .frame(width: 15, height: 15)
                    .overlay {
                        Text(String(entity.name.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                Text(entity.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("\(entity.occupiedSessionIDs.count)/\(entity.capacity)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActiveHere ? AgentTheme.accent : AgentTheme.textTertiary)
                    .help("Open as grid")
            }
            .contentShape(Rectangle())
            .onTapGesture { activateWorkspaceFromSidebar(entity) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open workspace \(entity.name) as grid")
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
        .background(
            isActiveHere ? AgentTheme.accentTint : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 8)
        .help("Open workspace “\(entity.name)” as grid")
        .contextMenu { workspaceContextMenu(entity) }
        // Sidebar-Reorder: Gruppen-Header ziehen, auf einen anderen Header
        // fallen lassen = davor einsortieren (reorderGridWorkspaces kann
        // durch stale Drags nie Entities verlieren).
        .draggable(DraggableWorkspace(workspaceID: entity.id))
        .dropDestination(for: DraggableWorkspace.self) { items, _ in
            guard let dropped = items.first, dropped.workspaceID != entity.id else { return false }
            return reorderWorkspace(dropped.workspaceID, before: entity.id)
        }
        // Session-Drop AUCH am Header (Muster ProjectChatGroup: zwei typisierte
        // Ziele auf derselben View): Das Workspace-Reorder-Ziel oben maskiert
        // im Header-Bereich sonst den Session-Drop des Gruppen-Containers —
        // ein LEERER oder zugeklappter Workspace bestünde nur aus dem Header
        // und wäre als Drop-Anker komplett unreaktiv (Nutzerbefund 2026-08-08).
        .dropDestination(for: DraggableSession.self) { items, _ in
            guard let dropped = items.first else { return false }
            return handleGridGroupDrop(dropped, workspaceID: entity.id)
        }
    }

    private func workspaceRow(
        _ session: AgentChatSession,
        entity: AgentGridWorkspace,
        slotIndex: Int,
        split: SubagentChildSplit? = nil
    ) -> some View {
        let rowOrder = entity.occupiedSessionIDs
        // Workspace = Arbeitsset: Minus (beenden + aus dem Workspace nehmen)
        // statt X/Archivieren — Zuordnung wie überall über SidebarCloseAction.
        let closeAction = SidebarCloseAction.resolveForWorkspaceRow(session: session)
        return PinnedSessionRow(
            session: session,
            project: workspace.projects.first { $0.id == session.projectID },
            isSelected: selectedSessionID == session.id,
            isMultiSelected: multiSelection.contains(session.id),
            statusStore: runtimeStatusStore,
            isMissingTranscript: missingTranscriptIDs.contains(session.id),
            closeIcon: closeAction.icon,
            closeHelp: closeAction.help,
            slotBadge: "S\(slotIndex + 1)",
            runningChildCount: split?.workingCount ?? 0,
            erroredChildCount: split?.erroredCount ?? 0,
            unreadChildCount: split?.hiddenUnreadCount ?? 0,
            childCount: split?.totalCount ?? 0,
            isChildrenExpanded: windowStore.expandedSubagentParentIDs.contains(session.id),
            onToggleChildren: { windowStore.toggleSubagentChildren(session.id) },
            onSelect: {
                handleSidebarRowClick(session.id, order: rowOrder) {
                    // Quellenunabhängige Klickregel via Bridge: im sichtbaren
                    // Workspace → Pane-Fokus, sonst Einzelansicht.
                    selectedSessionID = session.id
                }
            },
            onClose: { requestEndSession([session], removingFrom: entity) }
        )
        .padding(.leading, 10)
        .contextMenu {
            // Vollmenü mit „Aus Workspace „X" entfernen" als Kopf; das
            // Mitgliedschaftsmenü kommt ohne Entfernen-Teil (Policy:
            // includesMembershipRemoval == false — Review-Finding doppelte
            // Einträge bleibt damit behoben).
            sessionContextMenu(session, context: .workspaceRow, removalWorkspace: entity)
        }
        // Sidebar-Quelle = Add/Place-Semantik: bewusst OHNE Slot-Herkunft
        // (die trägt nur der Pane-Header — sonst würde ein Row-Drag im
        // eigenen Grid als Move/Swap statt als Sidebar-Drop aufgelöst).
        .draggable(DraggableSession(
            sessionID: session.id,
            sourceProjectID: session.projectID,
            sourceWindowID: windowID
        )) {
            SessionDragPreview(title: session.title)
        }
    }

    // MARK: - Subagent-Kinder (geteilt — siehe +SubagentChildren)

    /// Stufe-2-Toggle der WORKSPACE-Sektion (Fertige hinter der Fußzeile) —
    /// eigener View-State pro Sektion, die Darstellung liefert die geteilte
    /// `subagentChildrenRows`-Komponente.
    func toggleWorkspaceFinishedSubagents(_ parentID: UUID) {
        if workspaceFinishedSubagentParentIDs.contains(parentID) {
            workspaceFinishedSubagentParentIDs.remove(parentID)
        } else {
            workspaceFinishedSubagentParentIDs.insert(parentID)
        }
    }

    @ViewBuilder
    private func workspaceContextMenu(_ entity: AgentGridWorkspace) -> some View {
        Button("Open as grid", systemImage: "square.grid.2x2") {
            activateWorkspaceFromSidebar(entity)
        }
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renameWorkspaceDraft = entity.name
            renameWorkspaceTargetID = entity.id
        }
        Menu {
            // Farbnamen + echte Farbswatches wie im Tab-/Projekt-Farbmenü
            // (vorher rohe Hex-Strings mit einheitlichem circle.fill).
            ForEach(AgentProjectColor.palette, id: \.self) { hex in
                Button {
                    windowStore.setGridWorkspaceColor(entity.id, colorHex: hex)
                } label: {
                    Label {
                        Text(hex == entity.colorHex
                            ? String(localized: "\(AgentChatColorName.label(for: hex)) (active)")
                            : AgentChatColorName.label(for: hex))
                    } icon: {
                        Image(nsImage: colorSwatchImage(hex: hex))
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            workspacePendingDeletion = entity
        }
    }

    // MARK: - Aktionen

    /// Header-/⊞-Klick: Workspace als Grid öffnen. Single-Owner-Konflikte
    /// werden als Werte gemeldet — kein stilles Stehlen.
    func activateWorkspaceFromSidebar(_ entity: AgentGridWorkspace) {
        let wasVisibleHere = isGridActive
            && windowStore.window(for: windowID).activeWorkspaceID == entity.id
        switch windowStore.activateGridWorkspace(entity.id, in: windowID) {
        case .activated, .alreadyActiveHere:
            // perf.grid: NACH der Aktivierung mit der ZIEL-Entity messen —
            // vorher stünden die IDs des alten Workspace in der Erwartung
            // (500-ms-Fake-Verletzungen; Review-Finding). Ein Klick auf den
            // bereits sichtbaren Workspace attached nichts → keine Messung.
            if !wasVisibleHere {
                beginGridBuildMeasurement(for: entity)
            }
            multiSelection = []
        case .alreadyActive(let owner):
            // Ein anderes Fenster besitzt den Workspace bereits — dieses
            // Fenster nach vorn holen statt Terminals zu stehlen.
            focusWindow(owner)
        case .blockedByWindowOwnership(let conflicts):
            errorMessage = String(localized: "Workspace “\(entity.name)” cannot open here: \(ChatsUIStrings.runningInOtherWindow(count: conflicts.count)).")
        case .rejected:
            break
        }
    }

    /// ＋ im Sektions-Header: leeren Workspace anlegen und sofort öffnen —
    /// die sichtbaren leeren Slots sind die Drop-Ziele fürs Befüllen.
    func createWorkspaceFromSidebar() {
        let name = nextFreeWorkspaceName()
        let id = windowStore.createGridWorkspace(name: name, activateIn: windowID)
        if let entity = windowStore.gridWorkspace(id: id) {
            beginGridBuildMeasurement(for: entity)
        }
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
            errorMessage = String(localized: "A workspace shows at most 9 chats — the first 9 of the selection were added, \(sessionIDs.count - 9) were not.")
        }
        let id = windowStore.createGridWorkspace(
            name: nextFreeWorkspaceName(),
            capacity: AgentGridWorkspace.smallestCapacity(fitting: accepted.count),
            slots: accepted.map { $0 },
            activateIn: windowID
        )
        // Messung mit der NEUEN Entity (nicht dem alten Workspace).
        if let entity = windowStore.gridWorkspace(id: id) {
            beginGridBuildMeasurement(for: entity)
        }
        multiSelection = []
    }

    /// ⊞ am Projekt-Header / Kontextmenü „Als Workspace öffnen": Projekt als
    /// LIVE-Grid seiner aktiven Chats öffnen. Kein sichtbares Workspace-
    /// Entity — der Store hält pro Projekt eine versteckte View (Layout-
    /// Gedächtnis), deren Mitglieder ausschließlich die Aktiv-Ableitung
    /// verwaltet (`syncActiveProjectGridWorkspaces` hält sie danach live).
    /// Single-Owner-Konflikte wie beim Workspace-Header: Besitzerfenster
    /// nach vorn statt Terminals zu stehlen.
    func openProjectAsWorkspace(_ project: AgentProject, activeSessionIDs: Set<UUID>) {
        // Leere Aktiv-Menge: nur der ERSTE Klick braucht Chats — existiert
        // die View schon, ist ⊞ der Rücksprung-Anker und muss auch ein
        // leeres Grid wieder anzeigen können.
        let existing = windowStore.gridWorkspaces.first { $0.sourceProjectID == project.id }
        guard !activeSessionIDs.isEmpty || existing != nil else { return }
        let wasVisibleHere = isGridActive
            && activeGridWorkspaceEntity?.sourceProjectID == project.id
        switch windowStore.activateProjectGridWorkspace(
            projectID: project.id,
            name: project.name,
            colorHex: project.color,
            activeSessionIDs: activeSessionIDs,
            in: windowID
        ) {
        case .activated, .alreadyActiveHere:
            if !wasVisibleHere, let entity = windowStore.gridWorkspaces.first(
                where: { $0.sourceProjectID == project.id }
            ) {
                beginGridBuildMeasurement(for: entity)
            }
            multiSelection = []
        case .alreadyActive(let owner):
            focusWindow(owner)
        case .blockedByWindowOwnership(let conflicts):
            errorMessage = String(localized: "“\(project.name)” cannot open as a workspace here: \(ChatsUIStrings.runningInOtherWindow(count: conflicts.count)).")
        case .rejected:
            break
        }
    }

    /// Kappungs-Anzeige „9/N" am Projekt-Header: nur wenn die OFFENE
    /// Projekt-View dieses Fensters weniger zeigt, als aktiv sind (Endstufe
    /// 3×3 erreicht) — sonst `nil` (Header zeigt die normale Chat-Zahl).
    func projectViewOccupancyLabel(for project: AgentProject, activeCount: Int) -> String? {
        guard isGridActive,
              let entity = activeGridWorkspaceEntity,
              entity.sourceProjectID == project.id else { return nil }
        let shown = entity.occupiedSessionIDs.count
        guard activeCount > shown else { return nil }
        return "\(shown)/\(activeCount)"
    }

    /// Kontextmenü-Eintrag (Tabs + Sidebar, count-abhängiges Label).
    @ViewBuilder
    func newWorkspaceFromSelectionButton(for session: AgentChatSession) -> some View {
        Button(
            bulkLabel(String(localized: "New workspace with this chat"), String(localized: "New workspace from %d chats"), for: session),
            systemImage: "plus.square.on.square"
        ) {
            createWorkspaceFromSelection(actionGroup(for: session))
        }
    }

    private func nextFreeWorkspaceName() -> String {
        // Nur kuratierte Namen zählen — ein Projekt namens „Workspace"
        // soll den ersten sichtbaren Workspace nicht auf „Workspace 2"
        // zwingen.
        let used = Set(
            windowStore.gridWorkspaces
                .filter { $0.sourceProjectID == nil }
                .map(\.name)
        )
        if !used.contains("Workspace") { return "Workspace" }
        var suffix = 2
        while used.contains("Workspace \(suffix)") { suffix += 1 }
        return "Workspace \(suffix)"
    }

    @discardableResult
    private func reorderWorkspace(_ movedID: UUID, before targetID: UUID) -> Bool {
        // Stale Payloads (Quelle/Ziel während des Drags gelöscht) ohne
        // Mutation ablehnen — der End-Fallback würde sonst unerwartet
        // umsortieren (Review-Finding).
        let current = windowStore.gridWorkspaces.map(\.id)
        guard current.contains(movedID), current.contains(targetID) else { return false }
        var order = current.filter { $0 != movedID }
        guard let insertAt = order.firstIndex(of: targetID) else { return false }
        order.insert(movedID, at: insertAt)
        windowStore.reorderGridWorkspaces(orderedIDs: order)
        return true
    }

    // MARK: - Umbenennen-Sheet

    var renameWorkspaceSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename workspace")
                .font(.system(size: 13, weight: .semibold))
            TextField("Name", text: $renameWorkspaceDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commitWorkspaceRename() }
            HStack {
                Spacer()
                Button("Cancel") { renameWorkspaceTargetID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commitWorkspaceRename() }
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
