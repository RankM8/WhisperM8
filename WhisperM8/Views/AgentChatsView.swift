import AppKit
import SwiftUI

struct AgentChatsView: View {
    @State private var store = AgentSessionStore()
    @State private var workspace = AgentWorkspace.empty
    @State private var selectedProjectID: UUID?
    @State private var selectedSessionID: UUID?
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var isIndexingSessions = false
    @State private var indexRefreshTask: Task<Void, Never>?
    @State private var lastIndexStats: [AgentSessionIndexStats] = []
    @State private var sessionActionRequest: AgentSessionActionRequest?
    @StateObject private var terminalRegistry = AgentTerminalRegistry.shared
    /// Live-Status-Store für die Sidebar-Indikatoren. Wird vom
    /// `AgentSessionRuntimeWatcher` gepflegt, ephemeral (nicht persistiert).
    @StateObject private var runtimeStatusStore = AgentSessionRuntimeStatusStore()
    /// Lazy-init in `setupRuntimeServicesIfNeeded()`, weil beide Services Refs
    /// auf Store + Closures brauchen, die wir vor `body` nicht haben.
    @State private var runtimeWatcher: AgentSessionRuntimeWatcher?
    @State private var autoNamer: AgentSessionAutoNamer?
    /// Mirror der `autoNamer.inFlight`-Set — wird via NotificationCenter
    /// aktualisiert, damit SwiftUI Re-Renders triggert. Wir koennen das nicht
    /// ueber @Observable machen weil autoNamer lazy-init in einem optionalen
    /// State lebt.
    @State private var autoRenamingSessionIDs: Set<UUID> = []
    /// Hook-Bridge fuer Real-Time-Detection von SessionStart/SessionEnd via
    /// Claude-Code-Hooks. Event-driven via `DispatchSource` — 0% idle CPU.
    @State private var claudeHookBridge: ClaudeHookBridge?
    /// Pending ambiguous-rebind-Picker. `nil` solange keine
    /// Mehrdeutigkeit erkannt wurde.
    @State private var pendingAmbiguousRebind: AmbiguousRebindRequest?
    @SceneStorage("agentChatsInspectorVisible") private var isInspectorVisible = false
    @SceneStorage("agentChatsSidebarVisible") private var isSidebarVisible = true
    @State private var openTabIDs: Set<UUID> = []
    /// Pro-Projekt-Erinnerung welcher Tab zuletzt aktiv war. Wird beim
    /// Projekt-Switch konsultiert um auf den letzten Tab zu springen statt
    /// auf "den ersten verfuegbaren". Persistiert via AgentUIState.
    @State private var selectedSessionIDByProject: [UUID: UUID] = [:]
    /// `true` waehrend wir den UIState aus der Sidecar-Datei laden. Verhindert
    /// dass die initialen .onChange-Trigger waehrend des Loads zurueck-saven.
    @State private var isLoadingPersistedUIState = true
    /// Debounce-Timer fuer Save-Operationen — verhindert Write-Spam bei
    /// rapid tab-switches.
    @State private var uiStatePersistTask: Task<Void, Never>?
    @State private var renameTargetID: UUID?
    @State private var renameDraft: String = ""
    @State private var renameProjectTargetID: UUID?
    @State private var renameProjectDraft: String = ""
    /// Projekte, für die wir in dieser App-Session schon einen Auto-Icon-Lookup
    /// gestartet haben — verhindert wiederholte Filesystem-Scans bei jedem
    /// Workspace-Reload.
    @State private var iconLookupAttempted: Set<UUID> = []

    /// Wenn nicht-nil, zeigen wir das Background-Dispatch-Modal als Sheet.
    /// Bindet an ein Snapshot des aktuell selektierten Projekts, damit der
    /// User waehrend des Modals nicht aus Versehen das Projekt wechselt.
    @State private var pendingBackgroundDispatch: PendingBackgroundDispatch?
    /// Local-Session-ID einer Background-Session, die gerade noch spawned —
    /// die UI zeigt den Tab schon, aber `claude attach` startet erst nach
    /// dem Spawn-Callback. Verhindert dass der Detail-View sofort prepareCommand
    /// fuehrt (was ohne Short-ID failen wuerde).
    @State private var spawningBackgroundSessions: Set<UUID> = []
    /// Aktive Lifecycle-Aktionen (Logs/Stop/Respawn/Rm) — kennzeichnet die
    /// Session-ID waehrend des Subprocess-Aufrufs, damit das Context-Menu
    /// re-entrant-sicher ist.
    @State private var pendingLifecycleSessions: Set<UUID> = []
    /// Wenn nicht-nil, zeigen wir das Logs-Sheet fuer diese BG-Session.
    @State private var pendingBackgroundLogs: BackgroundLogsPresentation?
    /// `true` solange beim App-Start der Health-Check noch laeuft —
    /// verhindert mehrfache parallele Laeufe.
    @State private var hasRunStartupHealthCheck = false
    /// Session-IDs, fuer die wir ueber einen `Notification`-Hook ein
    /// "Needs Input"-Signal bekommen haben. Wird vom Notification-Listener
    /// gepflegt; die Sidebar pulst diese Sessions zusaetzlich zum
    /// regulaeren Runtime-Status.
    @State private var awaitingInputSessionIDs: Set<UUID> = []
    /// `true` solange das Sub-Agent-Library-Sheet sichtbar ist.
    @State private var subAgentLibrarySheet: SubAgentLibraryPresentation?
    /// Live-Tracker fuer die aktive Sub-Session innerhalb eines
    /// `.agentView`-TUI-Tabs. Polls `~/.claude/jobs/*/state.json` und meldet,
    /// wo der User gerade tippt / Claude gerade antwortet.
    @StateObject private var activeBackgroundTracker = ActiveBackgroundSessionTracker()

    private var selectedProject: AgentProject? {
        workspace.projects.first { $0.id == selectedProjectID } ?? workspace.projects.first
    }

    private var projectSessions: [AgentChatSession] {
        guard let selectedProject else { return [] }
        return sessions(for: selectedProject)
    }

    private var headerTabs: [AgentChatSession] {
        // projectSessions filtert bereits via openTabIDs/selectedSessionID —
        // headerTabs ist identisch.
        projectSessions
    }

    private var selectedSession: AgentChatSession? {
        projectSessions.first { $0.id == selectedSessionID } ?? projectSessions.first
    }

    private var manualProjects: [AgentProject] {
        AgentSessionStore.sortedProjects(
            workspace.projects.filter(\.isManuallyAdded)
        )
    }

