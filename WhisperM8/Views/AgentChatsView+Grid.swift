import AppKit
import SwiftUI

/// Grid-Workspaces (docs/plans/grid-workspace-plan.html): Das Fenster
/// referenziert einen globalen `WorkspaceLayout` (`activeWorkspaceID`);
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
    var activeGridWorkspaceEntity: WorkspaceLayout? {
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
                            systemImage: entity.contains(session.id)
                                ? "checkmark" : "square.grid.2x2"
                        )
                    }
                    .disabled(entity.contains(session.id))
                }
            } label: {
                Label("Zu Workspace hinzufügen", systemImage: "square.grid.2x2")
            }

            // Entfernen ist workspace-bewusst: genau die gemeinte Gruppe.
            if includeRemoval {
                let containing = workspaces.filter { $0.contains(session.id) }
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
        let result = windowStore.returnToActiveGrid(in: windowID)
        // Messung erst NACH erfolgreicher Aktivierung — eine abgelehnte
        // Rückkehr liefe sonst in den 500-ms-Timeout (Fake-Verletzung).
        if case .alreadyActiveHere = result {
            beginGridBuildMeasurement()
        } else if case .activated = result {
            beginGridBuildMeasurement()
        }
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
    /// der Single-Owner-Politik) — reiner Fenster-Fokus über die
    /// Fenster-ID, OHNE die Ansicht des Besitzers zu mutieren; funktioniert
    /// auch für Fenster ohne Tabs (Review-Findings).
    func focusWindow(_ ownerWindowID: UUID) {
        WindowRequestCenter.shared.requestWindowFocus(windowID: ownerWindowID)
    }

    // MARK: - perf.grid

    /// perf.grid: Aufbau-Messung am ÜBERGANG starten (vor dem Mount — die
    /// Panes attachen während `makeNSView`, also bevor ein Parent-`onAppear`
    /// feuern würde). Erwartet werden nur Panes der ZIEL-Entity mit lebendem
    /// Controller; Offline-Panes rendern Transcript-Views und attachen nie.
    func beginGridBuildMeasurement(for entity: WorkspaceLayout? = nil) {
        let target = entity ?? activeGridWorkspaceEntity
        let expected = target?.occupiedSessionIDs
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

    /// Die Flaechen-Ansicht. Alles, was frueher an Slots hing — Kapazitaet,
    /// leere Plaetze, Growzone, Shrink-Auswahl — ist mit Schema v5 entfallen
    /// und nicht ersetzt worden.
    private func gridWorkspaceContent(entity: WorkspaceLayout) -> some View {
        // Snapshot GENAU EINMAL pro Body-Eval.
        let sessionsByID = Dictionary(
            workspace.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return WorkspaceLayoutView(
            layout: entity,
            focusedSessionID: selectedSessionID,
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
                _ = windowStore.applyDrop(sessionID, target: target, inGridWorkspace: entity.id)
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
                if let session = sessionsByID[sessionID] {
                    gridPane(for: session, workspaceID: entity.id, slotIndex: 0)
                } else {
                    Color.clear
                }
            }
        )
        .onChange(of: selectedSessionID) { _, selected in
            guard let selected else { return }
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


    // MARK: - Workspace-Header-Zeile (ersetzt den Chat-Header im Grid)

    /// Header-Zeile der Grid-Ansicht: Workspace-Identität links, Kapazitäts-
    /// Picker rechts. Ersetzt `activeChatStatusRow` — die Session-Infos
    /// stehen im Grid bereits an jeder Pane, und der Picker lag vorher als
    /// Overlay ÜBER der rechten oberen Pane (verdeckte deren Header).
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
            Text("\(entity.allSessions.count) Chats")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(AgentTheme.textTertiary)

            Spacer(minLength: 8)

            // Während der Auswahl übernimmt die Aktionsleiste den Platz des
            // Pickers — eine weitere Stufe zu wählen wäre mitten in der
        }
        // Gleiche Mindesthöhe wie der zweizeilige Chat-Header — der Wechsel
        // Grid ↔ Einzelansicht soll das Layout darunter nicht springen lassen.
        .frame(minHeight: 30)
    }

    // MARK: - Drop-Handling

    /// Ganze Sidebar-Gruppe in den Workspace ziehen. Ohne Kapazitaet gibt es
    /// keine Obergrenze mehr — jeder Chat wird eine Flaeche.
    @discardableResult
    func handleGridGroupDrop(_ payload: DraggableSession, workspaceID: UUID) -> Bool {
        var added = false
        for sessionID in payload.sessionIDs {
            if windowStore.addSession(sessionID, toGridWorkspace: workspaceID) == .added {
                added = true
            }
        }
        return added
    }


    // MARK: - Feed-Drosselung (F11)

    /// Hintergrund-Panes des sichtbaren Grids drosseln (~12,5 Hz), die
    /// Fokus-Pane verarbeitet sofort (Umschalten flusht FIFO-treu).
    /// DIFF-basiert über `throttledGridPaneIDs`: Sessions, die den Workspace
    /// verlassen (⊖, Ersetzen, Shrink, Workspace-Wechsel), werden explizit
    /// entdrosselt — sonst blieben sie dauerhaft gedrosselt, auch in der
    /// Einzelansicht (Review-Finding).
    func applyGridOutputPriorities(entity: WorkspaceLayout, focused: UUID?) {
        let shouldThrottle = Set(entity.occupiedSessionIDs.filter { $0 != focused })
        for sessionID in throttledGridPaneIDs.subtracting(shouldThrottle) {
            terminalRegistry.controller(for: sessionID)?.setOutputPriority(.focusedVisible)
        }
        for sessionID in shouldThrottle {
            terminalRegistry.controller(for: sessionID)?.setOutputPriority(.backgroundVisible)
        }
        throttledGridPaneIDs = shouldThrottle
    }

    /// Grid verschwindet (Einzelansicht, Fenster zu): ALLE gedrosselten
    /// Panes zurück auf sofortige Verarbeitung (Registry-basiert — nicht
    /// nur die aktuellen Entity-Slots).
    func resetGridOutputPriorities() {
        for sessionID in throttledGridPaneIDs {
            terminalRegistry.controller(for: sessionID)?.setOutputPriority(.focusedVisible)
        }
        throttledGridPaneIDs = []
    }

    /// Pane für einen Slot-Index — Session-Map kommt als Snapshot vom
    /// Aufrufer (genau eine Berechnung pro Body-Eval). Jeder Slot (belegt
    /// wie leer) ist ein gezieltes Drop-Ziel mit benannter Aktion.
    @ViewBuilder
    // MARK: - Eine Flaeche

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
        let isProcessRunning = terminalRegistry.controller(for: session.id)?.isRunning == true
        return HStack(spacing: 8) {
            SessionLiveStatusDot(
                sessionID: session.id,
                isProcessRunning: isProcessRunning,
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
            accountBadge(for: session)
            Spacer(minLength: 6)
            // Repo im Editor öffnen (PhpStorm etc.) — nutzt dasselbe
            // gemerkte Öffnen-Ziel wie der IDE-Opener im Chat-Header
            // (projectOpenTarget); der ist im Grid ausgeblendet.
            if let project {
                Button {
                    openProject(project, in: projectOpenTarget)
                } label: {
                    Image(systemName: projectOpenTarget.systemImage)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(project.name) in \(projectOpenTarget.label) öffnen")
                .accessibilityLabel("\(project.name) in \(projectOpenTarget.label) öffnen")
            }
            // Start/Resume/Restart direkt an der Pane — der Chat-Header (wo
            // die Aktion sonst sitzt) ist im Grid ausgeblendet. Gleicher
            // Pfad wie dort: sessionActionRequest, die Detail-View der Pane
            // filtert per Session-ID. Subagent-Jobs haben eigene Controls.
            if !session.isSubagentJob || jobRuntimeModel.isTakenOver(session.id) {
                Button {
                    sessionActionRequest = AgentSessionActionRequest(
                        sessionID: session.id,
                        kind: isProcessRunning ? .restart : .start
                    )
                } label: {
                    Image(systemName: isProcessRunning ? "arrow.clockwise" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isProcessRunning
                    ? "Restart — Terminal neu starten"
                    : (session.externalSessionID == nil ? "Start" : "Resume"))
                .accessibilityLabel(isProcessRunning
                    ? "\(session.title) neu starten"
                    : (session.externalSessionID == nil
                        ? "\(session.title) starten"
                        : "\(session.title) fortsetzen"))
            }
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
        // Vereinheitlichtes Session-Kontextmenü — bewusst am HEADER, nicht
        // am Terminal-Inhalt (dort gehört der Rechtsklick dem PTY). Die
        // Header-Buttons bleiben als Schnellzugriff unverändert.
        .contextMenu {
            sessionContextMenu(
                session,
                context: .gridPane,
                removalWorkspace: windowStore.gridWorkspace(id: workspaceID)
            )
        }
    }

    // MARK: - Selektion / Tastatur

    /// leftMouseDown-Hook (siehe Monitor in +Shortcuts): Klick in eine
    /// nicht-fokussierte Pane verschiebt die Selektion dorthin. Beobachtend —
    /// das Event läuft unverändert weiter ans Terminal.
    func handleGridPaneMouseDown(_ event: NSEvent) {
        // Im Auswahlmodus gehört der Klick der Markierung: der Monitor sieht
        // Events VOR der View-Zustellung und würde sonst nebenbei den
        // Pane-Fokus verschieben.
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
/// Fokus zur Nachbarflaeche. Ohne Raster gibt es keine Richtungen mehr —
    /// gewandert wird linear durch die sichtbaren Chats in Lesereihenfolge.
    func moveGridFocus(_ direction: GridFocusDirection) {
        guard let entity = activeGridWorkspaceEntity else { return }
        let sichtbar = entity.visibleSessions
        guard !sichtbar.isEmpty else { return }
        let aktuell = selectedSessionID.flatMap { sichtbar.firstIndex(of: $0) } ?? 0
        let schritt: Int
        switch direction {
        case .left, .up: schritt = -1
        case .right, .down: schritt = 1
        }
        let ziel = (aktuell + schritt + sichtbar.count) % sichtbar.count
        selectedSessionID = sichtbar[ziel]
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
                onPrepareLaunchSettings: { sessionID, contextProfile in
                    AgentSessionStatusCoordinator.shared.prepareLaunchSettings(
                        localSessionID: sessionID,
                        contextProfile: contextProfile
                    )
                },
                onClaudeHookLaunched: { sessionID in
                    AgentSessionStatusCoordinator.shared.hookLaunchDidStart(sessionID: sessionID)
                }
            )
        }
    }
}
