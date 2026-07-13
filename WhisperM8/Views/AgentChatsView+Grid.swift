import AppKit
import SwiftUI

/// Grid-Workspaces (docs/plans/grid-workspace-plan.html): Das Fenster
/// referenziert einen globalen `AgentGridWorkspace` (`activeWorkspaceID`);
/// `showsGrid` zeigt dessen SLOTS als bündige Panes — feste Positionen,
/// leere Slots bleiben sichtbar, nichts rückt nach, keine Verdrängungs-
/// Automatik. Layout aus der Kapazität (2 = 1×2 · 3 = 2+1 · 4 = 2×2),
/// Splits am Entity persistiert. Fokus-Pane = `selectedSessionID`
/// (2-px-Inset-Akzent); nur sie bekommt Auto-Launch/Auto-Fokus. Klick auf
/// einen Chat außerhalb des Workspace öffnet die Einzelansicht — „Zurück
/// zum Workspace ‹Name›" stellt das Grid exakt wieder her.
extension AgentChatsView {
    var showsGrid: Bool {
        get { windowStore.showsGrid(in: windowID) }
        nonmutating set { windowStore.setShowsGrid(newValue, in: windowID) }
    }

    /// Der Workspace, den dieses Fenster referenziert (Grid sichtbar ODER
    /// Rücksprungziel der Einzelansicht).
    var activeGridWorkspaceEntity: AgentGridWorkspace? {
        windowStore.activeGridWorkspace(in: windowID)
    }

    /// Grid nur mit gültiger Workspace-Referenz — auch ein leerer Workspace
    /// (0/N) zeigt sein Grid (sichtbare leere Slots sind die Drop-Ziele).
    var isGridActive: Bool { showsGrid && activeGridWorkspaceEntity != nil }

    // MARK: - Workspace-Mitgliedschaft (Kontextmenü / Drops)

    /// Nimmt einen Chat in einen Workspace auf (erster freier Slot bzw.
    /// Auto-Wachsen). Volle Endstufe/Konflikte meldet der Store als Wert —
    /// sichtbar über den Hinweis-Alert (Review-Finding: benannte
    /// Ablehnungen waren nur im Log).
    func addSessionToWorkspace(_ sessionID: UUID, workspaceID: UUID) {
        let result = windowStore.addSession(sessionID, toGridWorkspace: workspaceID)
        let name = windowStore.gridWorkspace(id: workspaceID)?.name ?? "Workspace"
        switch result {
        case .full:
            errorMessage = "„\(name)“ ist voll (3×3) — gezielt auf eine Pane ablegen, um zu ersetzen."
        case .rejected:
            errorMessage = "Der Chat kann nicht in „\(name)“ aufgenommen werden (archiviert oder als Tab in einem anderen Fenster)."
        default:
            break
        }
    }

    /// ⊖ im Pane-Header / Kontextmenü: leert NUR den Slot — Tab und Prozess
    /// bleiben, nichts rückt nach (Fokus-Fallback macht der Store).
    func removeSessionFromWorkspace(_ sessionID: UUID, workspaceID: UUID) {
        windowStore.removeSession(sessionID, fromGridWorkspace: workspaceID)
    }