    private var visibleProjects: [AgentProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return manualProjects }
        return manualProjects.filter { project in
            project.name.localizedCaseInsensitiveContains(query)
                || project.path.localizedCaseInsensitiveContains(query)
                || sessions(for: project).contains { session in
                    session.title.localizedCaseInsensitiveContains(query)
                        || session.provider.displayName.localizedCaseInsensitiveContains(query)
                        || (session.groupName?.localizedCaseInsensitiveContains(query) == true)
                }
        }
    }

    private var runningResourceDescriptors: [AgentResourceSessionDescriptor] {
        // Quelle: `workspace.sessions` ist `@State` — Updates triggern Re-Render der View
        // und damit Re-Berechnung dieser Property. `terminalRegistry.runningControllers`
        // hingegen tut das nicht zuverlässig, weil `controller.isRunning` ein innerer
        // ObservableObject-State ist und kein `@Published` auf der Registry selbst.
        workspace.sessions.compactMap { session in
            guard session.status == .running,
                  let project = workspace.projects.first(where: { $0.id == session.projectID })
            else {
                return nil
            }

            return AgentResourceSessionDescriptor(
                id: session.id,
                projectName: project.name,
                projectPath: project.path,
                title: session.title,
                provider: session.provider,
                rootProcessID: terminalRegistry.controller(for: session.id)?.processID
            )
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                hashboardSidebar
                    .frame(width: 276)
            }

            mainWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isInspectorVisible {
                Divider()

                ProjectDetailPanel(
                    project: selectedProject,
                    session: selectedSession,
                    sessions: projectSessions,
                    onRefresh: { AgentScanCoordinator.shared.requestScan(reason: .manual) },
                    onNewCodexChat: { createSession(provider: .codex) },
                    onNewClaudeChat: { createSession(provider: .claude) },
                    onOpenPHPStorm: openSelectedProjectInPHPStorm
                )
                .frame(width: 292)
            }
        }
        .frame(minWidth: 920, minHeight: 700)
        .background(AgentTheme.background)
        .background(AgentChatsWindowAccessor())
        .ignoresSafeArea(.all, edges: .top)
        .sheet(isPresented: Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )) {
            renameSheet
        }
        .sheet(isPresented: Binding(
            get: { renameProjectTargetID != nil },
            set: { if !$0 { renameProjectTargetID = nil } }
        )) {
            renameProjectSheet
        }
        .sheet(item: $pendingBackgroundDispatch) { pending in
            BackgroundDispatchModal(
                project: pending.project,
                availableSubAgents: pending.subAgents,
                onCancel: { pendingBackgroundDispatch = nil },
                onDispatch: { request in
                    pendingBackgroundDispatch = nil
                    Task { await dispatchBackgroundAgent(in: pending.project, request: request) }
                }
            )
        }
        .sheet(item: $pendingBackgroundLogs) { presentation in
            BackgroundAgentLogsSheet(
                presentation: presentation,
                onClose: { pendingBackgroundLogs = nil }
            )
        }
        .sheet(item: $subAgentLibrarySheet) { presentation in
            SubAgentLibrarySheet(
                presentation: presentation,
                onClose: { subAgentLibrarySheet = nil }
            )
        }
        .sheet(item: $pendingAmbiguousRebind) { request in
            AgentSessionAmbiguousRebindPicker(
                request: request,
                onChoice: { externalID in
                    applyAmbiguousRebindChoice(request: request, externalID: externalID)
                    pendingAmbiguousRebind = nil
                },
                onCancel: {
                    pendingAmbiguousRebind = nil
                }
            )
        }
        .onAppear {
            setupRuntimeServicesIfNeeded()
            loadWorkspaceFast()
            loadPersistedUIState()
            syncActiveAgentChat()
            attemptAutoDetectProjectIcons()
            runBackgroundAgentStartupHealthCheckIfNeeded()
            updateActiveBackgroundTrackerIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentChatsView.backgroundNeedsInputNotification)) { note in
            if let id = note.userInfo?["localID"] as? UUID {
                awaitingInputSessionIDs.insert(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentChatsView.backgroundNeedsInputClearedNotification)) { note in
            if let id = note.userInfo?["localID"] as? UUID {
                awaitingInputSessionIDs.remove(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentChatsView.ambiguousRebindNotification)) { note in
            guard let request = note.userInfo?["request"] as? AmbiguousRebindRequest else { return }
            // Wenn der User gerade nicht in diesem Tab ist, ueberspringen wir
            // den Picker und loggen es — die naechste UI-Interaktion kann
            // den Picker erneut triggern via Resume-Button.
            guard request.localSessionID == selectedSessionID else {
                Logger.claudeRecovery.info("recovery_picker_skipped reason=tab-not-selected localID=\(request.localSessionID.uuidString, privacy: .public)")
                return
            }
            pendingAmbiguousRebind = request
            Logger.claudeRecovery.info("recovery_picker_shown localID=\(request.localSessionID.uuidString, privacy: .public) candidates=\(request.candidates.count)")
        }
        .onChange(of: workspace.projects.map(\.id)) { _, _ in
            // Neue Projekte (z.B. nach Sessions-Scan) → ggf. Icon resolven.
            attemptAutoDetectProjectIcons()
        }
        .onDisappear {
            indexRefreshTask?.cancel()
            activeBackgroundTracker.stop()
            // Window zu → kein aktiver Chat mehr für Recording-Coordinator.
            AppState.shared.activeAgentChat = nil
        }
        .onChange(of: selectedSessionID) { _, newValue in
            syncActiveAgentChat()
            // Pro-Projekt-Erinnerung: damit beim naechsten Projekt-Wechsel
            // der zuletzt benutzte Tab zurueckgeholt wird.
            if let projectID = selectedProjectID, let sessionID = newValue {
                selectedSessionIDByProject[projectID] = sessionID
            }
            schedulePersistUIState()
            updateActiveBackgroundTrackerIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncActiveAgentChat()
            schedulePersistUIState()
        }
        .onChange(of: workspace) { _, _ in syncActiveAgentChat() }
        .onChange(of: openTabIDs) { _, _ in schedulePersistUIState() }
        .onChange(of: expandedProjectIDs) { _, _ in schedulePersistUIState() }
        .onReceive(NotificationCenter.default.publisher(for: AgentScanCoordinator.scanRunningChangedNotification)) { note in
            if let running = note.userInfo?["running"] as? Bool {
                isIndexingSessions = running
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentSessionAutoNamer.inFlightDidChangeNotification)) { _ in
            autoRenamingSessionIDs = autoNamer?.inFlight ?? []
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentScanCoordinator.scanDidCompleteNotification)) { _ in
            // Workspace neu laden — der Coordinator hat moeglicherweise neue
            // Sessions importiert oder Stale-Running-States gefixt.
            loadWorkspaceFast()
            attemptAutoDetectProjectIcons()
            // Auto-Rename fuer alle generisch-benannten Sessions anstossen.
            forceAutoNameUntitledSessions()
        }
    }

    // MARK: - UI-State Persistenz (Sidecar agent-ui-state.json)

    /// Laedt den persistierten UI-State und populiert die `@State`-Vars.
    /// Garbage-Collection laeuft im Store (entfernt stale UUIDs).
    /// First-Load-Migration ebenfalls im Store (populiert aus Workspace
    /// wenn die Sidecar-Datei fehlt).
    private func loadPersistedUIState() {
        let state = store.loadUIState()

        // Aggregierte Set aller offenen Tabs ueber alle Projekte.
        var aggregatedOpen: Set<UUID> = []
        for ids in state.openTabIDsByProject.values {
            aggregatedOpen.formUnion(ids)
        }
        openTabIDs = aggregatedOpen
        selectedSessionIDByProject = state.selectedSessionIDByProject
        expandedProjectIDs = Set(state.expandedProjectIDs)

        // Project-Level Selection — fallback wenn die persistierte ID nicht
        // mehr existiert.
        if let pid = state.selectedProjectID,
           workspace.projects.contains(where: { $0.id == pid }) {
            selectedProjectID = pid
        }

        // Session-Selection: zuerst project-spezifisch, dann global,
        // sonst lass loadWorkspaceFast den Default setzen.
        if let pid = selectedProjectID,
           let sid = state.selectedSessionIDByProject[pid],
           workspace.sessions.contains(where: { $0.id == sid }) {
            selectedSessionID = sid
        }

        isLoadingPersistedUIState = false
    }

    /// Schedules ein debounced Save (500 ms) damit rapid tab-switches keinen
    /// Write-Spam verursachen. Beim ersten Load wird kein Save ausgeloest.
    private func schedulePersistUIState() {
        guard !isLoadingPersistedUIState else { return }
        uiStatePersistTask?.cancel()
        let snapshot = currentUIStateSnapshot()
        let storeRef = store
        uiStatePersistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? storeRef.saveUIState(snapshot)
        }
    }

    /// Baut aus den aktuellen @State-Vars einen `AgentUIState`. Verteilt
    /// `openTabIDs` per Session-ProjektID auf die `openTabIDsByProject`-Map.
    private func currentUIStateSnapshot() -> AgentUIState {
        var byProject: [UUID: [UUID]] = [:]
        // sortierte Reihenfolge: sortIndex / lastActivityAt aus sortedSessions
        let openSessions = workspace.sessions.filter { openTabIDs.contains($0.id) }
        let sorted = AgentSessionStore.sortedSessions(openSessions)
        for session in sorted {
            byProject[session.projectID, default: []].append(session.id)
        }
        return AgentUIState(
            schemaVersion: 1,
            openTabIDsByProject: byProject,
            selectedSessionIDByProject: selectedSessionIDByProject,
            selectedProjectID: selectedProjectID,
            expandedProjectIDs: Array(expandedProjectIDs)
        )
    }

    /// Aktiviert den Tracker fuer "in TUI aktive Sub-Session" nur, wenn
    /// der gerade selektierte Tab ein `.agentView` ist. Sonst lassen wir
    /// das Polling schlafen, um keine Disk-I/O zu produzieren, wenn der
    /// User in einem normalen Chat ist.
    /// Verdrahtet ausserdem den Keystroke-Listener am TUI-Terminal: jeder
    /// Tastendruck triggert einen sofortigen `nudge()` am Tracker — so
    /// reagiert die "letzte Aktivitaet"-Anzeige sub-Sekunden-schnell beim
    /// Navigieren, statt aufs 5-Sekunden-Polling zu warten.
    private func updateActiveBackgroundTrackerIfNeeded() {
        // Vorigen Listener (falls vom letzten Tab da) abhaengen.
        for controller in terminalRegistry.runningControllers {
            controller.setUserKeystrokeListener(nil)
        }

        guard selectedSession?.isAgentView == true else {
            activeBackgroundTracker.stop()
            return
        }
        activeBackgroundTracker.start()

        // Neuen Listener nur am Controller der aktuell selektierten .agentView-
        // Session anhaengen — andere Controller bleiben unangetastet.
        if let session = selectedSession,
           let controller = terminalRegistry.controller(for: session.id) {
            controller.setUserKeystrokeListener { [weak activeBackgroundTracker] in
                activeBackgroundTracker?.nudge()
            }
        }
    }

    /// Spiegelt die aktuelle Selection (Session + Projekt) in `AppState.activeAgentChat`.
    /// Wird beim Recording-Start vom Coordinator gelesen und ins Context-Bundle übernommen.
    private func syncActiveAgentChat() {
        guard let project = selectedProject,
              let session = selectedSession,
              session.status != .archived
        else {
            if AppState.shared.activeAgentChat != nil {
                AppState.shared.activeAgentChat = nil
            }
            return
        }

        let ref = AgentChatContextRef(
            sessionID: session.id,
            provider: session.provider,
            projectName: project.name,
            projectPath: project.path,
            title: session.title,
            externalSessionID: session.externalSessionID,
            kind: session.effectiveKind,
            backgroundShortID: session.backgroundShortID
        )
        if AppState.shared.activeAgentChat != ref {
            AppState.shared.activeAgentChat = ref
        }
    }

    private var renameSheet: some View {
        let originalTitle = renameTargetID
            .flatMap { id in workspace.sessions.first(where: { $0.id == id })?.title }
            ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            Text("Chat umbenennen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)

            TextField("Tab-Name", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
                .onSubmit { commitRename() }

            HStack {
                Spacer()
                Button("Abbrechen") { renameTargetID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || renameDraft == originalTitle
                    )
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(AgentTheme.panel)
    }

    private func commitRename() {
        guard let id = renameTargetID else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        renameSession(id: id, title: trimmed)
        renameTargetID = nil
    }

    private var renameProjectSheet: some View {
        let originalName = renameProjectTargetID
            .flatMap { id in workspace.projects.first(where: { $0.id == id })?.name }
            ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            Text("Projekt umbenennen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)

            TextField("Projekt-Name", text: $renameProjectDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
                .onSubmit { commitProjectRename() }

            HStack {
                Spacer()
                Button("Abbrechen") { renameProjectTargetID = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { commitProjectRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        renameProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || renameProjectDraft == originalName
                    )
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(AgentTheme.panel)
    }

    private func commitProjectRename() {
        guard let id = renameProjectTargetID else { return }
        let trimmed = renameProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        renameProject(id: id, name: trimmed)
        renameProjectTargetID = nil
    }

    private var hashboardSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Reservierter Bereich für die macOS-Window-Controls (rot/gelb/grün
                // floaten transparent über der Sidebar bei x ≈ 8–78).
                Spacer().frame(width: 70)
                Spacer(minLength: 4)
                AgentResourceSummaryButton(descriptors: runningResourceDescriptors)
            }
            .padding(.trailing, 8)
            .frame(height: 28)

            if isIndexingSessions {
                Label("Sessions werden gescannt", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    sidebarCommandRows
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)

                    if visibleProjects.isEmpty && searchText.isEmpty {
                        sidebarEmptyState
                    }

                    ForEach(visibleProjects) { project in
                        ProjectChatGroup(
                            project: project,
                            sessions: sessions(for: project),
                            isExpanded: expandedProjectIDs.contains(project.id) || !searchText.isEmpty,
                            selectedProjectID: selectedProjectID,
                            selectedSessionID: selectedSessionID,
                            onSelectProject: {
                                selectProject(project.id)
                            },
                            onToggleExpanded: {
                                toggleProject(project.id)
                            },
                            onSelectSession: { sessionID in
                                selectedProjectID = project.id
                                expandedProjectIDs.insert(project.id)
                                selectedSessionID = sessionID
                                openTabIDs.insert(sessionID)
                                AppPreferences.shared.agentDefaultProjectPath = project.path
                            },
                            onNewChat: {
                                selectedProjectID = project.id
                                expandedProjectIDs.insert(project.id)
                                createDefaultSession()
                            },
                            onCloseSession: { closeHeaderTab($0) },
                            onRenameRequest: { beginRename($0) },
                            onAutoNameRequest: { forceAutoNameSession($0) },
                            onRename: renameSession,
                            onSetColor: setSessionColor,
                            isRunning: { id in terminalRegistry.controller(for: id)?.isRunning == true },
                            runtimeStatus: { id in
                                // "Needs input" aus Notification-Hooks
                                // ueberlagert den Runtime-Watcher-Status —
                                // gerade bei Background-Sessions ist die
                                // JSONL nicht immer aussagekraeftig.
                                if awaitingInputSessionIDs.contains(id) {
                                    return .awaitingInput
                                }
                                return runtimeStatusStore.statuses[id]
                            },
                            isAutoRenaming: { id in autoRenamingSessionIDs.contains(id) },
                            onRenameProjectRequest: { beginRenameProject($0) },
                            onSetProjectColor: setProjectColor,
                            onChooseProjectIcon: { chooseProjectIcon($0) },
                            onAutoDetectProjectIcon: { reAutoDetectProjectIcon($0) },
                            onClearProjectIcon: { clearProjectIcon($0) },
                            onSessionDrop: { dropped, beforeID, targetProjectID in
                                dropSession(dropped, in: targetProjectID, beforeSessionID: beforeID)
                            },
                            onProjectDrop: { dropped, beforeID in
                                dropProject(dropped, beforeProjectID: beforeID)
                            }
                        )
                    }
                }
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)

            sidebarFooter
        }
        .background(AgentTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AgentTheme.border)
                .frame(width: 1)
        }
    }

    private var sidebarEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noch keine Projekte")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
            Text("Füge ein Projekt hinzu, um Codex- oder Claude-Chats darin anzulegen.")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                addProject()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Projekt hinzufügen")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(AgentTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 4) {
            Button {
                WindowRequestCenter.shared.request(.settings)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(AgentTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowButtonStyle())
            .help("Einstellungen öffnen")

            Button {
                WindowRequestCenter.shared.request(.onboarding)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Onboarding / Hilfe öffnen")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AgentTheme.border)
                .frame(height: 1)
        }
    }

    private var defaultAgentProvider: AgentProvider {
        AppPreferences.shared.defaultAgentLaunchTarget.provider
    }

    private var defaultAgentKind: AgentSessionKind? {
        AppPreferences.shared.defaultAgentLaunchTarget.kind
    }

    private func createDefaultSession() {
        let target = AppPreferences.shared.defaultAgentLaunchTarget
        createSession(provider: target.provider, kind: target.kind)
    }

    private var sidebarCommandRows: some View {
        VStack(spacing: 1) {
            Button {
                createDefaultSession()
            } label: {
                SidebarCommandRow(icon: "square.stack.3d.up", title: "Neuer Chat", isActive: selectedProject != nil)
            }
            .buttonStyle(SidebarRowButtonStyle())
            .disabled(selectedProject == nil)
            .help("Neuen Codex Chat im aktuellen Projekt starten")

            Button {
                AgentScanCoordinator.shared.requestScan(reason: .manual)
            } label: {
                SidebarCommandRow(icon: "arrow.clockwise", title: "Aktualisieren")
            }
            .buttonStyle(SidebarRowButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .help("Sessions neu einlesen (⌘R)")

            Button {
                addProject()
            } label: {
                SidebarCommandRow(icon: "plus", title: "Projekt hinzufügen", trailingIcon: "folder.badge.plus")
            }
            .buttonStyle(SidebarRowButtonStyle())
            .help("Ordner als Projekt hinzufügen")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                TextField("Filter…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AgentTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }

    private var mainWorkspace: some View {
        VStack(spacing: 0) {
            projectChatStrip

            if let selectedProject, let selectedSession {
                AgentSessionDetailView(
                    project: selectedProject,
                    session: selectedSession,
                    terminalRegistry: terminalRegistry,
                    actionRequest: sessionActionRequest,
                    onStateChanged: loadWorkspaceFast,
                    onSessionLaunched: { sessionID in
                        attachWatcher(sessionID: sessionID)
                    },
                    onSessionTerminated: { sessionID, exitCode in
                        runtimeWatcher?.markTerminated(sessionID: sessionID, exitCode: exitCode)
                        claudeHookBridge?.stopTracking(localSessionID: sessionID)
                    },
                    onExternalSessionIDBound: { sessionID in
                        attachWatcher(sessionID: sessionID)
                    },
                    onPrepareClaudeHookArguments: { sessionID in
                        claudeHookBridge?.prepareLaunch(localSessionID: sessionID) ?? []
                    },
                    onClaudeHookLaunched: { sessionID in
                        claudeHookBridge?.startTracking(localSessionID: sessionID)
                    }
                )
                .id(selectedSession.id)
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .background(AgentTheme.background)
            } else {
                ContentUnavailableView("Kein Agent Chat", systemImage: "terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentTheme.background)
    }

    private var projectChatStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !isSidebarVisible {
                    Spacer().frame(width: 70)
                }

                TitlebarIconButton(systemImage: "sidebar.left", help: isSidebarVisible ? "Sidebar ausblenden" : "Sidebar einblenden", isActive: isSidebarVisible) {
                    isSidebarVisible.toggle()
                }

                Text("Chat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.leading, 2)

                if !headerTabs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(headerTabs) { session in
                                ChatTabButton(
                                    session: session,
                                    isSelected: session.id == selectedSession?.id,
                                    onSelect: {
                                        openTabIDs.insert(session.id)
                                        selectedSessionID = session.id
                                    },
                                    onClose: {
                                        closeHeaderTab(session)
                                    }
                                )
                                .draggable(DraggableSession(sessionID: session.id, sourceProjectID: session.projectID))
                                .dropDestination(for: DraggableSession.self) { items, _ in
                                    guard let dropped = items.first else { return false }
                                    dropSession(dropped, in: session.projectID, beforeSessionID: session.id)
                                    return true
                                }
                                .contextMenu {
                                    sessionManagementMenu(session)
                                }
                            }
                        }
                    }
                }

                Menu {
                    Button("Neuer Codex Chat") { createSession(provider: .codex) }
                    Button("Neuer Claude Chat") { createSession(provider: .claude) }
                    Divider()
                    Button("Neuer Hintergrund-Agent…") { presentBackgroundDispatchModal() }
                        .disabled(selectedProject == nil)
                    Divider()
                    Button("Neuer Claude Agent View") {
                        createSession(provider: .claude, kind: .agentView)
                    }
                    Divider()
                    Button("Sub-Agent-Bibliothek anzeigen…") { presentSubAgentLibrary() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(AgentTheme.control.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentTheme.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(selectedProject == nil)
                .help("Neuen Chat anlegen")

                Spacer(minLength: 8)

                // Branch-Badge entfernt — die Branch steht ohnehin schon in
                // der Sidebar-Projekt-Zeile und im Project-Inspector, und
                // visueller Clutter im Titlebar-Bereich kostet mehr als er
                // hier liefert.

                TitlebarIconButton(systemImage: "sidebar.right", help: isInspectorVisible ? "Projekt-Kontext ausblenden" : "Projekt-Kontext anzeigen", isActive: isInspectorVisible) {
                    isInspectorVisible.toggle()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            HStack(spacing: 12) {
                Button {
                    isInspectorVisible.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Session-Einstellungen")

                ProviderTab(provider: .claude, isActive: selectedSession?.provider == .claude) {
                    switchSelectedProvider(to: .claude)
                }
                ProviderTab(provider: .codex, isActive: selectedSession?.provider == .codex) {
                    switchSelectedProvider(to: .codex)
                }

                if let selectedSession {
                    selectedSessionHeaderControls(selectedSession)
                }

                Spacer()

                if selectedProject != nil {
                    Button {
                        openSelectedProjectInPHPStorm()
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("PHPStorm öffnen")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)

            activeChatStatusRow
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AgentTheme.border)
                        .frame(height: 1)
                }
        }
        .background(AgentTheme.header)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AgentTheme.border)
                .frame(height: 1)
        }
    }

    /// Prominenter „in welchem Chat / welchem Repo bin ich"-Header — dritte
    /// Header-Zeile ueber dem PTY. Zeigt:
    /// - Session-Title (semibold) + Sub-Kind-Indikator (BG / VIEW)
    /// - Projekt-Name + Branch (kleiner, monospaced)
    /// - Bei `.agentView`-Tabs zusaetzlich: aktive Sub-Session innerhalb
    ///   der TUI, live-getrackt ueber `~/.claude/jobs/*/state.json`
    /// - Runtime-Info (Provider · Modell · Status) ganz rechts
    @ViewBuilder
    private var activeChatStatusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            statusDot

            VStack(alignment: .leading, spacing: 2) {
                primaryTitleRow
                secondaryProjectRow
                if selectedSession?.isAgentView == true {
                    tuiActiveSubSessionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let selectedSession {
                Text(selectedSession.runtimeDisplayText)
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Live-Anzeige der Sub-Session, in der zuletzt Aktivitaet passierte —
    /// nur sichtbar wenn der aktive Tab eine `.agentView`-TUI ist.
    /// Quelle: `ActiveBackgroundSessionTracker` (5s-Polling +
    /// Keystroke-Nudge). Wir labeln das explizit als "letzte Aktivitaet"
    /// und zeigen die relative Zeit dazu — denn wir koennen nicht
    /// erkennen, welche Row die TUI gerade selektiert hat, sondern nur,
    /// in welcher Session sich zuletzt etwas geschrieben hat.
    @ViewBuilder
    private var tuiActiveSubSessionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9))
                .foregroundStyle(.orange.opacity(0.8))
            if let active = activeBackgroundTracker.currentSession {
                Text("letzte Aktivität:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(active.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(active.projectDisplayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(active.shortID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                if let stateLabel = active.state, !stateLabel.isEmpty {
                    kindBadge(stateLabel.uppercased(), color: stateColor(for: stateLabel))
                }
                // Relative-Zeit-Anzeige fuer "vor wie lange". Bindet auf
                // `currentTimeForRelativeLabels`, damit der Text sich pro
                // Sekunde aktualisiert ohne den Tracker neu zu pollen.
                Text("· vor \(relativeDurationLabel(from: active.lastActivityAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .help("Zeitpunkt der letzten Schreibaktivität in der JSONL dieser Session. Reine TUI-Navigation ohne Schreiben ist nicht detektierbar.")
            } else {
                Text("letzte Aktivität: — keine Schreibaktivität im JSONL-Pool")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .help("Sub-Sessions werden hier sichtbar, sobald Claude in deren JSONL schreibt oder du in der TUI eine Taste drückst. Reines Mit-den-Pfeiltasten-Navigieren reicht nicht — WhisperM8 hat keinen Direktzugriff auf den TUI-internen Fokus.")
            }
        }
    }

    /// Liefert "12s", "3m", "1h 4m" — kurze Beschriftung der Differenz
    /// zwischen `date` und jetzt. Pure-Funktion fuer einfache Testbarkeit.
    private func relativeDurationLabel(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 1 { return "gerade eben" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes - hours * 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    /// Hex-Farbe fuer den State-Indikator pro TUI-State.
    private func stateColor(for state: String) -> Color {
        switch state.lowercased() {
        case "working", "running":
            return .green
        case "blocked", "needs_input", "awaiting":
            return .orange
        case "done", "completed", "succeeded":
            return AgentTheme.textTertiary
        case "errored", "failed":
            return .red
        default:
            return AgentTheme.textSecondary
        }
    }

    /// Klein-aber-prominenter Status-Dot links: gruen wenn das PTY laeuft,
    /// orange bei Needs-Input (Hook-Bridge), grau wenn keine Session da.
    @ViewBuilder
    private var statusDot: some View {
        if let selectedSession {
            let running = terminalRegistry.controller(for: selectedSession.id)?.isRunning == true
            let needsInput = awaitingInputSessionIDs.contains(selectedSession.id)
            let color: Color = {
                if needsInput { return .orange }
                if running { return .green }
                return AgentTheme.textTertiary
            }()
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(AgentTheme.textTertiary.opacity(0.4))
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var primaryTitleRow: some View {
        HStack(spacing: 6) {
            if let selectedSession {
                Text(selectedSession.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if selectedSession.isBackgroundChat {
                    kindBadge("BG", color: .indigo)
                        .help("Hintergrund-Agent · vom Claude-Supervisor gehostet")
                    if let shortID = selectedSession.backgroundShortID, !shortID.isEmpty {
                        Text(shortID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .help("Background-Agent Short-ID")
                    }
                } else if selectedSession.isAgentView {
                    kindBadge("VIEW", color: .orange)
                        .help("Claude Agents View · Multi-Session-Dashboard. Der aktive Sub-Chat innerhalb der TUI ist von WhisperM8 aus nicht erkennbar.")
                }
            } else if let selectedProject {
                Text(selectedProject.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
            } else {
                Text("Kein Chat ausgewählt")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var secondaryProjectRow: some View {
        if let project = selectedProject {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(project.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                if let branch = project.lastBranch, !branch.isEmpty {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(AgentTheme.textTertiary)
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .lineLimit(1)
                }
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(project.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.path)
            }
        } else {
            Color.clear.frame(height: 12)
        }
    }

    @ViewBuilder
    private func kindBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.04)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.30), lineWidth: 0.5)
            )
            .fixedSize()
    }

    private func selectedSessionHeaderControls(_ session: AgentChatSession) -> some View {
        let controller = terminalRegistry.controller(for: session.id)
        let isRunning = controller?.isRunning == true

        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isRunning ? AgentTheme.textSecondary : AgentTheme.textTertiary)
                    .frame(width: 5, height: 5)
                Text(session.runtimeDisplayText)
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            Button {
                sessionActionRequest = AgentSessionActionRequest(
                    sessionID: session.id,
                    kind: isRunning ? .restart : .start
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isRunning ? "arrow.clockwise" : "play.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text(isRunning ? "Restart" : (session.externalSessionID == nil ? "Start" : "Resume"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(AgentTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(AgentTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Menu {
                Button(isRunning ? "Restart" : (session.externalSessionID == nil ? "Start Terminal" : "Resume Terminal"), systemImage: isRunning ? "arrow.clockwise" : "play.fill") {
                    sessionActionRequest = AgentSessionActionRequest(
                        sessionID: session.id,
                        kind: isRunning ? .restart : .start
                    )
                }
                Button("Umbenennen…", systemImage: "pencil") {
                    beginRename(session)
                }
                Button("Titel automatisch generieren", systemImage: "sparkles") {
                    forceAutoNameSession(session)
                }
                .disabled(session.externalSessionID == nil)
                Divider()
                Menu("Tab-Farbe") {
                    ForEach(AgentChatColor.palette, id: \.self) { color in
                        Button {
                            setSessionColor(id: session.id, color: color)
                        } label: {
                            Label {
                                Text(AgentChatColorName.label(for: color))
                            } icon: {
                                Image(nsImage: colorSwatchImage(hex: color))
                            }
                        }
                    }
                    Divider()
                    Button("Provider-Farbe verwenden", systemImage: "arrow.uturn.backward") {
                        setSessionColor(id: session.id, color: nil)
                    }
                }
                Divider()
                Button("Schließen", systemImage: "xmark", role: .destructive) {
                    closeHeaderTab(session)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Chat-Aktionen")
        }
    }

    private func refresh() {
        loadWorkspaceFast()
        AgentScanCoordinator.shared.requestScan(reason: .manual)
    }

    /// Lazy-init der Runtime-Services. Wird einmal beim ersten `onAppear`
    /// aufgerufen — verträgt aber Re-Calls, weil sie sich mit `nil`-Check
    /// schützen. Wir können das nicht im `init()` machen, weil
    /// `runtimeStatusStore` ein `@StateObject` ist und vor `body` noch nicht
    /// instanziiert ist.
    private func setupRuntimeServicesIfNeeded() {
        if autoNamer == nil {
            autoNamer = AgentSessionAutoNamer(store: store)
        }
        if runtimeWatcher == nil {
            let store = self.store
            let statusStore = runtimeStatusStore
            let watcher = AgentSessionRuntimeWatcher(statusStore: statusStore) { [weak autoNamer] sessionID in
                AgentChatsView.handleTurnFinished(
                    sessionID: sessionID,
                    store: store,
                    autoNamer: autoNamer
                ) {
                    // Wir können hier kein `self` capturen (wäre stale beim
                    // mehrfachen Watcher-Init); der Workspace-Reload passiert
                    // beim nächsten `loadWorkspaceFast`-Tick (Indexer-Refresh
                    // bzw. UI-Reload).
                }
            }
            runtimeWatcher = watcher
        }
        if claudeHookBridge == nil {
            let store = self.store
            let registry = terminalRegistry
            let bridge = ClaudeHookBridge()
            bridge.setDecisionHandler { localID, event in
                AgentChatsView.handleClaudeHookEvent(
                    localID: localID,
                    event: event,
                    store: store,
                    terminalRegistry: registry
                )
            }
            claudeHookBridge = bridge
        }
    }

    /// Notification fuer den ambiguous-rebind-Picker (Phase 6).
    static let ambiguousRebindNotification = Notification.Name("AgentChatsView.ambiguousRebind")
    /// Wird vom Hook-Bridge-Handler bei `Notification`-Events gepostet —
    /// die View fuegt die `localID` aus `userInfo["localID"]` in
    /// `awaitingInputSessionIDs` ein.
    static let backgroundNeedsInputNotification = Notification.Name("AgentChatsView.backgroundNeedsInput")
    /// Pendant zum oberen — entfernt die localID wieder (z. B. nach
    /// `.preToolUse` oder `.sessionEnd`).
    static let backgroundNeedsInputClearedNotification = Notification.Name("AgentChatsView.backgroundNeedsInputCleared")

    /// Verarbeitet die User-Wahl im Ambiguous-Picker. `externalID == nil`
    /// bedeutet "Neue Session starten" — wir nullen die externe ID und
    /// markieren die Session als nicht gelauncht, damit der naechste
    /// Resume-Klick einen frischen Claude-Lauf startet.
    private func applyAmbiguousRebindChoice(request: AmbiguousRebindRequest, externalID: String?) {
        do {
            try store.updateSession(id: request.localSessionID) { session in
                let old = session.externalSessionID
                session.externalSessionID = externalID
                if externalID == nil {
                    session.hasLaunchedInitialPrompt = false
                }
                Logger.claudeRecovery.info("recovery_user_chose localID=\(request.localSessionID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(externalID ?? "nil", privacy: .public)")
            }
            Task { @MainActor in
                terminalRegistry.controller(for: request.localSessionID)?
                    .updateExternalSessionID(externalID)
            }
            loadWorkspaceFast()
        } catch {
            Logger.claudeRecovery.warning("recovery_user_chose_failed localID=\(request.localSessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hook-Event-Handler: bei `SessionStart` mit nicht-leerer `session_id`
    /// updaten wir die externalSessionID; bei `SessionEnd(reason: "resume")`
    /// machen wir uns mental "darauf bereit, dass eine neue ID kommt" —
    /// behalten aber die alte ID bis das naechste SessionStart-Event kommt.
    private static func handleClaudeHookEvent(
        localID: UUID,
        event: ClaudeHookEvent,
        store: AgentSessionStore,
        terminalRegistry: AgentTerminalRegistry
    ) {
        switch event.hookEventName {
        case .sessionStart:
            guard let newID = event.sessionID, !newID.isEmpty else { return }
            do {
                try store.updateSession(id: localID) { session in
                    let old = session.externalSessionID
                    guard old != newID else { return }
                    session.externalSessionID = newID
                    Logger.claudeBinding.info("binding_launch_id_set localID=\(localID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(newID, privacy: .public)")
                }
                Task { @MainActor in
                    terminalRegistry.controller(for: localID)?.updateExternalSessionID(newID)
                }
            } catch {
                Logger.claudeBinding.warning("binding_launch_set_failed localID=\(localID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        case .sessionEnd:
            // /resume-Wechsel ist erwartet — naechstes SessionStart wird die
            // neue ID liefern. Nichts tun ausser Logging. Ein eventueller
            // "Needs input"-Pulse wird vom Notification-Listener selbst
            // bei .preToolUse / SessionStart geclearet — beim Ende ist die
            // Session ohnehin nicht mehr "awaiting".
            let reason = event.reason ?? "unknown"
            Logger.claudeBinding.info("binding_session_end localID=\(localID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .preToolUse:
            // Tool-Use bedeutet: die Session arbeitet wieder, also ist ein
            // "Needs input"-Pulse veraltet. Wir clearen ihn — der naechste
            // Notification-Event setzt ihn bei Bedarf erneut.
            Logger.claudeBinding.debug("binding_pretool_use localID=\(localID.uuidString, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputClearedNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .notification:
            // Wichtiges Signal: Claude druckt Permission-Prompts und andere
            // Notifications hier hinein. Fuer Background-Sessions ist das
            // der einzige verlaessliche "Needs input"-Trigger (kein
            // interaktives PTY). Wir posten eine NotificationCenter-
            // Notification, die die View in `awaitingInputSessionIDs`
            // einfuegt — die Sidebar pulst den Status entsprechend.
            Logger.claudeBinding.info("binding_notification localID=\(localID.uuidString, privacy: .public)")
            NotificationCenter.default.post(
                name: AgentChatsView.backgroundNeedsInputNotification,
                object: nil,
                userInfo: ["localID": localID]
            )
        case .other:
            return
        }
    }

    /// Hängt den Watcher an eine laufende Session — entweder direkt nach
    /// `markLaunched` (externalSessionID kann noch fehlen) oder nach
    /// `bindExternalSessionIDWhenAvailable` (jetzt mit valider ID).
    /// Idempotent: bei wiederholtem Aufruf updated der Watcher die ID intern.
    private func attachWatcher(sessionID: UUID) {
        guard let watcher = runtimeWatcher else { return }
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }
        watcher.watch(
            sessionID: session.id,
            provider: session.provider,
            externalSessionID: session.externalSessionID,
            cwd: project.path,
            priorTurnFinishedAt: session.lastTurnAt
        )
    }

    /// Triggert beim turn-finished-Signal des Watchers das Persistieren des
    /// `lastTurnAt`-Stempels und den Auto-Namer. Bewusst static, damit der
    /// Closure beim Watcher-Init kein View-`self` festhält.
    private static func handleTurnFinished(
        sessionID: UUID,
        store: AgentSessionStore,
        autoNamer: AgentSessionAutoNamer?,
        onCompletion: @escaping () -> Void
    ) {
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }

        // Auto-Namer mit Snapshot starten (lastTurnAt ist hier noch nil) —
        // der `recordTurnEnded` läuft direkt danach und beeinflusst diesen
        // Snapshot nicht mehr.
        autoNamer?.handleTurnFinished(session: session, cwd: project.path) { _ in
            Task { @MainActor in onCompletion() }
        }

        do {
            try store.recordTurnEnded(id: sessionID)
        } catch {
            Logger.debug("Failed to record turn ended: \(error.localizedDescription)")
        }
    }

    private func loadWorkspaceFast() {
        PerfBudgets.sidebarWorkspaceLoad.withInterval { loadWorkspaceFastBody() }
    }

    /// Vom Signpost-Wrapper getrennt, damit die bestehende
    /// durationMs-Logzeile unverändert bleibt. Läuft auf dem MainActor!
    private func loadWorkspaceFastBody() {
        let startedAt = Date()
        do {
            try store.markStaleRunningSessionsClosed(excluding: terminalRegistry.activeSessionIDs)
        } catch {
            errorMessage = error.localizedDescription
        }

        workspace = store.loadWorkspace()

        if selectedProjectID == nil || !workspace.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = workspace.projects.first?.id
        }
        if expandedProjectIDs.isEmpty {
            expandedProjectIDs = Set(workspace.projects.prefix(3).map(\.id))
        }
        if let selectedProjectID {
            expandedProjectIDs.insert(selectedProjectID)
        }
        if selectedSessionID == nil || !projectSessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = projectSessions.first?.id
        }
        Logger.agentPerformance.debug("agent_chats_fast_load durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) projects=\(workspace.projects.count) sessions=\(workspace.sessions.count)")
    }

    private func refreshSessionsInBackground(reason: String) {
        indexRefreshTask?.cancel()
        isIndexingSessions = true
        let startedAt = Date()
        let activeSessionIDs = terminalRegistry.activeSessionIDs

        indexRefreshTask = Task {
            defer {
                if !Task.isCancelled {
                    isIndexingSessions = false
                }
            }
            let result = Task.detached(priority: .utility) {
                try PerfBudgets.sidebarBackgroundIndex.withInterval {
                    let cacheStore = AgentSessionIndexCacheStore()
                    var cache = cacheStore.load()
                    let codex = CodexSessionIndexer().indexedSessionResult(cache: &cache)
                    let claude = ClaudeSessionIndexer().indexedSessionResult(cache: &cache)
                    cacheStore.save(cache)

                    let store = AgentSessionStore()
                    try store.markStaleRunningSessionsClosed(excluding: activeSessionIDs)
                    try store.mergeIndexedSessions(codex.sessions + claude.sessions)
                    return [codex.stats, claude.stats]
                }
            }

            guard !Task.isCancelled else { return }
            do {
                let stats = try await result.value
                guard !Task.isCancelled else { return }
                lastIndexStats = stats
                loadWorkspaceFast()
                // Manuelles Sessions-Scannen ist auch der natürliche Trigger,
                // um *alle* generisch benannten Sessions nachträglich vom
                // Auto-Namer benennen zu lassen — sowohl frisch indexierte
                // alte Sessions als auch solche, deren erster
                // Auto-Naming-Versuch vorher gescheitert ist.
                forceAutoNameUntitledSessions()
                Logger.agentPerformance.info("agent_chats_background_index reason=\(reason, privacy: .public) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) stats=\(lastIndexStats.map { "\($0.provider.rawValue):\($0.scannedFiles)/\($0.cacheHits)/\($0.bytesRead)" }.joined(separator: ","), privacy: .public)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Drag-and-Drop coordinators

    /// Reordert die Sessions eines Projekts: Row-Drops werden vom Planner
    /// richtungsabhaengig eingeordnet, `nil` bedeutet ans Ende anhaengen.
    /// Cross-Project: wenn `droppedSession.sourceProjectID != projectID`,
    /// wird die Session zusätzlich in das Ziel-Projekt verschoben.
    private func dropSession(
        _ dropped: DraggableSession,
        in projectID: UUID,
        beforeSessionID: UUID?
    ) {
        switch AgentDragDropPlanner.sessionDropPlan(
            dropped: dropped,
            targetProjectID: projectID,
            beforeSessionID: beforeSessionID,
            workspace: workspace
        ) {
        case .reorder(let projectID, let orderedIDs):
            do {
                try store.reorderSessions(in: projectID, orderedIDs: orderedIDs)
                workspace = store.loadWorkspace()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .move(let sessionID, let newProjectID, let targetIndex):
            do {
                try store.moveSessionToProject(
                    sessionID: sessionID,
                    newProjectID: newProjectID,
                    targetIndex: targetIndex
                )
                workspace = store.loadWorkspace()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .none:
            return
        }
    }

    /// Reordert die Projekt-Reihenfolge in der Sidebar — `droppedProject`
    /// wird vor `beforeProjectID` einsortiert (`nil` = ans Ende).
    private func dropProject(
        _ dropped: DraggableProject,
        beforeProjectID: UUID?
    ) {
        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: dropped,
            beforeProjectID: beforeProjectID,
            visibleProjects: manualProjects
        )
        guard case .reorder(let orderedIDs) = plan else { return }
        do {
            try store.reorderProjects(orderedIDs: orderedIDs)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Manueller Trigger aus dem "…"-Menü eines Tabs oder Sidebar-Rechtsklick.
    /// Erzwingt eine Title-Generierung für genau diese Session — auch wenn sie
    /// schon mal automatisch benannt war oder das letzte Auto-Naming
    /// fehlgeschlagen ist. `canAutoRenameTitle` bleibt aktiv: wenn der User
    /// manuell umbenannt hat (`titleIsAutoGenerated == false`), schreiben wir
    /// trotzdem nichts.
    private func forceAutoNameSession(_ session: AgentChatSession) {
        guard let autoNamer else { return }
        guard let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }
        autoNamer.forceGenerateTitle(session: session, cwd: project.path) { [store] result in
            if case .success = result {
                Task { @MainActor in
                    workspace = store.loadWorkspace()
                }
            }
        }
    }

    /// Geht durch alle nicht-archivierten Sessions, die noch einen generischen
    /// Default-Namen tragen ("Claude Chat" / "Codex Chat" / "… Chat") und ruft
    /// den Auto-Namer im Force-Modus auf. Nutzt `forceGenerateTitle`, das
    /// `lastTurnAt` und `alreadyAttempted` ignoriert — `canAutoRenameTitle`
    /// bleibt aber Schutz gegen User-Renames.
    private func forceAutoNameUntitledSessions() {
        guard let autoNamer else { return }

        let candidates: [(session: AgentChatSession, project: AgentProject)] = workspace.sessions.compactMap { session in
            guard session.status != .archived else { return nil }
            guard session.externalSessionID != nil else { return nil }
            guard isDefaultUntitled(session) else { return nil }
            guard let project = workspace.projects.first(where: { $0.id == session.projectID }) else { return nil }
            return (session, project)
        }

        guard !candidates.isEmpty else { return }

        for entry in candidates {
            autoNamer.forceGenerateTitle(session: entry.session, cwd: entry.project.path) { [store] result in
                if case .success = result {
                    Task { @MainActor in
                        workspace = store.loadWorkspace()
                    }
                }
            }
        }
    }

    /// Liefert `true`, wenn die Session noch einen generischen
    /// Auto-Default-Namen trägt — und damit Kandidat für nachträgliches
    /// Auto-Naming ist.
    private func isDefaultUntitled(_ session: AgentChatSession) -> Bool {
        let normalized = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "Claude Chat"
            || normalized == "Codex Chat"
            || normalized.hasSuffix(" Chat")
    }

    private func sessions(for project: AgentProject) -> [AgentChatSession] {
        // Sichtbarkeit: alle manuell erstellten, nicht-archivierten Sessions
        // die der User aktiv im Memory hat (openTabIDs) oder gerade selektiert.
        // status == .running/.pending ist redundant — laufende Sessions sind
        // per Definition in openTabIDs (werden bei Launch eingefuegt). Wir
        // muessen nur sicherstellen dass openTabIDs persistent ist (siehe
        // AgentUIState).
        AgentSessionStore.sortedSessions(
            workspace.sessions.filter { session in
                guard session.projectID == project.id,
                      session.status != .archived,
                      session.isManuallyCreated
                else { return false }
                return openTabIDs.contains(session.id)
                    || session.id == selectedSessionID
            }
        )
    }

    private func selectProject(_ projectID: UUID) {
        selectedProjectID = projectID
        expandedProjectIDs.insert(projectID)

        // Pro-Projekt-Erinnerung: wenn wir fuer dieses Projekt schon einen
        // zuletzt benutzten Tab persistiert haben, dahin zurueckspringen
        // statt automatisch auf "den ersten verfuegbaren".
        if let lastID = selectedSessionIDByProject[projectID],
           workspace.sessions.contains(where: { $0.id == lastID && $0.projectID == projectID }) {
            selectedSessionID = lastID
            openTabIDs.insert(lastID)
            return
        }

        let sessions = workspace.sessions
            .filter { $0.projectID == projectID && $0.status != .archived }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        if let firstID = sessions.first?.id {
            selectedSessionID = firstID
            openTabIDs.insert(firstID)
        } else {
            selectedSessionID = nil
        }
        if let project = workspace.projects.first(where: { $0.id == projectID }) {
            AppPreferences.shared.agentDefaultProjectPath = project.path
        }
    }

    private func toggleProject(_ projectID: UUID) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let project = try store.upsertProject(path: url.path, createdManually: true)
                workspace = store.loadWorkspace()
                selectedProjectID = project.id
                selectedSessionID = sessions(for: project).first?.id
                expandedProjectIDs.insert(project.id)
                AppPreferences.shared.agentDefaultProjectPath = project.path
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createSession(provider: AgentProvider, kind: AgentSessionKind? = nil) {
        guard let selectedProject else { return }
        do {
            // Agent View hat keine externe Session-ID (es ist ein Dashboard
            // ueber viele Sessions). Auch der Titel ist anders.
            let isAgentView = kind == .agentView
            let title = isAgentView
                ? "Agent View"
                : "\(provider.displayName) Chat"
            // Vorbereitete externe Session-ID nur fuer normale Claude-Chats —
            // damit unsere Hook-Bridge die JSONL findet. Codex und Agent View
            // generieren ihre IDs intern.
            let externalSessionID: String? = (provider == .claude && !isAgentView)
                ? UUID().uuidString.lowercased()
                : nil
            let session = try store.createSession(
                provider: provider,
                projectPath: selectedProject.path,
                title: title,
                model: AppPreferences.shared.codexPostProcessingModelRaw,
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                externalSessionID: externalSessionID,
                shouldLaunchOnOpen: true,
                kind: kind
            )
            workspace = store.loadWorkspace()
            selectedSessionID = session.id
            openTabIDs.insert(session.id)
            sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Background Agents (Phase 2)

    /// Oeffnet die Read-Only-Sub-Agent-Bibliothek als Sheet. Listet alle
    /// Sub-Agents aus `~/.claude/agents/` (User) + `.claude/agents/`
    /// (Projekt), grupiert nach Scope. Zweck: Discovery — der User sieht,
    /// was er dem `--agent`-Flag im Dispatch-Modal mitgeben kann.
    private func presentSubAgentLibrary() {
        let projectPath = selectedProject?.path
        let agents = SubAgentDiscovery.discover(projectPath: projectPath)
        subAgentLibrarySheet = SubAgentLibraryPresentation(
            projectName: selectedProject?.name,
            agents: agents
        )
    }

    /// Oeffnet das Background-Dispatch-Modal fuer das aktuell selektierte
    /// Projekt. Sub-Agent-Discovery laeuft synchron — die Listen sind klein
    /// und es ist FS-cached.
    private func presentBackgroundDispatchModal() {
        guard let project = selectedProject else { return }
        let subAgents = SubAgentDiscovery.discover(projectPath: project.path)
        pendingBackgroundDispatch = PendingBackgroundDispatch(
            project: project,
            subAgents: subAgents
        )
    }

    /// Spawnt einen neuen Background-Agent via `claude --bg`, persistiert die
    /// Short-ID auf die neu angelegte Session und triggert dann `claude attach`
    /// als PTY-Tab. Drei Stufen:
    ///
    /// 1. Persistieren — Tab erscheint sofort in der Sidebar (mit Pending-State).
    /// 2. Spawn — Subprocess-Aufruf, parsed Short-ID. Bei Fehler: errorMessage.
    /// 3. Attach — Short-ID auf Session schreiben + sessionActionRequest senden.
    @MainActor
    private func dispatchBackgroundAgent(in project: AgentProject, request: BackgroundDispatchRequest) async {
        // 1. Stub-Session anlegen (ohne Short-ID), Tab oeffnen.
        let session: AgentChatSession
        do {
            session = try store.createSession(
                provider: .claude,
                projectPath: project.path,
                title: backgroundSessionTitle(for: request),
                model: AppPreferences.shared.codexPostProcessingModelRaw,
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                externalSessionID: nil,
                initialPrompt: request.prompt,
                shouldLaunchOnOpen: false,
                kind: .backgroundChat,
                backgroundSubAgent: request.subAgent,
                backgroundPermissionMode: request.permissionMode
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        workspace = store.loadWorkspace()
        spawningBackgroundSessions.insert(session.id)
        selectedSessionID = session.id
        openTabIDs.insert(session.id)

        // 2. Hook-Bridge vorbereiten — die Background-Session erbt die
        //    Settings vom Supervisor, also muessen wir `--settings <path>`
        //    schon beim Spawn-Subprocess setzen, nicht erst beim spaeteren
        //    `claude attach`. Wenn die Bridge nicht da ist (sehr alter
        //    State / kein Hook-Setup), spawnen wir ohne Settings — der
        //    Agent laeuft trotzdem, wir kriegen halt keine Live-Events.
        let settingsPath = claudeHookBridge?.prepareSettingsFile(localSessionID: session.id)

        // 3. Spawn via BackgroundAgentSpawner.
        let extraArgs = AgentCommandBuilder.parseArguments(AppPreferences.shared.claudeExtraArguments)
        do {
            let result = try await BackgroundAgentSpawner.spawn(
                initialPrompt: request.prompt,
                projectPath: project.path,
                settingsFilePath: settingsPath,
                subAgent: request.subAgent,
                permissionMode: request.permissionMode,
                extraArguments: extraArgs
            )
            // 4. Short-ID persistieren + Hook-Tracking starten + Attach triggern.
            try store.setBackgroundShortID(localSessionID: session.id, shortID: result.shortID)
            try store.updateSession(id: session.id) { updated in
                updated.hasLaunchedInitialPrompt = true
            }
            workspace = store.loadWorkspace()
            spawningBackgroundSessions.remove(session.id)
            if settingsPath != nil {
                claudeHookBridge?.startTracking(localSessionID: session.id)
            }
            sessionActionRequest = AgentSessionActionRequest(sessionID: session.id, kind: .start)
        } catch {
            // Spawn fehlgeschlagen — Stub-Session ist nutzlos (kein Attach
            // moeglich ohne Short-ID), also wieder loeschen statt als
            // "Session noch nicht gestartet"-Geist liegen lassen.
            spawningBackgroundSessions.remove(session.id)
            try? store.deleteSession(id: session.id)
            workspace = store.loadWorkspace()
            openTabIDs.remove(session.id)
            if selectedSessionID == session.id {
                selectedSessionID = sessions(for: project).first?.id
            }
            errorMessage = "Hintergrund-Agent konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    // MARK: - Background Agents · Phase 3 (Lifecycle)

    /// Oeffnet das Logs-Sheet fuer eine Background-Session. Ruft `claude
    /// logs <id>` asynchron auf und reicht das Ergebnis ins Sheet weiter —
    /// das Sheet selbst zeigt einen Spinner, solange wir laden.
    @MainActor
    private func showBackgroundLogs(for session: AgentChatSession) {
        guard let shortID = session.backgroundShortID, !shortID.isEmpty else { return }
        let presentation = BackgroundLogsPresentation(
            sessionID: session.id,
            shortID: shortID,
            title: session.title,
            state: .loading
        )
        pendingBackgroundLogs = presentation
        pendingLifecycleSessions.insert(session.id)
        Task { @MainActor in
            defer { pendingLifecycleSessions.remove(session.id) }
            do {
                let result = try await BackgroundAgentLifecycle.logs(shortID: shortID)
                // Nur uebernehmen, wenn das Sheet noch fuer dieselbe Short-ID offen ist —
                // sonst hat der User das Sheet schon geschlossen oder gewechselt.
                guard pendingBackgroundLogs?.id == presentation.id else { return }
                let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr]\n" + result.stderr)
                pendingBackgroundLogs = presentation.with(state: .loaded(combined))
            } catch {
                guard pendingBackgroundLogs?.id == presentation.id else { return }
                pendingBackgroundLogs = presentation.with(state: .failed(error.localizedDescription))
            }
        }
    }

    /// Fuehrt eine Lifecycle-Aktion auf einer Background-Session aus. Bei
    /// `.rm` raeumen wir nach Erfolg auch den lokalen State auf (Tab
    /// schliessen + Session archivieren), bei den anderen Aktionen
    /// belassen wir die Session in der UI.
    @MainActor
    private func performBackgroundLifecycle(
        _ action: BackgroundAgentLifecycle.Action,
        on session: AgentChatSession
    ) {
        guard let shortID = session.backgroundShortID, !shortID.isEmpty else { return }
        pendingLifecycleSessions.insert(session.id)
        Task { @MainActor in
            defer { pendingLifecycleSessions.remove(session.id) }
            do {
                switch action {
                case .logs:
                    _ = try await BackgroundAgentLifecycle.logs(shortID: shortID)
                case .stop:
                    _ = try await BackgroundAgentLifecycle.stop(shortID: shortID)
                case .respawn:
                    _ = try await BackgroundAgentLifecycle.respawn(shortID: shortID)
                case .rm:
                    _ = try await BackgroundAgentLifecycle.remove(shortID: shortID)
                    forgetBackgroundSession(session.id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Lokales Cleanup, wenn der User die Session vom Supervisor entfernt
    /// hat (oder der Health-Check sie als verwaist klassifiziert).
    /// Terminiert ggf. das PTY, archiviert die Session, schliesst den Tab.
    @MainActor
    private func forgetBackgroundSession(_ id: UUID) {
        if terminalRegistry.controller(for: id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: id)
        }
        try? store.updateSession(id: id) { session in
            session.status = .archived
            session.backgroundShortID = nil
        }
        workspace = store.loadWorkspace()
        openTabIDs.remove(id)
        if selectedSessionID == id {
            selectedSessionID = projectSessions.first(where: { $0.id != id })?.id
        }
    }

    /// Beim Window-Open: pro Short-ID einmal Health-Check fahren. Sessions,
    /// die der Supervisor nicht mehr kennt, werden lokal archiviert — sonst
    /// liessen sie sich nicht mehr attachen und blieben als Zombies in der
    /// Sidebar. Idempotent: laeuft pro Window-Lifetime nur einmal.
    private func runBackgroundAgentStartupHealthCheckIfNeeded() {
        guard !hasRunStartupHealthCheck else { return }
        hasRunStartupHealthCheck = true
        let candidates: [(UUID, String)] = workspace.sessions.compactMap { session in
            guard session.isBackgroundChat,
                  session.status != .archived,
                  let id = session.backgroundShortID,
                  !id.isEmpty
            else { return nil }
            return (session.id, id)
        }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (sessionID, shortID) in candidates {
                let outcome = await BackgroundAgentLifecycle.healthCheck(shortID: shortID)
                guard outcome == .unknown else { continue }
                await MainActor.run {
                    forgetBackgroundSession(sessionID)
                }
            }
        }
    }

    /// Kurzer Titel-Fallback, bis der AutoNamer einen besseren Namen aus dem
    /// Transcript ableitet. Zeigt direkt den Prompt-Anfang an.
    private func backgroundSessionTitle(for request: BackgroundDispatchRequest) -> String {
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? trimmed
        let cap = 60
        let snippet = firstLine.count > cap ? String(firstLine.prefix(cap - 1)) + "…" : firstLine
        return snippet.isEmpty ? "Hintergrund-Agent" : snippet
    }

    private func markSession(_ id: UUID, status: AgentChatStatus) {
        do {
            if status == .closed || status == .archived {
                terminalRegistry.terminate(sessionID: id)
            }
            try store.updateSession(id: id) { session in
                session.status = status
            }
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func relaunch(_ id: UUID) {
        markSession(id, status: .pending)
        selectedSessionID = id
    }

    private func renameSession(id: UUID, title: String) {
        do {
            try store.renameSession(id: id, title: title)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSessionGroup(id: UUID, groupName: String?) {
        do {
            try store.setSessionGroup(id: id, groupName: groupName)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSessionColor(id: UUID, color: String?) {
        do {
            try store.setSessionColor(id: id, color: color)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Project metadata actions

    private func beginRenameProject(_ project: AgentProject) {
        renameProjectTargetID = project.id
        renameProjectDraft = project.name
    }

    private func renameProject(id: UUID, name: String) {
        do {
            try store.renameProject(id: id, name: name)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setProjectColor(id: UUID, color: String) {
        do {
            try store.setProjectColor(id: id, color: color)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Öffnet einen NSOpenPanel und speichert den absoluten Pfad als
    /// `customIconAbsolutePath` (Vorrang vor Auto-Detect-Pfad). Akzeptiert die
    /// üblichen Bildformate, die NSImage zuverlässig darstellt.
    private func chooseProjectIcon(_ project: AgentProject) {
        let panel = NSOpenPanel()
        panel.title = "Projekt-Icon wählen"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .svg, .icns, .ico, .image]
        panel.directoryURL = URL(fileURLWithPath: project.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.setProjectCustomIcon(id: project.id, absolutePath: url.path)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Setzt den Auto-Lookup-Status zurück und triggert sofort einen neuen
    /// Resolver-Lauf — User-getriggert via Context-Menü.
    private func reAutoDetectProjectIcon(_ project: AgentProject) {
        do {
            try store.clearProjectIcon(id: project.id)
            iconLookupAttempted.remove(project.id)
            workspace = store.loadWorkspace()
            attemptAutoDetectProjectIcons()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearProjectIcon(_ id: UUID) {
        do {
            try store.clearProjectIcon(id: id)
            iconLookupAttempted.insert(id)  // nicht direkt re-resolven
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Iteriert über alle Projekte und scannt deren Repos asynchron nach Icons,
    /// sofern noch kein Lookup gemacht wurde. Bewusst lazy: nur Projekte, deren
    /// `iconAutoLookupAttempted != true` und die in dieser App-Session noch
    /// nicht gescannt wurden.
    private func attemptAutoDetectProjectIcons() {
        let candidates = workspace.projects.filter { project in
            !iconLookupAttempted.contains(project.id)
                && project.iconAutoLookupAttempted != true
                && (project.customIconAbsolutePath?.isEmpty ?? true)
                && (project.iconRelativePath?.isEmpty ?? true)
        }
        guard !candidates.isEmpty else { return }

        for project in candidates {
            iconLookupAttempted.insert(project.id)
        }

        Task.detached(priority: .utility) { [store] in
            for project in candidates {
                let path = project.path
                let id = project.id
                let resolved = AgentProjectIconResolver.findIconRelativePath(in: path)
                do {
                    try store.applyAutoResolvedProjectIcon(id: id, relativePath: resolved)
                } catch {
                    Logger.debug("project_icon_auto_resolve_failed project=\(id.uuidString) error=\(error.localizedDescription)")
                }
            }
            await MainActor.run {
                workspace = store.loadWorkspace()
            }
        }
    }

    private func moveSession(id: UUID, direction: AgentSessionMoveDirection) {
        do {
            try store.moveSession(id: id, direction: direction)
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func sessionManagementMenu(_ session: AgentChatSession) -> some View {
        Group {
            Button("Umbenennen…", systemImage: "pencil") {
                beginRename(session)
            }
            Button("Titel automatisch generieren", systemImage: "sparkles") {
                forceAutoNameSession(session)
            }
            .disabled(session.externalSessionID == nil)
            Menu("Tab-Farbe") {
                ForEach(AgentChatColor.palette, id: \.self) { color in
                    Button {
                        setSessionColor(id: session.id, color: color)
                    } label: {
                        Label {
                            Text(AgentChatColorName.label(for: color))
                        } icon: {
                            Image(nsImage: colorSwatchImage(hex: color))
                        }
                    }
                }
                Divider()
                Button("Provider-Farbe verwenden", systemImage: "arrow.uturn.backward") {
                    setSessionColor(id: session.id, color: nil)
                }
            }
            if session.isBackgroundChat {
                Divider()
                backgroundLifecycleMenuItems(session)
            }
            Divider()
            Button("Schließen", systemImage: "xmark", role: .destructive) {
                closeHeaderTab(session)
            }
        }
    }

    /// Lifecycle-Aktionen, die nur fuer `.backgroundChat`-Sessions Sinn
    /// ergeben. Werden in `sessionManagementMenu` nur fuer Background-Tabs
    /// eingehaengt. Disabled-Zustand: Aktion laeuft bereits oder Short-ID
    /// noch nicht bekannt (Spawn pending oder fehlgeschlagen).
    @ViewBuilder
    private func backgroundLifecycleMenuItems(_ session: AgentChatSession) -> some View {
        let hasID = session.hasBackgroundShortID
        let busy = pendingLifecycleSessions.contains(session.id)
        Button("Logs anzeigen", systemImage: "doc.text.magnifyingglass") {
            showBackgroundLogs(for: session)
        }
        .disabled(!hasID || busy)
        Button("Stoppen", systemImage: "stop.circle") {
            performBackgroundLifecycle(.stop, on: session)
        }
        .disabled(!hasID || busy)
        Button("Respawn", systemImage: "arrow.clockwise.circle") {
            performBackgroundLifecycle(.respawn, on: session)
        }
        .disabled(!hasID || busy)
        Button("Vom Supervisor entfernen", systemImage: "trash", role: .destructive) {
            performBackgroundLifecycle(.rm, on: session)
        }
        .disabled(!hasID || busy)
    }

    private func beginRename(_ session: AgentChatSession) {
        renameTargetID = session.id
        renameDraft = session.title
    }

    private func closeHeaderTab(_ session: AgentChatSession) {
        // X-Klick auf Tab/Sidebar = Chat vollständig schließen.
        // Terminal terminieren (falls läuft) und Session archivieren – dadurch verschwindet
        // sie aus Header UND Sidebar (beide nutzen denselben `status != .archived` Filter).
        // Daten bleiben in der Workspace-Datei erhalten, nichts geht verloren.
        if terminalRegistry.controller(for: session.id)?.isRunning == true {
            terminalRegistry.terminate(sessionID: session.id)
        }

        do {
            try store.updateSession(id: session.id) { $0.status = .archived }
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }

        openTabIDs.remove(session.id)

        if selectedSessionID == session.id {
            // Nächste verfügbare Session im selben Projekt wählen (oder nil, wenn keine).
            let remaining = workspace.sessions.filter { other in
                other.id != session.id &&
                other.projectID == session.projectID &&
                other.status != .archived &&
                other.isManuallyCreated &&
                (other.status == .running || other.status == .pending || openTabIDs.contains(other.id))
            }
            selectedSessionID = remaining.first?.id
        }
    }

    private func switchSelectedProvider(to provider: AgentProvider) {
        guard let project = selectedProject else { return }
        if let match = projectSessions.first(where: { $0.provider == provider }) {
            selectedSessionID = match.id
        } else {
            createSession(provider: provider)
        }
        AppPreferences.shared.agentDefaultProjectPath = project.path
    }

    private func openSelectedProjectInPHPStorm() {
        guard let selectedProject else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: selectedProject.path)],
            withApplicationAt: URL(fileURLWithPath: "/Applications/PhpStorm.app"),
            configuration: configuration
        ) { app, error in
            if app == nil || error != nil {
                DispatchQueue.main.async {
                    errorMessage = error?.localizedDescription ?? "PhpStorm konnte nicht geöffnet werden."
                }
            }
        }
    }
}

/// Snapshot der Daten, die das Background-Dispatch-Sheet braucht. Wir
/// kopieren das selektierte Projekt + die zum Zeitpunkt-des-Open gefundenen
/// Sub-Agents rein, damit das Modal unabhaengig von Workspace-Aenderungen
/// im Hintergrund bleibt.
struct PendingBackgroundDispatch: Identifiable, Equatable {
    let id = UUID()
    let project: AgentProject
    let subAgents: [SubAgent]
}

/// State-Snapshot fuer das BG-Logs-Sheet (`claude logs <id>`). Der `id`
/// dient als Stable-Identity, damit SwiftUI's `.sheet(item:)` das Sheet
/// nicht bei jedem State-Wechsel neu rebuilded — wir tauschen nur den
/// `state`-Wert aus.
struct BackgroundLogsPresentation: Identifiable, Equatable {
    enum State: Equatable {
        case loading
        case loaded(String)
        case failed(String)
    }

    let id = UUID()
    let sessionID: UUID
    let shortID: String
    let title: String
    var state: State

    func with(state newState: State) -> BackgroundLogsPresentation {
        var copy = self
        copy.state = newState
        return copy
    }
}

/// Snapshot fuer das Sub-Agent-Library-Sheet — wir kopieren die geladene
/// Liste rein, damit das Sheet beim Resize / Scrollen nicht jeden Frame
/// die FS-Discovery erneut faehrt.
struct SubAgentLibraryPresentation: Identifiable, Equatable {
    let id = UUID()
    let projectName: String?
    let agents: [SubAgent]
}

/// Read-Only-Liste aller Sub-Agents im aktiven User+Project-Scope.
/// Zweck: Discovery. Keine Edit-Aktionen — wenn der User editieren will,
/// macht er das in seinem Editor und re-discovered durch erneutes Oeffnen.
struct SubAgentLibrarySheet: View {
    let presentation: SubAgentLibraryPresentation
    var onClose: () -> Void

    private var grouped: [(scope: SubAgent.Scope, agents: [SubAgent])] {
        let projectAgents = presentation.agents.filter { $0.scope == .project }
        let userAgents = presentation.agents.filter { $0.scope == .user }
        var sections: [(SubAgent.Scope, [SubAgent])] = []
        if !projectAgents.isEmpty { sections.append((.project, projectAgents)) }
        if !userAgents.isEmpty { sections.append((.user, userAgents)) }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "books.vertical")
                    .foregroundStyle(AgentTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sub-Agent-Bibliothek")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                    Text(presentation.projectName.map { "Scope: \($0) + global" } ?? "Scope: global")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                Spacer()
                Text("\(presentation.agents.count) Agents")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
            }

            if presentation.agents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(grouped, id: \.scope) { section in
                            sectionView(section.scope, agents: section.agents)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 260, maxHeight: 420)
            }

            HStack {
                Spacer()
                Button("Schließen") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .background(AgentTheme.panel)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(AgentTheme.textTertiary)
            Text("Keine Sub-Agents gefunden.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AgentTheme.textSecondary)
            Text("Lege Markdown-Files unter ~/.claude/agents/ an oder im Projekt unter .claude/agents/.")
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func sectionView(_ scope: SubAgent.Scope, agents: [SubAgent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(scope == .project ? "PROJEKT" : "GLOBAL")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.06)
                    .foregroundStyle(scope == .project ? .orange : AgentTheme.textTertiary)
                Text("· \(agents.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
            ForEach(agents) { agent in
                agentRow(agent)
            }
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: SubAgent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("@\(agent.name)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                if agent.isolationWorktree {
                    Label("worktree", systemImage: "square.stack.3d.up")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.indigo)
                }
                if let mode = agent.permissionMode {
                    Text(mode)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.purple)
                }
                if let model = agent.model {
                    Text(model)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                Spacer()
            }
            if let desc = agent.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(3)
            }
            if agent.hasToolsRestriction, let tools = agent.toolsRaw {
                Text("Tools: \(tools)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .lineLimit(2)
            }
            Text(agent.fileURL.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1)
        )
    }
}

/// Modaler Sheet, der den Output von `claude logs <short-id>` anzeigt.
/// Read-only — refresht nicht selbststaendig. Schliesst per Esc oder
/// "Schliessen"-Button.
struct BackgroundAgentLogsSheet: View {
    let presentation: BackgroundLogsPresentation
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(AgentTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logs · \(presentation.title)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                    Text("claude logs \(presentation.shortID)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                Spacer()
            }

            Group {
                switch presentation.state {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Lade Logs …").foregroundStyle(AgentTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .loaded(let output):
                    ScrollView {
                        Text(output.isEmpty ? "(kein Output)" : output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AgentTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1)
                    )
                    .frame(minHeight: 220, maxHeight: 380)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button("Schließen") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(AgentTheme.panel)
    }
}
