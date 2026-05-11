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
    /// Live-Status-Store für die Sidebar-Indikatoren. Wird vom
    /// `AgentSessionRuntimeWatcher` gepflegt, ephemeral (nicht persistiert).
    @StateObject private var runtimeStatusStore = AgentSessionRuntimeStatusStore()
    /// Lazy-init in `setupRuntimeServicesIfNeeded()`, weil beide Services Refs
    /// auf Store + Closures brauchen, die wir vor `body` nicht haben.
    @State private var runtimeWatcher: AgentSessionRuntimeWatcher?
    @State private var autoNamer: AgentSessionAutoNamer?
    @State private var summarizer: AgentSessionSummarizer?
    /// In-flight Summary-IDs für UI-Spinner. Wird vom Coordinator beim Aufruf
    /// gesetzt und nach Completion wieder geräumt.
    @State private var summariesInFlight: Set<UUID> = []
    @SceneStorage("agentChatsInspectorVisible") private var isInspectorVisible = false
    @SceneStorage("agentChatsSidebarVisible") private var isSidebarVisible = true
    @State private var openTabIDs: Set<UUID> = []
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
        .sheet(isPresented: Binding(
            get: { renameProjectTargetID != nil },
            set: { if !$0 { renameProjectTargetID = nil } }
        )) {
            renameProjectSheet
        }
        .onAppear {
            setupRuntimeServicesIfNeeded()
            loadWorkspaceFast()
            syncActiveAgentChat()
            attemptAutoDetectProjectIcons()
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
                                createSession(provider: defaultAgentProvider)
                            },
                            onCloseSession: { closeHeaderTab($0) },
                            onRenameRequest: { beginRename($0) },
                            onAutoNameRequest: { forceAutoNameSession($0) },
                            onRename: renameSession,
                            onSetColor: setSessionColor,
                            isRunning: { id in terminalRegistry.controller(for: id)?.isRunning == true },
                            runtimeStatus: { id in runtimeStatusStore.statuses[id] },
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
                    onStateChanged: loadWorkspaceFast,
                    onSessionLaunched: { sessionID in
                        attachWatcher(sessionID: sessionID)
                    },
                    onSessionTerminated: { sessionID, exitCode in
                        runtimeWatcher?.markTerminated(sessionID: sessionID, exitCode: exitCode)
                    },
                    onExternalSessionIDBound: { sessionID in
                        attachWatcher(sessionID: sessionID)
                    },
                    onRequestSummary: { sessionID, force in
                        requestSummary(sessionID: sessionID, force: force)
                    },
                    isGeneratingSummary: { id in summariesInFlight.contains(id) }
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
        refreshSessionsInBackground(reason: "refresh")
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
        if summarizer == nil {
            summarizer = AgentSessionSummarizer(store: store)
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
                generateMissingSummariesAfterScan()
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

    /// Reordert die Sessions eines Projekts: `droppedSession` wird *vor*
    /// `beforeSessionID` einsortiert (`nil` bedeutet ans Ende anhängen).
    /// Cross-Project: wenn `droppedSession.sourceProjectID != projectID`,
    /// wird die Session zusätzlich in das Ziel-Projekt verschoben.
    private func dropSession(
        _ dropped: DraggableSession,
        in projectID: UUID,
        beforeSessionID: UUID?
    ) {
        if dropped.sourceProjectID == projectID {
            // Reorder innerhalb desselben Projekts.
            let currentSessions = workspace.sessions
                .filter { $0.projectID == projectID && $0.status != .archived }
            let sorted = AgentSessionStore.sortedSessions(currentSessions)
            var orderedIDs = sorted.map(\.id).filter { $0 != dropped.sessionID }
            let insertAt: Int
            if let beforeSessionID, let idx = orderedIDs.firstIndex(of: beforeSessionID) {
                insertAt = idx
            } else {
                insertAt = orderedIDs.count
            }
            orderedIDs.insert(dropped.sessionID, at: insertAt)
            do {
                try store.reorderSessions(in: projectID, orderedIDs: orderedIDs)
                workspace = store.loadWorkspace()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        // Cross-Project-Move: Session ins Ziel-Projekt verschieben und an
        // der gewünschten Position einsortieren.
        let targetSessions = workspace.sessions
            .filter { $0.projectID == projectID && $0.status != .archived }
        let sorted = AgentSessionStore.sortedSessions(targetSessions)
        let targetIndex: Int
        if let beforeSessionID, let idx = sorted.firstIndex(where: { $0.id == beforeSessionID }) {
            targetIndex = idx
        } else {
            targetIndex = sorted.count
        }
        do {
            try store.moveSessionToProject(
                sessionID: dropped.sessionID,
                newProjectID: projectID,
                targetIndex: targetIndex
            )
            workspace = store.loadWorkspace()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reordert die Projekt-Reihenfolge in der Sidebar — `droppedProject`
    /// wird vor `beforeProjectID` einsortiert (`nil` = ans Ende).
    private func dropProject(
        _ dropped: DraggableProject,
        beforeProjectID: UUID?
    ) {
        let visible = manualProjects
        var orderedIDs = visible.map(\.id).filter { $0 != dropped.projectID }
        let insertAt: Int
        if let beforeProjectID, let idx = orderedIDs.firstIndex(of: beforeProjectID) {
            insertAt = idx
        } else {
            insertAt = orderedIDs.count
        }
        orderedIDs.insert(dropped.projectID, at: insertAt)
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

    /// Nach einem Sessions-Scan: für alle nicht-archivierten Sessions ohne
    /// `summary` einen passiven Generate-Pass anstoßen. Reuses den selben
    /// in-flight-Tracker wie der Detail-View, sodass UI-Spinner konsistent
    /// bleiben, falls der User in der Zeit eine Session öffnet.
    private func generateMissingSummariesAfterScan() {
        for session in workspace.sessions {
            guard session.status != .archived else { continue }
            guard session.summary == nil else { continue }
            guard session.externalSessionID != nil else { continue }
            requestSummary(sessionID: session.id, force: false)
        }
    }

    /// Wird vom Detail-View bei `onAppear` (passiv, force=false) und vom
    /// "Neu generieren"-Button (force=true) aufgerufen. Verwaltet den
    /// in-flight Set für den Spinner-State und reloaded den Workspace
    /// nach erfolgreichem Schreiben.
    private func requestSummary(sessionID: UUID, force: Bool) {
        guard let summarizer else { return }
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }
        if !force, session.summary != nil { return }
        if summariesInFlight.contains(sessionID) { return }

        summariesInFlight.insert(sessionID)
        let started = summarizer.generateSummary(
            for: session,
            cwd: project.path,
            force: force
        ) { [store] result in
            Task { @MainActor in
                summariesInFlight.remove(sessionID)
                if case .success = result {
                    workspace = store.loadWorkspace()
                }
            }
        }
        if !started {
            // generateSummary hat schon vorher abgebrochen (z.B. weil
            // bereits ein Summary existiert). UI-State entsprechend zurücknehmen.
            summariesInFlight.remove(sessionID)
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
    var onAutoNameRequest: (AgentChatSession) -> Void
    var onRename: (UUID, String) -> Void
    var onSetColor: (UUID, String?) -> Void
    var isRunning: (UUID) -> Bool
    var runtimeStatus: (UUID) -> AgentSessionRuntimeStatus?
    var onRenameProjectRequest: (AgentProject) -> Void
    var onSetProjectColor: (UUID, String) -> Void
    var onChooseProjectIcon: (AgentProject) -> Void
    var onAutoDetectProjectIcon: (AgentProject) -> Void
    var onClearProjectIcon: (UUID) -> Void
    /// Drop-Handler: `droppedSession` soll vor `beforeSessionID` einsortiert
    /// werden (oder ans Ende wenn `nil`). Wenn `droppedSession.sourceProjectID`
    /// vom aktuellen Projekt abweicht, ist's automatisch ein Cross-Project-Move.
    var onSessionDrop: (DraggableSession, _ beforeSessionID: UUID?, _ targetProjectID: UUID) -> Void
    /// Drop eines Projekts vor diesem Projekt (oder `nil` = ans Ende der Liste).
    var onProjectDrop: (DraggableProject, _ beforeProjectID: UUID?) -> Void

    @State private var isHeaderHovered = false
    @State private var isSessionDragOver: Bool = false
    @State private var isProjectDragOver: Bool = false

    private var isSelected: Bool {
        selectedProjectID == project.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader

            if isExpanded && !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions.prefix(20)) { session in
                        sessionRow(session)
                    }
                    // Trailing-Spacer als Drop-Target für "ans Ende anhängen":
                    // 8px transparente Zone unterhalb der letzten Row fängt
                    // Drops, die unter alle Sessions zielen.
                    Color.clear
                        .frame(height: 8)
                        .contentShape(Rectangle())
                        .dropDestination(for: DraggableSession.self) { items, _ in
                            guard let dropped = items.first else { return false }
                            onSessionDrop(dropped, nil, project.id)
                            return true
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentChatSession) -> some View {
        SessionListButton(
            session: session,
            isSelected: selectedSessionID == session.id,
            isRunning: isRunning(session.id),
            runtimeStatus: runtimeStatus(session.id),
            onSelect: { onSelectSession(session.id) },
            onClose: { onCloseSession(session) }
        )
        .draggable(DraggableSession(sessionID: session.id, sourceProjectID: project.id))
        .dropDestination(for: DraggableSession.self) { items, _ in
            guard let dropped = items.first else { return false }
            onSessionDrop(dropped, session.id, project.id)
            return true
        }
        .contextMenu {
            Button("Umbenennen…", systemImage: "pencil") {
                onRenameRequest(session)
            }
            Button("Titel automatisch generieren", systemImage: "sparkles") {
                onAutoNameRequest(session)
            }
            .disabled(session.externalSessionID == nil)
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

                ProjectAvatar(project: project)

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
            .background(headerBackground.overlay(
                isSessionDragOver || isProjectDragOver
                    ? AgentTheme.selection.opacity(0.5)
                    : Color.clear
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .draggable(DraggableProject(projectID: project.id))
        // Drop eines anderen Projekts → ordnet sich VOR diesem Projekt ein.
        .dropDestination(for: DraggableProject.self) { items, _ in
            guard let dropped = items.first, dropped.projectID != project.id else { return false }
            onProjectDrop(dropped, project.id)
            return true
        } isTargeted: { isProjectDragOver = $0 }
        // Drop einer Session auf den Projekt-Header → an's Ende dieses Projekts
        // (Cross-Project-Move oder Reorder-an-Ende im selben Projekt).
        .dropDestination(for: DraggableSession.self) { items, _ in
            guard let dropped = items.first else { return false }
            onSessionDrop(dropped, nil, project.id)
            return true
        } isTargeted: { isSessionDragOver = $0 }
        .contextMenu {
            Button("Umbenennen…", systemImage: "pencil") {
                onRenameProjectRequest(project)
            }
            Menu("Farbe") {
                ForEach(AgentProjectColor.palette, id: \.self) { color in
                    Button {
                        onSetProjectColor(project.id, color)
                    } label: {
                        Label {
                            Text(AgentChatColorName.label(for: color))
                        } icon: {
                            Image(nsImage: colorSwatchImage(hex: color))
                        }
                    }
                }
            }
            Divider()
            Button("Icon wählen…", systemImage: "photo") {
                onChooseProjectIcon(project)
            }
            Button("Auto-Icon erkennen", systemImage: "sparkles.rectangle.stack") {
                onAutoDetectProjectIcon(project)
            }
            if project.resolvedIconURL != nil
                || project.iconRelativePath != nil
                || project.customIconAbsolutePath != nil {
                Button("Icon entfernen", systemImage: "xmark.circle", role: .destructive) {
                    onClearProjectIcon(project.id)
                }
            }
        }
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
    /// Live-Status der Session, ermittelt vom `AgentSessionRuntimeWatcher`.
    /// `nil` solange die Session nicht läuft oder der Watcher noch keinen
    /// ersten Sample produziert hat — dann fallen wir auf `isRunning` zurück.
    let runtimeStatus: AgentSessionRuntimeStatus?
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovered = false
    @State private var pulsePhase: Bool = false

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
                        // Text dehnt sich über die verbleibende Row-Breite, damit
                        // der Status-/Close-Indicator immer rechts bündig sitzt
                        // und der Hover-Background bis an die Sidebar-Kante reicht.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(session.title)

                    trailingIndicator
                        .frame(width: 18, alignment: .trailing)
                }
                .padding(.leading, 28)
                .padding(.trailing, 8)
            }
            // Volle Sidebar-Breite, damit der Background und die Hit-Area die
            // ganze Row abdecken — sonst klebt der Hover-Hintergrund nur am
            // Text-Inhalt und kurze Chat-Namen sehen abgeschnitten aus.
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
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
        } else {
            statusIndicator
        }
    }

    /// Bildet den Live-Status der Session als kompakte Glyphe ab (5 px). Die
    /// fünf Zustände sind aufsteigend „aufdringlicher" gestaffelt:
    /// idle → unscheinbar grau, working → grün-gepulst, awaitingInput →
    /// orange-gepulst, errored → rot-fest, stopped → versteckt.
    @ViewBuilder
    private var statusIndicator: some View {
        let resolved = resolvedStatus
        switch resolved {
        case .working:
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
                .opacity(pulsePhase ? 1.0 : 0.45)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsePhase)
                .onAppear { pulsePhase = true }
                .help("Arbeitet …")
        case .awaitingInput:
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
                .opacity(pulsePhase ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsePhase)
                .onAppear { pulsePhase = true }
                .help("Wartet möglicherweise auf User-Input")
        case .idle:
            Circle()
                .fill(Color.green.opacity(0.55))
                .frame(width: 5, height: 5)
                .help("Bereit")
        case .errored:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.8))
                .help("Mit Fehler beendet")
        case .stopped, .none:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// Wenn der Watcher noch keinen Status geliefert hat, wir aber wissen, dass
    /// der Process läuft, gehen wir defaultmäßig auf `.working`. Verhindert
    /// einen Glüh-Glitch direkt nach dem Start.
    private var resolvedStatus: AgentSessionRuntimeStatus? {
        if let runtimeStatus { return runtimeStatus }
        return isRunning ? .working : nil
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

/// Sidebar-Avatar eines Projekts. Render-Reihenfolge:
/// 1. User-gewähltes Custom-Icon (`customIconAbsolutePath`)
/// 2. Auto-erkanntes Repo-Icon (`iconRelativePath`)
/// 3. Fallback: farbiges 18×18-Quadrat mit Initial-Buchstaben.
///
/// Das Loading erfolgt synchron via `NSImage(contentsOf:)` — die Files sind
/// in der Regel < 50 KB und liegen lokal. Wird das zum Hotspot, kann hier
/// ein In-Memory-Cache nachgerüstet werden.
private struct ProjectAvatar: View {
    let project: AgentProject
    var size: CGFloat = 18

    var body: some View {
        if let icon = loadedIcon() {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: project.color))
                .frame(width: size, height: size)
                .overlay(
                    Text(project.name.prefix(1).uppercased())
                        .font(.system(size: max(8, size * 0.55), weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    private func loadedIcon() -> NSImage? {
        guard let url = project.resolvedIconURL else { return nil }
        return NSImage(contentsOf: url)
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
        // Dynamischer Background: reagiert auf NSAppearance der Hosting-View,
        // damit der durch `titlebarAppearsTransparent + fullSizeContentView`
        // sichtbare Window-Background nicht im Light-Mode dunkel bleibt.
        window.backgroundColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0.058, green: 0.060, blue: 0.064, alpha: 1)
                : NSColor.white
        }
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
    /// Runtime-Watcher-Hooks. Aufrufer (AgentChatsView) reicht hier Closures
    /// rein, die intern `runtimeWatcher?.watch(...)` etc. aufrufen — so muss
    /// die Detail-View nichts vom Watcher selbst wissen.
    var onSessionLaunched: (UUID) -> Void = { _ in }
    var onSessionTerminated: (UUID, Int32?) -> Void = { _, _ in }
    var onExternalSessionIDBound: (UUID) -> Void = { _ in }
    /// Wird aufgerufen wenn der Detail-View eine inhaltliche Zusammenfassung
    /// der geschlossenen Session generieren möchte. `force == true` bedeutet
    /// "User hat 'Neu generieren' geklickt" — dann auch dann generieren, wenn
    /// schon ein `summary` existiert.
    var onRequestSummary: (UUID, _ force: Bool) -> Void = { _, _ in }
    /// Liefert `true`, solange ein Summary für diese Session aktuell generiert
    /// wird — die UI bindet das auf einen Spinner.
    var isGeneratingSummary: (UUID) -> Bool = { _ in false }

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
                ClosedSessionSummaryView(
                    session: session,
                    errorMessage: errorMessage,
                    isGenerating: isGeneratingSummary(session.id),
                    onGenerate: { force in onRequestSummary(session.id, force) }
                )
            }
        }
        .onAppear {
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
            // Direkt nach dem Mount Tastaturfokus auf das Terminal setzen,
            // damit der User sofort tippen kann und nicht im Sidebar-Filter
            // hängenbleibt. `focusTerminal` is async-dispatched — okay wenn
            // das View jetzt erst mountet.
            controller?.focusTerminal()
            // Beim Öffnen einer geschlossenen Session ohne Summary einmal
            // im Hintergrund anstoßen — der Coordinator (AgentChatsView)
            // entscheidet, ob das tatsächlich ausgeführt wird (in-flight,
            // schon vorhanden, fehlende externalSessionID).
            if controller == nil && session.summary == nil {
                onRequestSummary(session.id, false)
            }
        }
        .onChange(of: session.id) { _, _ in
            errorMessage = nil
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
            // Wechsel zwischen offenen Chats: dem neuen Terminal Fokus geben.
            controller?.focusTerminal()
            if controller == nil && session.summary == nil {
                onRequestSummary(session.id, false)
            }
        }
        .onChange(of: actionRequest) { _, request in
            handleActionRequest(request)
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
                onTerminated: { exitCode in markTerminated(exitCode: exitCode) }
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
            onSessionLaunched(session.id)
            // Erster Start: Terminal-NSView ist jetzt mit dem Window verbunden
            // → Tastaturfokus dorthin, damit der User direkt tippen kann.
            controller?.focusTerminal()
            onStateChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markTerminated(exitCode: Int32?) {
        do {
            try store.updateSession(id: session.id) { updated in
                if updated.status == .running {
                    updated.status = .closed
                }
            }
            onSessionTerminated(session.id, exitCode)
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
                    onExternalSessionIDBound(session.id)
                    onStateChanged()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Detail-View einer geschlossenen / nicht-attached Session. Zeigt eine kurze
/// Headline + ausführliche Beschreibung, statt der bisherigen rein technischen
/// "Session metadata loaded" Hinweise. Resume- und Session-ID-Hinweise bleiben
/// als Footer kleingedruckt erhalten, damit Power-User weiterhin Zugriff
/// haben.
private struct ClosedSessionSummaryView: View {
    let session: AgentChatSession
    let errorMessage: String?
    let isGenerating: Bool
    /// Ruft den Summarizer auf. `force = true` bedeutet "Neu generieren"-Klick;
    /// `false` ist der „passive" Anstoß beim Öffnen.
    var onGenerate: (_ force: Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(12)
                        .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgentTheme.border, lineWidth: 1))
                }

                if let summary = session.summary {
                    summaryBody(summary)
                } else if isGenerating {
                    generatingPlaceholder
                } else {
                    emptyPlaceholder
                }

                technicalFooter
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AgentTheme.background)
    }

    @ViewBuilder
    private func summaryBody(_ summary: AgentSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Text(summary.headline)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                regenerateButton
            }

            Divider().background(AgentTheme.border)

            Text(summary.details)
                .font(.system(size: 13))
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text("Automatisch zusammengefasst · \(relativeDate(summary.generatedAt))")
                    .font(.system(size: 11))
            }
            .foregroundStyle(AgentTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var generatingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Zusammenfassung wird generiert …")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AgentTheme.textPrimary)
            }
            Text("Wir lesen das Transcript dieser Session und fragen \(session.provider.displayName) nach einer kurzen Zusammenfassung. Das dauert in der Regel ein paar Sekunden.")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Noch keine Zusammenfassung verfügbar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
            Text("Wenn diese Session ein vollständiges Transcript bei \(session.provider.displayName) hinterlassen hat, kann WhisperM8 daraus eine kurze Zusammenfassung erzeugen.")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onGenerate(true)
            } label: {
                Label("Zusammenfassung erzeugen", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var regenerateButton: some View {
        if isGenerating {
            ProgressView().controlSize(.small)
        } else {
            Button {
                onGenerate(true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Zusammenfassung neu generieren")
        }
    }

    @ViewBuilder
    private var technicalFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().background(AgentTheme.border)
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Diese Session ist aktuell nicht verbunden. ")
                + Text("Resume").bold()
                + Text(" oben in der Header-Leiste verbindet sie wieder.")
            }
            .font(.system(size: 11))
            .foregroundStyle(AgentTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            if let externalSessionID = session.externalSessionID {
                Text("Session-ID: \(externalSessionID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 12)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
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

/// 22 Theme-Tokens, je in Light- und Dark-Variante. Alle Werte werden über
/// `Color.dynamic(light:dark:)` aufgelöst — der zugrundeliegende
/// `NSColor(name:dynamicProvider:)` liest die aktuelle `NSAppearance` aus
/// der View-Hierarchie, sodass `.preferredColorScheme(.light/.dark)` auf
/// dem Root die Tokens automatisch umschaltet.
private enum AgentTheme {
    // Surfaces: dunkles Off-Black ↔ helles Off-White, mit subtilen Stufen
    // damit Sidebar/Header/Panel/Surface in beiden Modi voneinander abheben.
    // Main content area: pure white im Light (Apple-HIG: main pane ist
    // weiß, Sidebar/Header tinted), Off-Black im Dark.
    static let background = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.058, green: 0.060, blue: 0.064)
    )
    static let sidebar = Color.dynamic(
        light: Color(red: 0.935, green: 0.935, blue: 0.940),
        dark: Color(red: 0.075, green: 0.078, blue: 0.082)
    )
    static let header = Color.dynamic(
        light: Color(red: 0.950, green: 0.950, blue: 0.955),
        dark: Color(red: 0.070, green: 0.072, blue: 0.076)
    )
    static let surface = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.090, green: 0.092, blue: 0.097)
    )
    static let panel = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.105, green: 0.108, blue: 0.114)
    )
    static let control = Color.dynamic(
        light: Color(red: 0.920, green: 0.920, blue: 0.928),
        dark: Color(red: 0.140, green: 0.143, blue: 0.150)
    )

    // Translucent overlays: schwarz auf hell, weiß auf dunkel.
    // (Reine Inversion: gleich aussehende Tiefe in beiden Modi.)
    static let hover = Color.dynamic(
        light: Color.black.opacity(0.045),
        dark: Color.white.opacity(0.04)
    )
    static let selection = Color.dynamic(
        light: Color.black.opacity(0.075),
        dark: Color.white.opacity(0.07)
    )
    static let selectionStrong = Color.dynamic(
        light: Color.black.opacity(0.11),
        dark: Color.white.opacity(0.10)
    )

    static let headerTab = Color.dynamic(
        light: Color(red: 0.928, green: 0.928, blue: 0.936),
        dark: Color(red: 0.080, green: 0.082, blue: 0.086)
    )
    static let tabSelected = Color.dynamic(
        light: Color(red: 1.0, green: 1.0, blue: 1.0),
        dark: Color(red: 0.115, green: 0.118, blue: 0.124)
    )
    static let statusPill = Color.dynamic(
        light: Color(red: 0.985, green: 0.985, blue: 0.990),
        dark: Color(red: 0.050, green: 0.052, blue: 0.055)
    )

    // Hairlines/Connectors: minimaler Kontrast genügt. Im Light leicht
    // sichtbarer (8%) als im Dark (6%), weil schwarze Hairlines auf weiß
    // visuell stärker wirken bei gleicher Opacity wäre zu schwach.
    static let border = Color.dynamic(
        light: Color.black.opacity(0.08),
        dark: Color.white.opacity(0.06)
    )
    static let borderStrong = Color.dynamic(
        light: Color.black.opacity(0.13),
        dark: Color.white.opacity(0.10)
    )
    static let connector = Color.dynamic(
        light: Color.black.opacity(0.11),
        dark: Color.white.opacity(0.10)
    )
    static let connectorActive = Color.dynamic(
        light: Color.black.opacity(0.25),
        dark: Color.white.opacity(0.22)
    )

    // Text: schwarz auf hell, weiß auf dunkel. Opacity-Stufen so dass
    // primary/secondary/tertiary in beiden Modi die gleiche Hierarchie haben.
    static let textPrimary = Color.dynamic(
        light: Color.black.opacity(0.90),
        dark: Color.white.opacity(0.92)
    )
    static let textSecondary = Color.dynamic(
        light: Color.black.opacity(0.58),
        dark: Color.white.opacity(0.55)
    )
    static let textTertiary = Color.dynamic(
        light: Color.black.opacity(0.42),
        dark: Color.white.opacity(0.38)
    )

    // Akzente: gleiches Hue, im Light leicht dunkler für Kontrast auf weiß.
    static let accentDiffPos = Color.dynamic(
        light: Color(red: 0.18, green: 0.62, blue: 0.30),
        dark: Color(red: 0.40, green: 0.85, blue: 0.45)
    )
    static let accentDiffNeg = Color.dynamic(
        light: Color(red: 0.78, green: 0.22, blue: 0.22),
        dark: Color(red: 0.95, green: 0.40, blue: 0.40)
    )
}

private extension Color {
    /// Erzeugt eine Color, deren tatsächlicher Wert zur Render-Zeit anhand
    /// der View-Hierarchie-Appearance entschieden wird. Reicht sowohl für
    /// macOS-System-Theme-Wechsel als auch für `.preferredColorScheme(...)`
    /// Override auf einer Scene.
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
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