    /// Workspace-bewusste Kontextmenü-Einträge (Tabs + Sidebar-Rows):
    /// „Zu Workspace hinzufügen →", präzises Platzieren ohne Drag
    /// („Im Workspace platzieren → Slot N") und Entfernen je Mitgliedschaft
    /// (bei Mehrfach-Mitgliedschaft als Untermenü je Workspace).
    /// `includeRemoval: false` für Kontexte, die den Entfernen-Eintrag der
    /// eigenen Gruppe schon selbst anbieten (Workspace-Rows).
    @ViewBuilder
    func workspaceMembershipMenu(
        for session: AgentChatSession,
        includeRemoval: Bool = true
    ) -> some View {
        let workspaces = windowStore.gridWorkspaces
        if !workspaces.isEmpty {
            Menu {
                ForEach(workspaces) { entity in
                    Button {
                        addSessionToWorkspace(session.id, workspaceID: entity.id)
                    } label: {
                        Label(
                            entity.name,
                            systemImage: entity.slotIndex(of: session.id) != nil
                                ? "checkmark" : "square.grid.2x2"
                        )
                    }
                    .disabled(entity.slotIndex(of: session.id) != nil)
                }
            } label: {
                Label("Zu Workspace hinzufügen", systemImage: "square.grid.2x2")
            }

            // Präziser Weg ohne Drag: gezielt in einen Slot des SICHTBAREN
            // Workspace platzieren (ersetzt/tauscht wie ein Slot-Drop).
            if isGridActive, let entity = activeGridWorkspaceEntity {
                Menu {
                    ForEach(0 ..< entity.capacity, id: \.self) { index in
                        Button {
                            _ = windowStore.addSession(
                                session.id, toGridWorkspace: entity.id, at: index
                            )
                        } label: {
                            Text(slotPlacementLabel(entity: entity, index: index))
                        }
                        .disabled(entity.slots[index] == session.id)
                    }
                } label: {
                    Label("Im Workspace platzieren", systemImage: "square.grid.3x3.topleft.filled")
                }
            }

            // Entfernen ist workspace-bewusst: genau die gemeinte Gruppe.
            if includeRemoval {
                let containing = workspaces.filter { $0.slotIndex(of: session.id) != nil }
                if containing.count == 1, let only = containing.first {
                    Button("Aus Workspace „\(only.name)“ entfernen", systemImage: "minus.circle") {
                        removeSessionFromWorkspace(session.id, workspaceID: only.id)
                    }
                } else if containing.count > 1 {
                    Menu {
                        ForEach(containing) { entity in
                            Button(entity.name) {
                                removeSessionFromWorkspace(session.id, workspaceID: entity.id)
                            }
                        }
                    } label: {
                        Label("Aus Workspace entfernen", systemImage: "minus.circle")
                    }
                }
            }
        }
    }

    private func slotPlacementLabel(entity: AgentGridWorkspace, index: Int) -> String {
        guard let occupantID = entity.slots[index] else { return "Slot \(index + 1) (frei)" }
        let occupantName = workspace.sessions.first { $0.id == occupantID }?.title ?? "belegt"
        return "Slot \(index + 1) — ersetzt „\(occupantName)“"
    }

    // MARK: - Maximize / Zurück zum Workspace

    /// Pane-Maximize: dieser Chat groß in der Einzelansicht — die
    /// Workspace-Referenz und die Slots bleiben unverändert.
    func maximizePane(_ sessionID: UUID) {
        windowStore.showSingleSession(sessionID, in: windowID)
        multiSelection = []
    }

