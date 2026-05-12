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
    @StateObject private var terminalRegistry = AgentTerminalRegistry()
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
            externalSessionID: session.externalSessionID
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
                LazyVStack(alignment: .leading, spacing: 8) {
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
                            runtimeStatus: { id in runtimeStatusStore.statuses[id] },
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
                    Button("Neuer Claude Agent View") {
                        createSession(provider: .claude, kind: .agentView)
                    }
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

            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AgentTheme.textTertiary)

                if let selectedSession {
                    Text(selectedSession.title)
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .lineLimit(1)
                } else if let selectedProject {
                    Text(URL(fileURLWithPath: selectedProject.path).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Kein Projekt ausgewählt")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }

                Spacer()

                if let selectedSession {
                    Text(selectedSession.runtimeDisplayText)
                        .font(.system(size: 9, weight: .regular).monospacedDigit())
                        .foregroundStyle(AgentTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
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
            // neue ID liefern. Nichts tun ausser Logging.
            let reason = event.reason ?? "unknown"
            Logger.claudeBinding.info("binding_session_end localID=\(localID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
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
            Divider()
            Button("Schließen", systemImage: "xmark", role: .destructive) {
                closeHeaderTab(session)
            }
        }
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
