import AppKit
import SwiftUI

private struct AgentSessionActionRequest: Equatable {
    enum Kind: Equatable {
        case start
        case restart
    }

    let id = UUID()
    let sessionID: UUID
    let kind: Kind
}

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
    @SceneStorage("agentChatsInspectorVisible") private var isInspectorVisible = false
    @SceneStorage("agentChatsSidebarVisible") private var isSidebarVisible = true
    @State private var openTabIDs: Set<UUID> = []
    @State private var renameTargetID: UUID?
    @State private var renameDraft: String = ""

    private var selectedProject: AgentProject? {
        workspace.projects.first { $0.id == selectedProjectID } ?? workspace.projects.first
    }

    private var projectSessions: [AgentChatSession] {
        guard let selectedProject else { return [] }
        return sessions(for: selectedProject)
    }

    private var headerTabs: [AgentChatSession] {
        projectSessions.filter { session in
            if session.status == .running || session.status == .pending { return true }
            if openTabIDs.contains(session.id) { return true }
            if session.id == selectedSessionID { return true }
            return false
        }
    }

    private var selectedSession: AgentChatSession? {
        projectSessions.first { $0.id == selectedSessionID } ?? projectSessions.first
    }

    private var manualProjects: [AgentProject] {
        workspace.projects.filter(\.isManuallyAdded)
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
                    onRefresh: { refreshSessionsInBackground(reason: "inspector") },
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
        .onAppear {
            loadWorkspaceFast()
            syncActiveAgentChat()
        }
        .onDisappear {
            indexRefreshTask?.cancel()
            // Window zu → kein aktiver Chat mehr für Recording-Coordinator.
            AppState.shared.activeAgentChat = nil
        }
        .onChange(of: selectedSessionID) { _, _ in syncActiveAgentChat() }
        .onChange(of: selectedProjectID) { _, _ in syncActiveAgentChat() }
        .onChange(of: workspace) { _, _ in syncActiveAgentChat() }
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
                                createSession(provider: defaultAgentProvider)
                            },
                            onCloseSession: { closeHeaderTab($0) },
                            onRenameRequest: { beginRename($0) },
                            onRename: renameSession,
                            onSetColor: setSessionColor,
                            isRunning: { id in terminalRegistry.controller(for: id)?.isRunning == true }
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
        AgentProvider(rawValue: AppPreferences.shared.defaultAgentProviderRaw) ?? .claude
    }

    private var sidebarCommandRows: some View {
        VStack(spacing: 1) {
            Button {
                createSession(provider: defaultAgentProvider)
            } label: {
                SidebarCommandRow(icon: "square.stack.3d.up", title: "Neuer Chat", isActive: selectedProject != nil)
            }
            .buttonStyle(SidebarRowButtonStyle())
            .disabled(selectedProject == nil)
            .help("Neuen Codex Chat im aktuellen Projekt starten")

            Button {
                refreshSessionsInBackground(reason: "manual")
            } label: {
                SidebarCommandRow(icon: "arrow.triangle.2.circlepath", title: "Sessions scannen")
            }
            .buttonStyle(SidebarRowButtonStyle())
            .help("Sessions im Hintergrund neu indizieren")

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
                    onStateChanged: loadWorkspaceFast
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

                if let branch = selectedProject?.lastBranch, !branch.isEmpty {
                    BranchTag(branch: branch)
                        .help(selectedProject?.path ?? branch)
                }

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
        refreshSessionsInBackground(reason: "refresh")
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
                Logger.agentPerformance.info("agent_chats_background_index reason=\(reason, privacy: .public) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) stats=\(lastIndexStats.map { "\($0.provider.rawValue):\($0.scannedFiles)/\($0.cacheHits)/\($0.bytesRead)" }.joined(separator: ","), privacy: .public)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sessions(for project: AgentProject) -> [AgentChatSession] {
        // Identische Sichtbarkeitsregel wie `headerTabs`: nur Sessions, die im Header
        // aktiv sind. Sidebar und Header bleiben so 1:1 synchron — kein "Ghost"-Eintrag
        // einer geschlossenen Session, die oben schon weg ist.
        AgentSessionStore.sortedSessions(
            workspace.sessions.filter { session in
                guard session.projectID == project.id,
                      session.status != .archived,
                      session.isManuallyCreated
                else { return false }
                if session.status == .running || session.status == .pending { return true }
                if openTabIDs.contains(session.id) { return true }
                if session.id == selectedSessionID { return true }
                return false
            }
        )
    }

    private func selectProject(_ projectID: UUID) {
        selectedProjectID = projectID
        expandedProjectIDs.insert(projectID)
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

    private func createSession(provider: AgentProvider) {
        guard let selectedProject else { return }
        do {
            let title = "\(provider.displayName) Chat"
            let session = try store.createSession(
                provider: provider,
                projectPath: selectedProject.path,
                title: title,
                model: AppPreferences.shared.codexPostProcessingModelRaw,
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                externalSessionID: provider == .claude ? UUID().uuidString.lowercased() : nil,
                shouldLaunchOnOpen: true
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

private struct AgentResourceSummaryButton: View {
    let descriptors: [AgentResourceSessionDescriptor]

    @State private var snapshot = AgentResourceSnapshot.empty
    @State private var isPopoverPresented = false

    private var shouldPoll: Bool {
        isPopoverPresented || !descriptors.isEmpty
    }

    private var pollingKey: String {
        let processKey = descriptors
            .map { "\($0.id.uuidString):\($0.rootProcessID ?? 0)" }
            .joined(separator: ",")
        return "\(shouldPoll)-\(processKey)"
    }

    @State private var isHovered = false

    var body: some View {
        Button {
            refresh()
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 9, weight: .medium))
                Text(summaryText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textTertiary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? AgentTheme.border : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Session-Ressourcen anzeigen")
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
            AgentResourcePopover(snapshot: snapshot, onRefresh: refresh)
                .frame(width: 420)
        }
        .onAppear(perform: refresh)
        .onChange(of: descriptors) { _, _ in
            refresh()
        }
        .task(id: pollingKey) {
            guard shouldPoll else {
                refresh()
                return
            }

            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var isActive: Bool { snapshot.runningSessionCount > 0 }

    private var rowBackground: Color {
        if isActive { return AgentTheme.surface }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }

    private var summaryText: String {
        guard snapshot.runningSessionCount > 0 else { return "0" }
        return "\(snapshot.runningSessionCount) · \(AgentResourceFormat.cpu(snapshot.totalCPUPercent)) · \(AgentResourceFormat.memory(snapshot.totalMemoryBytes))"
    }

    private func refresh() {
        let descriptors = descriptors
        Task {
            let next = await Task.detached(priority: .utility) {
                AgentResourceMonitor().snapshot(for: descriptors)
            }.value
            snapshot = next
        }
    }
}

private struct AgentResourcePopover: View {
    let snapshot: AgentResourceSnapshot
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Resource Usage")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Aktualisieren")
            }
            .padding(14)

            HStack(spacing: 20) {
                metricColumn("CPU", AgentResourceFormat.cpu(snapshot.totalCPUPercent))
                metricColumn("Memory", AgentResourceFormat.memory(snapshot.totalMemoryBytes))
                if let ramShare = snapshot.ramSharePercent {
                    metricColumn("RAM Share", AgentResourceFormat.percent(ramShare))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Divider()

            if snapshot.projects.isEmpty {
                Text("Keine laufenden Agent-Sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.projects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
            }
        }
        .background(AgentTheme.panel)
    }

    private func metricColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectSection(_ project: AgentResourceProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(project.projectName.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(AgentResourceFormat.cpu(project.cpuPercent))  \(AgentResourceFormat.memory(project.memoryBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            ForEach(project.sessions) { session in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProviderIcon(
                            provider: session.provider,
                            size: 12,
                            tint: Color(hex: session.provider == .codex ? "#32D74B" : "#FF9F0A")
                        )
                        .frame(width: 18)
                        Text(session.title)
                            .lineLimit(1)
                        Spacer()
                        Text("\(AgentResourceFormat.cpu(session.cpuPercent))  \(AgentResourceFormat.memory(session.memoryBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ForEach(session.processes) { process in
                        HStack {
                            Text(process.command)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(AgentResourceFormat.cpu(process.cpuPercent))  \(AgentResourceFormat.memory(process.memoryBytes))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AgentTheme.background.opacity(0.35))
            }
        }
    }
}

private enum AgentResourceFormat {
    static func cpu(_ value: Double) -> String {
        "\(String(format: "%.1f", max(0, value)))%"
    }

    static func percent(_ value: Double) -> String {
        "\(String(format: "%.0f", max(0, value)))%"
    }

    static func memory(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1024 {
            return "\(String(format: "%.1f", megabytes)) MB"
        }
        return "\(String(format: "%.2f", megabytes / 1024)) GB"
    }
}

private struct ProjectChatGroup: View {
    let project: AgentProject
    let sessions: [AgentChatSession]
    let isExpanded: Bool
    let selectedProjectID: UUID?
    let selectedSessionID: UUID?
    var onSelectProject: () -> Void
    var onToggleExpanded: () -> Void
    var onSelectSession: (UUID) -> Void
    var onNewChat: () -> Void
    var onCloseSession: (AgentChatSession) -> Void
    var onRenameRequest: (AgentChatSession) -> Void
    var onRename: (UUID, String) -> Void
    var onSetColor: (UUID, String?) -> Void
    var isRunning: (UUID) -> Bool

    @State private var isHeaderHovered = false

    private var isSelected: Bool {
        selectedProjectID == project.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader

            if isExpanded && !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions.prefix(20)) { session in
                        SessionListButton(
                            session: session,
                            isSelected: selectedSessionID == session.id,
                            isRunning: isRunning(session.id),
                            onSelect: { onSelectSession(session.id) },
                            onClose: { onCloseSession(session) }
                        )
                        .contextMenu {
                            Button("Umbenennen…", systemImage: "pencil") {
                                onRenameRequest(session)
                            }
                            Menu("Tab-Farbe") {
                                ForEach(AgentChatColor.palette, id: \.self) { color in
                                    Button {
                                        onSetColor(session.id, color)
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
                                    onSetColor(session.id, nil)
                                }
                            }
                            Divider()
                            Button("Schließen", systemImage: "xmark", role: .destructive) {
                                onCloseSession(session)
                            }
                        }
                    }
                }
            }
        }
    }

    private var groupHeader: some View {
        Button(action: onSelectProject) {
            HStack(alignment: .center, spacing: 9) {
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.12), value: isExpanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: project.color))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Text(project.name.prefix(1).uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                            .foregroundStyle(AgentTheme.textTertiary)
                        Text(project.lastBranch ?? "local")
                            .font(.system(size: 10))
                            .foregroundStyle(AgentTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !sessions.isEmpty {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(AgentTheme.textTertiary)
                            Text("\(sessions.count)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(AgentTheme.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 6)

                if isHeaderHovered {
                    Button(action: onNewChat) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Neuen Codex Chat im Projekt starten")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(minHeight: 36, maxHeight: 36)
            .background(headerBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
    }

    private var headerBackground: Color {
        if isSelected { return AgentTheme.selection }
        if isHeaderHovered { return AgentTheme.hover }
        return Color.clear
    }

    private var groupedSessions: [(name: String?, sessions: [AgentChatSession])] {
        let groups = Dictionary(grouping: sessions) { $0.groupName }
        let groupNames = groups.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case let (left?, right?):
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            case (nil, nil):
                return false
            }
        }
        return groupNames.map { ($0, groups[$0] ?? []) }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct SessionListButton: View {
    let session: AgentChatSession
    let isSelected: Bool
    let isRunning: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false

    /// Position des Connector-Strichs vom linken Rand der Sidebar — exakt unter
    /// der Mitte des 18×18 Project-Avatars (8 px outer-padding + 9 px Avatar-Halbbreite).
    private static let connectorX: CGFloat = 18

    private var customColor: Color? {
        guard let hex = session.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .leading) {
                // Vertikale Connector-Linie — pro Sub-Item rendern, dadurch kontinuierlich
                // wenn die Items in einer VStack mit spacing 0 stehen.
                Rectangle()
                    .fill(isSelected ? AgentTheme.connectorActive : AgentTheme.connector)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, Self.connectorX)

                HStack(spacing: 8) {
                    if let customColor {
                        Circle()
                            .fill(customColor.opacity(isSelected ? 0.95 : 0.7))
                            .frame(width: 6, height: 6)
                    } else {
                        ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textTertiary)
                            .frame(width: 11, alignment: .center)
                    }

                    Text(session.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    trailingIndicator
                        .frame(width: 18, alignment: .trailing)
                }
                .padding(.leading, 28)
                .padding(.trailing, 8)
            }
            .frame(minHeight: 26, maxHeight: 26)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isHovered || isSelected {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 16, height: 16)
                .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .help("Chat schließen")
        } else if isRunning {
            Circle()
                .fill(Color.green.opacity(0.65))
                .frame(width: 5, height: 5)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var rowBackground: Color {
        if isSelected { return AgentTheme.selection }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }
}

private struct SidebarCommandRow: View {
    let icon: String
    let title: String
    var isActive: Bool = false
    var trailingIcon: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .frame(width: 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground(pressed: configuration.isPressed))
            )
            .padding(.horizontal, 8)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func rowBackground(pressed: Bool) -> Color {
        if pressed { return AgentTheme.selectionStrong }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }
}

private struct ProviderTab: View {
    let provider: AgentProvider
    let isActive: Bool
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProviderIcon(
                    provider: provider,
                    size: 12,
                    tint: isActive ? AgentTheme.textPrimary : AgentTheme.textTertiary
                )
                Text(provider.displayName)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(background, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isActive { return AgentTheme.tabSelected }
        if isHovered { return AgentTheme.surface }
        return Color.clear
    }
}

private struct ChatTabButton: View {
    let session: AgentChatSession
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false

    private var customColor: Color? {
        guard let hex = session.color, !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let customColor {
                    Rectangle()
                        .fill(customColor.opacity(isSelected ? 0.85 : 0.55))
                        .frame(width: 3, height: 14)
                } else {
                    ProviderIcon(provider: session.provider, size: 11, tint: AgentTheme.textTertiary)
                }

                Text(session.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                trailingIndicator
                    .frame(width: 18, alignment: .trailing)
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 90, maxWidth: 200, minHeight: 22, maxHeight: 22)
            .background(tabBackground, in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isHovered || isSelected {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 16, height: 16)
                .background(AgentTheme.hover, in: RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .help("Tab schließen")
        } else if session.status == .running {
            Circle()
                .fill(AgentTheme.textTertiary)
                .frame(width: 4, height: 4)
        } else if session.status != .archived {
            Text(session.status.displayName)
                .font(.system(size: 9))
                .foregroundStyle(AgentTheme.textTertiary)
                .lineLimit(1)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var tabBackground: Color {
        if isSelected { return AgentTheme.tabSelected }
        if isHovered { return AgentTheme.surface }
        return Color.clear
    }

    private var borderColor: Color {
        isSelected ? AgentTheme.borderStrong : AgentTheme.border
    }
}

/// Rendert das offizielle Provider-Logo (Claude / Codex) aus dem Asset-Bundle.
/// Fällt bei fehlendem Asset auf das SF-Symbol zurück.
/// Lesbarer Name für jede Palette-Farbe — wird im Tab-Farbe-Menü als
/// Haupttext angezeigt (statt nur Hex-Code).
private enum AgentChatColorName {
    static let map: [String: String] = [
        "#32D74B": "Grün",
        "#FF9F0A": "Orange",
        "#0A84FF": "Blau",
        "#BF5AF2": "Lila",
        "#FF453A": "Rot",
        "#64D2FF": "Türkis",
        "#FFD60A": "Gelb",
        "#AC8E68": "Sand"
    ]

    static func label(for hex: String) -> String {
        map[hex] ?? hex
    }
}

/// Erzeugt ein farbiges 12×12-Swatch als NSImage. Für Context-Menüs robuster
/// als `Image(systemName:).foregroundStyle(...)`, das im Menü-Renderer oft
/// die Tint-Farbe verliert.
private func colorSwatchImage(hex: String, size: CGFloat = 12) -> NSImage {
    let nsColor = NSColor(Color(hex: hex))
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        nsColor.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let stroke = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        stroke.lineWidth = 0.5
        stroke.stroke()
        return true
    }
    image.isTemplate = false
    return image
}

private struct ProviderIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 11
    var tint: Color = AgentTheme.textSecondary

    var body: some View {
        if let nsImage = NSImage(named: provider.assetName) {
            let templateImage = Self.templateCopy(nsImage)
            Image(nsImage: templateImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(tint)
        } else {
            Image(systemName: provider.systemImage)
                .font(.system(size: size - 1, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }

    private static func templateCopy(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.isTemplate = true
        return copy
    }
}

private struct AgentChatsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedRed: 0.058, green: 0.060, blue: 0.064, alpha: 1)
    }
}

private struct TitlebarIconButton: View {
    let systemImage: String
    let help: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 24, height: 22)
                .background(background, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .onHover { isHovered = $0 && !isDisabled }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var foreground: Color {
        if isDisabled { return AgentTheme.textTertiary.opacity(0.6) }
        if isActive { return AgentTheme.textPrimary }
        return AgentTheme.textSecondary
    }

    private var background: Color {
        if isDisabled { return Color.clear }
        if isActive { return AgentTheme.selection }
        if isHovered { return AgentTheme.hover }
        return Color.clear
    }
}

private struct BranchTag: View {
    let branch: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .bold))
            Text(formattedBranch)
                .font(.system(size: 10, weight: .semibold).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 1.0))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(red: 0.78, green: 0.62, blue: 1.0).opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.78, green: 0.62, blue: 1.0).opacity(0.25), lineWidth: 1))
        .frame(maxWidth: 180)
    }

    private var formattedBranch: String {
        branch.hasPrefix("/") ? branch : "/\(branch)"
    }
}

private struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    var isActive: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? AgentTheme.textPrimary : AgentTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var background: Color {
        if isActive { return AgentTheme.selection }
        if isHovered { return AgentTheme.surface }
        return AgentTheme.headerTab
    }
}

private struct ProjectDetailPanel: View {
    let project: AgentProject?
    let session: AgentChatSession?
    let sessions: [AgentChatSession]
    var onRefresh: () -> Void
    var onNewCodexChat: () -> Void
    var onNewClaudeChat: () -> Void
    var onOpenPHPStorm: () -> Void

    @State private var status: GitProjectStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project context")
                        .font(.headline.weight(.semibold))
                    Text("\(project?.name ?? "-") · \(session?.title ?? "Kein Chat")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    refreshPanel()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            detailCard {
                DetailHeader(title: "Recording Context", icon: "mic")
                DetailRow(label: "Kontextquelle", value: "Aktiver Chat")
                if let session {
                    HStack {
                        ProviderIcon(
                            provider: session.provider,
                            size: 13,
                            tint: Color(hex: AgentChatColor.fallback(for: session))
                        )
                        Text(session.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text(session.status.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 7))
                }
            }

            detailCard {
                DetailHeader(title: "Branch-Details", icon: "point.topleft.down.curvedto.point.bottomright.up")
                DetailRow(label: "Projekt", value: project?.name ?? "-")
                DetailRow(label: "Branch", value: status?.branch ?? project?.lastBranch ?? "local")
                DetailRow(label: "Pfad", value: project?.path ?? "-", monospaced: true)
            }

            detailCard {
                DetailHeader(title: "Änderungen", icon: "doc.text.magnifyingglass")
                HStack {
                    Text(status?.summary ?? "Kein Git-Status")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let status {
                        Text("+\(status.added) -\(status.deleted)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(status.added > 0 ? .green : .secondary, status.deleted > 0 ? .red : .secondary)
                    }
                }
                .font(.callout)
            }

            detailCard {
                DetailHeader(title: "Git-Aktionen", icon: "arrow.triangle.branch")
                CompactActionButton(title: "Status prüfen", icon: "checklist", action: refreshPanel)
                CompactActionButton(title: "Neuer Codex Chat", icon: "sparkles", action: onNewCodexChat)
                CompactActionButton(title: "Neuer Claude Chat", icon: "seal", action: onNewClaudeChat)
            }

            detailCard {
                DetailHeader(title: "Arbeitsumgebung", icon: "hammer")
                CompactActionButton(title: "PHPStorm öffnen", icon: "chevron.left.forwardslash.chevron.right", action: onOpenPHPStorm)
                DetailRow(label: "Aktiver Chat", value: session?.title ?? "-")
                DetailRow(label: "Provider", value: session?.provider.displayName ?? "-")
            }

            detailCard {
                DetailHeader(title: "Artefakte & Quellen", icon: "shippingbox")
                DetailRow(label: "Chats", value: "\(sessions.count)")
                DetailRow(label: "Screenshots", value: "\(session?.imagePaths.count ?? 0)")
                DetailRow(label: "Modell", value: session?.model ?? "-")
            }

            Spacer()
        }
        .padding(16)
        .background(AgentTheme.background)
        .onAppear(perform: refreshGitStatus)
        .onChange(of: project?.path) { _, _ in
            refreshGitStatus()
        }
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgentTheme.border, lineWidth: 1))
    }

    private func refreshPanel() {
        refreshGitStatus()
        onRefresh()
    }

    private func refreshGitStatus() {
        guard let project else {
            status = nil
            return
        }
        status = GitProjectStatus(path: project.path)
    }
}

private struct DetailHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct CompactActionButton: View {
    let title: String
    let icon: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private struct AgentSessionDetailView: View {
    let project: AgentProject
    let session: AgentChatSession
    @ObservedObject var terminalRegistry: AgentTerminalRegistry
    var actionRequest: AgentSessionActionRequest?
    var onStateChanged: () -> Void

    @State private var store = AgentSessionStore()
    @State private var errorMessage: String?

    private var controller: AgentTerminalController? {
        terminalRegistry.controller(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                AgentTerminalView(controller: controller)
                    .background(AgentTheme.background)
            } else {
                inactiveTerminalPreview
            }
        }
        .onAppear {
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
        }
        .onChange(of: session.id) { _, _ in
            errorMessage = nil
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
        }
        .onChange(of: actionRequest) { _, request in
            handleActionRequest(request)
        }
    }

    private var inactiveTerminalPreview: some View {
        ZStack(alignment: .topLeading) {
            AgentTheme.background

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout.monospaced())
                    .padding(18)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session metadata loaded. Terminal is not attached.")
                    Text("Use Resume in the header to reconnect this \(session.provider.displayName) session.")
                    if let externalSessionID = session.externalSessionID {
                        Text("session \(externalSessionID)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .padding(18)
            }
        }
    }

    private func handleActionRequest(_ request: AgentSessionActionRequest?) {
        guard let request, request.sessionID == session.id else { return }
        switch request.kind {
        case .start:
            prepareCommand()
        case .restart:
            restartTerminal()
        }
    }

    private func prepareCommand() {
        do {
            let command = try AgentCommandBuilder().command(for: session, project: project)
            terminalRegistry.startController(
                sessionID: session.id,
                command: command,
                onLaunched: markLaunched,
                onTerminated: { _ in markTerminated() }
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restartTerminal() {
        terminalRegistry.terminate(sessionID: session.id)
        prepareCommand()
    }

    private func markLaunched() {
        do {
            try store.updateSession(id: session.id) { updated in
                updated.status = .running
                updated.hasLaunchedInitialPrompt = true
                updated.shouldLaunchOnOpen = false
                updated.initialPrompt = nil
            }
            bindExternalSessionIDWhenAvailable()
            onStateChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markTerminated() {
        do {
            try store.updateSession(id: session.id) { updated in
                if updated.status == .running {
                    updated.status = .closed
                }
            }
            onStateChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bindExternalSessionIDWhenAvailable() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                let indexedSessions = CodexSessionIndexer().indexedSessions(limit: 20)
                    + ClaudeSessionIndexer().indexedSessions(limit: 20)
                if try store.bindLatestIndexedSession(
                    localSessionID: session.id,
                    provider: session.provider,
                    projectPath: project.path,
                    indexedSessions: indexedSessions
                ) != nil {
                    onStateChanged()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct GitProjectStatus {
    var branch: String?
    var changedFiles: Int
    var added: Int
    var deleted: Int

    var summary: String {
        changedFiles == 0 ? "Clean" : "\(changedFiles) Dateien geändert"
    }

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        branch = Self.git(["-C", path, "branch", "--show-current"])?.nilIfEmpty
        let porcelain = Self.git(["-C", path, "status", "--porcelain"]) ?? ""
        changedFiles = porcelain
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count

        let diff = Self.git(["-C", path, "diff", "--numstat"]) ?? ""
        var addedTotal = 0
        var deletedTotal = 0
        for line in diff.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            addedTotal += Int(parts[0]) ?? 0
            deletedTotal += Int(parts[1]) ?? 0
        }
        added = addedTotal
        deleted = deletedTotal
    }

    private static func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

private enum AgentTheme {
    static let background = Color(nsColor: NSColor(calibratedRed: 0.058, green: 0.060, blue: 0.064, alpha: 1))
    static let sidebar = Color(nsColor: NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.082, alpha: 1))
    static let header = Color(nsColor: NSColor(calibratedRed: 0.070, green: 0.072, blue: 0.076, alpha: 1))
    static let surface = Color(nsColor: NSColor(calibratedRed: 0.090, green: 0.092, blue: 0.097, alpha: 1))
    static let panel = Color(nsColor: NSColor(calibratedRed: 0.105, green: 0.108, blue: 0.114, alpha: 1))
    static let control = Color(nsColor: NSColor(calibratedRed: 0.140, green: 0.143, blue: 0.150, alpha: 1))
    static let hover = Color.white.opacity(0.04)
    static let selection = Color.white.opacity(0.07)
    static let selectionStrong = Color.white.opacity(0.10)
    static let headerTab = Color(nsColor: NSColor(calibratedRed: 0.080, green: 0.082, blue: 0.086, alpha: 1))
    static let tabSelected = Color(nsColor: NSColor(calibratedRed: 0.115, green: 0.118, blue: 0.124, alpha: 1))
    static let statusPill = Color(nsColor: NSColor(calibratedRed: 0.050, green: 0.052, blue: 0.055, alpha: 1))
    static let border = Color.white.opacity(0.06)
    static let borderStrong = Color.white.opacity(0.10)
    static let connector = Color.white.opacity(0.10)
    static let connectorActive = Color.white.opacity(0.22)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.38)
    static let accentDiffPos = Color(nsColor: NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.45, alpha: 1))
    static let accentDiffNeg = Color(nsColor: NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.40, alpha: 1))
}

private extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