    /// „Zurück zum Workspace ‹Name›" aus der Einzelansicht: stellt das Grid
    /// exakt wieder her (Slots + Fokus repariert der Store).
    func returnToWorkspace() {
        beginGridBuildMeasurement()
        let result = windowStore.returnToActiveGrid(in: windowID)
        switch result {
        case .alreadyActive(let owner):
            // Sollte für das eigene Rücksprungziel nie passieren — defensiv:
            // Besitzerfenster nach vorn.
            focusWindow(owner)
        case .blockedByWindowOwnership(let conflicts):
            errorMessage = "Zurück zum Workspace nicht möglich: \(conflicts.count) \(conflicts.count == 1 ? "Chat läuft" : "Chats laufen") als Tab in einem anderen Fenster."
        default:
            break
        }
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
    /// der Single-Owner-Politik) — über den Session-Fokus-Pfad des
    /// WindowRequestCenter (dasselbe Routing wie ein Notification-Klick).
    func focusWindow(_ ownerWindowID: UUID) {
        let owner = windowStore.window(for: ownerWindowID)
        guard let session = owner.selectedSessionID ?? owner.openTabIDs.first else { return }
        WindowRequestCenter.shared.requestSessionFocus(sessionID: session)
    }

    // MARK: - perf.grid

    /// perf.grid: Aufbau-Messung am ÜBERGANG starten (vor dem Mount — die
    /// Panes attachen während `makeNSView`, also bevor ein Parent-`onAppear`
    /// feuern würde). Erwartet werden nur Panes mit lebendem Controller;
    /// Offline-Panes rendern Transcript-Views und attachen nie.
    func beginGridBuildMeasurement() {
        let expected = activeGridWorkspaceEntity?.occupiedSessionIDs
            .filter { terminalRegistry.controller(for: $0) != nil } ?? []
        GridPerformanceTracker.shared.beginBuild(expectedPaneIDs: Set(expected))
    }

    // MARK: - Grid-Container (bündig, 1-px-Divider)

    @ViewBuilder
    var gridWorkspace: some View {
        if let entity = activeGridWorkspaceEntity {
            gridWorkspaceContent(entity: entity)
        } else {
            // Von mainWorkspace nie ohne Entity aufgerufen (isGridActive) —
            // defensiver Fallback.
            Color.clear
        }
    }

    private func gridWorkspaceContent(entity: AgentGridWorkspace) -> some View {
        // Snapshot GENAU EINMAL pro Body-Eval — die Pane-Closure des
        // Containers darf die Session-Map nicht pro Slot neu berechnen.
        let sessionsByID = Dictionary(
            workspace.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        return AgentGridSplitContainer(
            layout: AgentGridAutoLayout.forCapacity(entity.capacity),
            persistedColumnFractions: entity.columnFractions,
            persistedRowFractions: entity.rowFractions,
            commitColumnFractions: { fractions in
                windowStore.setGridColumnFractions(ofGridWorkspace: entity.id, fractions)
            },
            commitRowFractions: { fractions in
                windowStore.setGridRowFractions(ofGridWorkspace: entity.id, fractions)
            },
            onHandleHoverChanged: { hovering in
                // Griff-Hover unterdrückt das Pane-Klick-Routing — ein
                // Drag-Start soll nicht nebenbei die Selektion verschieben.
                if hovering { hoveredGridPaneID = nil }
            },
            pane: { index in gridSlot(index, entity: entity, sessionsByID: sessionsByID) }
        )
        // Der 1-px-„Gap" zwischen den Panes IST die Trennlinie — gleiche
        // Farbe wie die übrigen Chrome-Divider. Kein Außen-Padding, keine
        // Karten: die Panes nutzen die volle Fläche.
        .background(AgentTheme.border)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedSessionID) { _, selected in
            guard let selected else { return }
            // F11: alter Fokus wird Hintergrund (drosselt), neuer Fokus
            // flusht seinen Rückstand VOR dem Tastatur-Fokus.
            applyGridOutputPriorities(entity: entity, focused: selected)
            // Fokus-Wechsel remountet die Pane-DetailView NICHT (stabile
            // .id) — deren onAppear-Fokus feuert also nicht erneut. Die
            // Tastatur explizit in die neue Fokus-Pane geben, sonst folgt
            // nur der Akzent-Rahmen, das Tippen bliebe im alten Terminal.
            if let controller = terminalRegistry.controller(for: selected) {
                // perf.grid: Fokuswechsel nur messen, wenn ein Terminal
                // existiert — Offline-/Subagent-Panes würden zwangsläufig
                // in den Timeout laufen (Fake-Verletzungen). Ende in
                // focusTerminal nach erfolgreichem makeFirstResponder.
                GridPerformanceTracker.shared.beginFocusSwitch()
                controller.focusTerminal()
            }
        }
        // Slot-Änderungen (⊖, Drops, Kapazität) entfernen Panes ohne
        // onHover(false) — Flag räumen, sonst selektiert ein Klick ins
        // Leere eine unsichtbare Session.
        .onChange(of: entity.slots) { _, _ in
            hoveredGridPaneID = nil
            applyGridOutputPriorities(entity: entity, focused: selectedSessionID)
        }
        .onAppear {
            applyGridOutputPriorities(entity: entity, focused: selectedSessionID)
        }
        .onDisappear {
            hoveredGridPaneID = nil
            gridDropTargeted = false
            // Einzelansicht/Workspace-Wechsel: keine Pane darf gedrosselt
            // zurückbleiben (der Rückstand wird dabei geflusht).
            resetGridOutputPriorities(entity: entity)
        }
        // Growzone (F8): Drag über dem Grid + alle Slots belegt + nächste
        // Stufe existiert → Erweitern-Zone als eigener Bereich UNTER dem
        // Grid (safeAreaInset statt Overlay — sie darf die untersten Slots
        // nicht überdecken und deren gezieltes Ersetzen nicht abfangen).
        // Auf der Endstufe 3×3 erscheint sie NICHT (Gruppen-Drop wird
        // benannt abgelehnt; gezieltes Ersetzen bleibt).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if gridDropTargeted,
               entity.firstFreeSlotIndex == nil,
               let next = AgentGridWorkspace.nextCapacity(after: entity.capacity) {
                gridGrowZone(entity: entity, nextCapacity: next)
            }
        }
        .animation(.easeOut(duration: 0.12), value: gridDropTargeted)
        // Die Grid-Fläche selbst (Divider/Ränder) ist bewusst KEIN
        // Drop-Ziel (Plan-Abschnitt 03: Trennlinien bleiben Resize-Griffe) —
        // der Handler lehnt ab, `isTargeted` steuert nur die Growzone.
        // Aufnehmen läuft über die Slot-Zonen, die Growzone und die
        // Sidebar-Gruppen.
        .dropDestination(for: DraggableSession.self) { _, _ in
            false
        } isTargeted: { gridDropTargeted = $0 }
    }

    /// Erweitern-Zone: Drop wächst auf die nächste Stufe (der Store
    /// platziert in den ersten NEUEN Slot).
    private func gridGrowZone(entity: AgentGridWorkspace, nextCapacity: Int) -> some View {
        GridGrowDropZone(
            label: "＋ Hier ablegen — „\(entity.name)“ erweitert auf \(Self.capacityLabel(nextCapacity))",
            onDrop: { dropped in handleGridGroupDrop(dropped, workspaceID: entity.id) }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    static func capacityLabel(_ capacity: Int) -> String {
        switch capacity {
        case 2: return "1×2"
        case 3: return "2+1"
        case 4: return "2×2"
        case 6: return "3×2"
        case 9: return "3×3"
        default: return "\(capacity)"
        }
    }

    // MARK: - Drop-Handling

    /// Drop auf Gruppe/Growzone: aufnehmen (erster freier Slot, sonst
    /// Auto-Wachsen). Cross-Window-Drags holen den Tab explizit in dieses
    /// Fenster — aber erst NACH den mutationsfreien Pre-Checks, und ein
    /// dennoch abgelehnter Add rollt die Übernahme zurück (Review-Finding:
    /// kein halb ausgeführter Drop).
    @discardableResult
    func handleGridGroupDrop(_ payload: DraggableSession, workspaceID: UUID) -> Bool {
        guard let entity = windowStore.gridWorkspace(id: workspaceID) else { return false }
        if entity.slotIndex(of: payload.sessionID) != nil {
            return true // schon Mitglied — nichts zu tun, nichts zu übernehmen
        }
        if entity.firstFreeSlotIndex == nil,
           AgentGridWorkspace.nextCapacity(after: entity.capacity) == nil {
            errorMessage = "„\(entity.name)“ ist voll (3×3) — gezielt auf eine Pane ablegen, um zu ersetzen."
            return false
        }

        let adoptedFrom = adoptCrossWindowTabIfNeeded(payload)
        let result = windowStore.addSession(payload.sessionID, toGridWorkspace: workspaceID)
        switch result {
        case .added, .alreadyMember, .replaced, .swapped:
            return true
        case .full, .rejected:
            rollbackAdoption(payload.sessionID, to: adoptedFrom)
            if case .full = result {
                errorMessage = "„\(entity.name)“ ist voll (3×3) — gezielt auf eine Pane ablegen, um zu ersetzen."
            }
            return false
        }
    }

    /// Gezielter Slot-Drop (Pane oder leerer Slot) — Semantik über den
    /// puren `GridDropZoneResolver`, ausgeführt als EINE Store-Mutation
    /// gegen den FRISCH gelesenen Workspace (nie den Body-Snapshot).
    /// Die Übernahme eines Cross-Window-Tabs passiert erst nach der
    /// Auflösung; scheitert der Add danach, wird sie zurückgerollt.
    func handleGridSlotDrop(_ payload: DraggableSession, targetSlot: Int, workspaceID: UUID) -> Bool {
        guard let entity = windowStore.gridWorkspace(id: workspaceID) else { return false }
        switch GridDropZoneResolver.action(
            sessionID: payload.sessionID,
            sourceWorkspaceID: payload.sourceWorkspaceID,
            sourceSlotIndex: payload.sourceSlotIndex,
            targetSlot: targetSlot,
            workspace: entity
        ) {
        case .moveSlot(let from, let to):
            return windowStore.moveSlot(inGridWorkspace: workspaceID, from: from, to: to)
        case .swapSlots(let first, let second):
            return windowStore.swapSlots(inGridWorkspace: workspaceID, first, second)
        case .place:
            let adoptedFrom = adoptCrossWindowTabIfNeeded(payload)
            let result = windowStore.addSession(
                payload.sessionID, toGridWorkspace: workspaceID, at: targetSlot
            )
            switch result {
            case .rejected, .full:
                rollbackAdoption(payload.sessionID, to: adoptedFrom)
                return false
            default:
                return true
            }
        case .none:
            return false
        }
    }

    /// Cross-Window-Drag: Tab explizit in dieses Fenster übernehmen, damit
    /// der Store-Add nicht am Tab-Ownership-Konflikt scheitert. Deckt auch
    /// Payloads OHNE `sourceWindowID` ab (Projekt-Rows, ältere Builds) —
    /// maßgeblich ist, wo der Tab wirklich lebt. Liefert das Quellfenster
    /// für einen etwaigen Rollback.
    @discardableResult
    private func adoptCrossWindowTabIfNeeded(_ payload: DraggableSession) -> UUID? {
        guard let host = windowStore.windowID(containingTab: payload.sessionID),
              host != windowID else { return nil }
        windowStore.moveTab(payload.sessionID, from: host, to: windowID, before: nil)
        return host
    }

    /// Abgelehnter Drop nach einer Tab-Übernahme: Tab zurück ins
    /// Quellfenster (sofern es noch existiert — sonst bleibt er hier, das
    /// ist der kleinere Schaden gegenüber einem verlorenen Tab).
    private func rollbackAdoption(_ sessionID: UUID, to sourceWindowID: UUID?) {
        guard let sourceWindowID, windowStore.hasWindow(sourceWindowID) else { return }
        windowStore.moveTab(sessionID, from: windowID, to: sourceWindowID, before: nil)
    }

    // MARK: - Feed-Drosselung (F11)

    /// Hintergrund-Panes des sichtbaren Grids drosseln (~12,5 Hz), die
    /// Fokus-Pane verarbeitet sofort (Umschalten flusht FIFO-treu).
    func applyGridOutputPriorities(entity: AgentGridWorkspace, focused: UUID?) {
        for sessionID in entity.occupiedSessionIDs {
            terminalRegistry.controller(for: sessionID)?
                .setOutputPriority(sessionID == focused ? .focusedVisible : .backgroundVisible)
        }
    }

    /// Grid verschwindet (Einzelansicht, Workspace-Wechsel): alle Panes
    /// zurück auf sofortige Verarbeitung.
    func resetGridOutputPriorities(entity: AgentGridWorkspace) {
        for sessionID in entity.occupiedSessionIDs {
            terminalRegistry.controller(for: sessionID)?.setOutputPriority(.focusedVisible)
        }
    }

    /// Pane für einen Slot-Index — Session-Map kommt als Snapshot vom
    /// Aufrufer (genau eine Berechnung pro Body-Eval). Jeder Slot (belegt
    /// wie leer) ist ein gezieltes Drop-Ziel mit benannter Aktion.
    @ViewBuilder
    private func gridSlot(
        _ index: Int,
        entity: AgentGridWorkspace,
        sessionsByID: [UUID: AgentChatSession]
    ) -> some View {
        let occupied = entity.slots.indices.contains(index) ? entity.slots[index] : nil
        GridSlotDropArea(
            slotIndex: index,
            occupiedTitle: occupied.flatMap { sessionsByID[$0]?.title },
            onDrop: { payload in
                handleGridSlotDrop(payload, targetSlot: index, workspaceID: entity.id)
            }
        ) {
            if let sessionID = occupied, let session = sessionsByID[sessionID] {
                // RENDER-OWNERSHIP-Guard (Review-Blocker): eine Terminal-View
                // lebt nur in EINER Hierarchie. Die Pane rendert das Terminal
                // nur, wenn der Tab DIESEM Fenster gehört — sonst (Tab
                // geschlossen/abgewandert, egal über welchen Mutationspfad)
                // ein Platzhalter mit explizitem Übernahme-Angebot.
                if windowStore.windowID(containingTab: sessionID) == windowID {
                    gridPane(for: session, workspaceID: entity.id, slotIndex: index)
                } else {
                    gridOrphanSlot(session, entity: entity, slotIndex: index)
                }
            } else {
                gridEmptySlot(index)
            }
        }
    }

    /// Platzhalter für einen Slot, dessen Chat gerade KEIN Tab dieses
    /// Fensters ist (geschlossen oder in ein anderes Fenster gewandert) —
    /// die Mitgliedschaft bleibt, gerendert wird erst nach expliziter
    /// Übernahme (kein stilles Terminal-Stehlen).
    private func gridOrphanSlot(
        _ session: AgentChatSession,
        entity: AgentGridWorkspace,
        slotIndex: Int
    ) -> some View {
        let hostWindowID = windowStore.windowID(containingTab: session.id)
        return VStack(spacing: 6) {
            Text(session.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
                .lineLimit(1)
            Text(hostWindowID == nil
                ? "Tab wurde geschlossen"
                : "Läuft als Tab in einem anderen Fenster")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
            Button(hostWindowID == nil ? "Wieder öffnen" : "Hierher verschieben") {
                if let hostWindowID {
                    windowStore.moveTab(session.id, from: hostWindowID, to: windowID, before: nil)
                } else {
                    windowStore.openTab(session.id, in: windowID, select: false)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(hostWindowID == nil
                ? "Tab von \(session.title) wieder öffnen"
                : "\(session.title) in dieses Fenster verschieben")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
    }

    /// Sichtbar leerer Slot — stabile Position, Drop-Ziel (Paket 2e).
    private func gridEmptySlot(_ index: Int) -> some View {
        VStack(spacing: 3) {
            Text("Slot \(index + 1)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
            Text("Chat hier ablegen")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    AgentTheme.border,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AgentTheme.background)
    }

    private func gridPane(for session: AgentChatSession, workspaceID: UUID, slotIndex: Int) -> some View {
        let isFocused = session.id == selectedSession?.id
        let project = workspace.projects.first { $0.id == session.projectID }
        return VStack(spacing: 0) {
            gridPaneHeader(
                session, project: project, isFocused: isFocused,
                workspaceID: workspaceID, slotIndex: slotIndex
            )
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
                // INNEN-Padding wie die Einzelansicht (mainWorkspace) — die
                // Dichte-Vorgabe betrifft nur die Abstände ZWISCHEN den
                // Panes, nicht den Leseabstand des Terminal-Inhalts.
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
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

    private func gridPaneHeader(
        _ session: AgentChatSession,
        project: AgentProject?,
        isFocused: Bool,
        workspaceID: UUID,
        slotIndex: Int
    ) -> some View {
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
            .help("Diesen Chat maximieren („Zurück zum Workspace“ stellt das Grid wieder her)")
            .accessibilityLabel("\(session.title) maximieren")
            Button {
                removeSessionFromWorkspace(session.id, workspaceID: workspaceID)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Bewusst KEIN Tab-Schließen im Pane-Header — ⊖ leert nur den
            // Slot; Tabs schließt man in der Tab-Leiste (✕, ⌘W, Mittelklick).
            .help("Aus dem Workspace nehmen (Slot bleibt frei, Tab bleibt offen)")
            .accessibilityLabel("\(session.title) aus dem Workspace nehmen")
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
        // Drag-Quelle NUR der Pane-Header (F7) — mit voller Herkunft:
        // gleicher Workspace = tauschen/verschieben, anderes Ziel =
        // aufnehmen/platzieren.
        .draggable(DraggableSession(
            sessionID: session.id,
            sourceProjectID: session.projectID,
            sourceWindowID: windowID,
            sourceWorkspaceID: workspaceID,
            sourceSlotIndex: slotIndex
        ))
    }

    // MARK: - Selektion / Tastatur

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

    /// Tastatur-Fokuswechsel zwischen Panes (⌃⌘-Pfeile, siehe +Shortcuts):
    /// bewegt den Fokus GEOMETRISCH über das Slot-Raster (pure Logik im
    /// `GridFocusNavigator` — rechts/links bleiben in der Zeile, oben/unten
    /// folgen der Spalte, leere Slots werden in der Richtung übersprungen).
    func moveGridFocus(_ direction: GridFocusDirection) {
        guard isGridActive, let entity = activeGridWorkspaceEntity else { return }
        let currentIndex = selectedSessionID.flatMap { entity.slotIndex(of: $0) } ?? 0
        guard let targetIndex = GridFocusNavigator.target(
            from: currentIndex,
            direction: direction,
            layout: AgentGridAutoLayout.forCapacity(entity.capacity),
            occupied: entity.slots.map { $0 != nil }
        ), let target = entity.slots[targetIndex] else { return }
        selectedSessionID = target
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
