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
    @State private var sessionActionRequest: AgentSessionActionRequest?
    @StateObject private var terminalRegistry = AgentTerminalRegistry()
    @SceneStorage("agentChatsInspectorVisible") private var isInspectorVisible = false

    private var selectedProject: AgentProject? {
        workspace.projects.first { $0.id == selectedProjectID } ?? workspace.projects.first
    }

    private var projectSessions: [AgentChatSession] {
        guard let selectedProject else { return [] }
        return sessions(for: selectedProject)
    }

    private var selectedSession: AgentChatSession? {
        projectSessions.first { $0.id == selectedSessionID } ?? projectSessions.first
    }

    private var visibleProjects: [AgentProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspace.projects }
        return workspace.projects.filter { project in
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
        terminalRegistry.runningControllers.compactMap { controller in
            guard let session = workspace.sessions.first(where: { $0.id == controller.sessionID }),
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
                rootProcessID: controller.processID
            )
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            hashboardSidebar
                .frame(width: 276)

            Divider()

            mainWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isInspectorVisible {
                Divider()

                ProjectDetailPanel(
                    project: selectedProject,
                    session: selectedSession,
                    sessions: projectSessions,
                    onRefresh: refresh,
                    onNewCodexChat: { createSession(provider: .codex) },
                    onNewClaudeChat: { createSession(provider: .claude) },
                    onOpenPHPStorm: openSelectedProjectInPHPStorm
                )
                .frame(width: 292)
            }
        }
        .frame(minWidth: isInspectorVisible ? 1180 : 920, minHeight: 720)
        .background(AgentTheme.background)
        .onAppear(perform: refresh)
    }

    private var hashboardSidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    sidebarCommandRows

                    HStack(spacing: 8) {
                        Text("PROJECTS · \(visibleProjects.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            if expandedProjectIDs.count == workspace.projects.count {
                                expandedProjectIDs.removeAll()
                            } else {
                                expandedProjectIDs = Set(workspace.projects.map(\.id))
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(expandedProjectIDs.count == workspace.projects.count ? 180 : 0))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Projektgruppen auf-/zuklappen")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

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
                                AppPreferences.shared.agentDefaultProjectPath = project.path
                            },
                            onNewChat: {
                                selectedProjectID = project.id
                                expandedProjectIDs.insert(project.id)
                                createSession(provider: .codex)
                            },
                            onRename: renameSession,
                            onSetGroup: setSessionGroup,
                            onSetColor: setSessionColor,
                            onMove: moveSession
                        )
                    }
                }
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 10) {
                Button {
                    addProject()
                } label: {
                    Label("Projekt hinzufügen", systemImage: "plus")
                }

                Spacer()

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Sessions aktualisieren")
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .padding(12)
        }
        .background(AgentTheme.sidebar)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .overlay(Text("W8").font(.caption.weight(.bold)).foregroundStyle(.white))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Hashboard")
                        .font(.headline.weight(.semibold))
                    Text("Agent Chats")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                AgentResourceSummaryButton(descriptors: runningResourceDescriptors)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter projects, chats...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgentTheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var sidebarCommandRows: some View {
        VStack(spacing: 4) {
            Button {
                createSession(provider: .codex)
            } label: {
                SidebarCommandRow(icon: "square.and.pencil", title: "Neuer Codex Chat")
            }
            .disabled(selectedProject == nil)

            Button {
                refresh()
            } label: {
                SidebarCommandRow(icon: "magnifyingglass", title: "Sessions scannen")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private var mainWorkspace: some View {
        VStack(spacing: 0) {
            projectChatStrip

            Divider()

            if let selectedProject, let selectedSession {
                AgentSessionDetailView(
                    project: selectedProject,
                    session: selectedSession,
                    terminalRegistry: terminalRegistry,
                    actionRequest: sessionActionRequest,
                    onStateChanged: refresh
                )
            } else {
                ContentUnavailableView("Kein Agent Chat", systemImage: "terminal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AgentTheme.background)
    }

    private var projectChatStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let selectedProject {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(hex: selectedProject.color))
                        .frame(width: 34, height: 34)
                        .overlay(Text(selectedProject.name.prefix(1)).font(.headline.weight(.bold)).foregroundStyle(.white))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(selectedProject?.name ?? "Kein Projekt")
                            .font(.headline.weight(.semibold))
                        Label(selectedProject?.lastBranch ?? "local", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(selectedProject?.path ?? "Projekt auswählen oder hinzufügen")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let selectedSession {
                    selectedSessionHeaderControls(selectedSession)
                }

                if selectedProject != nil {
                    Button {
                        openSelectedProjectInPHPStorm()
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .frame(width: 28, height: 28)
                            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("PHPStorm öffnen")
                }

                Button {
                    isInspectorVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .frame(width: 28, height: 28)
                        .background(isInspectorVisible ? AgentTheme.selection : AgentTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(isInspectorVisible ? "Projekt-Kontext ausblenden" : "Projekt-Kontext anzeigen")

                Menu {
                    Button("Neuer Codex Chat") { createSession(provider: .codex) }
                    Button("Neuer Claude Chat") { createSession(provider: .claude) }
                } label: {
                    Label("Chat", systemImage: "plus")
                }
                .disabled(selectedProject == nil)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 11)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(projectSessions) { session in
                        ChatTabButton(
                            session: session,
                            isSelected: session.id == selectedSession?.id
                        ) {
                            selectedSessionID = session.id
                        }
                        .contextMenu {
                            sessionManagementMenu(session)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
        }
        .background(AgentTheme.surface)
    }

    private func selectedSessionHeaderControls(_ session: AgentChatSession) -> some View {
        let controller = terminalRegistry.controller(for: session.id)
        let isRunning = controller?.isRunning == true

        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: session.provider.systemImage)
                    .foregroundStyle(Color(hex: AgentChatColor.fallback(for: session)))
                Text(session.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(isRunning ? "Running" : session.status.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isRunning ? .green : .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 260)

            Text(session.runtimeDisplayText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 6))

            Button {
                sessionActionRequest = AgentSessionActionRequest(
                    sessionID: session.id,
                    kind: isRunning ? .restart : .start
                )
            } label: {
                Label(isRunning ? "Restart" : (session.externalSessionID == nil ? "Start" : "Resume"), systemImage: isRunning ? "arrow.clockwise" : "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 7))

            Menu {
                Button(isRunning ? "Restart" : (session.externalSessionID == nil ? "Start Terminal" : "Resume Terminal"), systemImage: isRunning ? "arrow.clockwise" : "play.fill") {
                    sessionActionRequest = AgentSessionActionRequest(
                        sessionID: session.id,
                        kind: isRunning ? .restart : .start
                    )
                }
                Button("Close Terminal", systemImage: "xmark.circle") {
                    markSession(session.id, status: .closed)
                }
                .disabled(controller == nil)
                Button("Archive", systemImage: "archivebox", role: .destructive) {
                    markSession(session.id, status: .archived)
                }
                Divider()
                Button("In Work gruppieren") { setSessionGroup(id: session.id, groupName: "Work") }
                Button("In Research gruppieren") { setSessionGroup(id: session.id, groupName: "Research") }
                Button("Gruppe entfernen") { setSessionGroup(id: session.id, groupName: nil) }
                Divider()
                Menu("Tab-Farbe") {
                    ForEach(AgentChatColor.palette, id: \.self) { color in
                        Button(color) { setSessionColor(id: session.id, color: color) }
                    }
                    Button("Provider-Farbe verwenden") { setSessionColor(id: session.id, color: nil) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
                    .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 7))
            }
            .menuStyle(.borderlessButton)
            .help("Chat-Aktionen")
        }
    }

    private func refresh() {
        do {
            try store.markStaleRunningSessionsClosed(excluding: terminalRegistry.activeSessionIDs)
            try store.mergeIndexedSessions(
                CodexSessionIndexer().indexedSessions()
                    + ClaudeSessionIndexer().indexedSessions()
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        workspace = store.loadWorkspace()
        if workspace.projects.isEmpty {
            do {
                _ = try store.upsertProject(path: AppPreferences.shared.agentDefaultProjectPath)
                workspace = store.loadWorkspace()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

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
    }

    private func sessions(for project: AgentProject) -> [AgentChatSession] {
        AgentSessionStore.sortedSessions(
            workspace.sessions
                .filter { $0.projectID == project.id && $0.status != .archived }
        )
    }

    private func selectProject(_ projectID: UUID) {
        selectedProjectID = projectID
        expandedProjectIDs.insert(projectID)
        let sessions = workspace.sessions
            .filter { $0.projectID == projectID && $0.status != .archived }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        selectedSessionID = sessions.first?.id
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
                let project = try store.upsertProject(path: url.path)
                workspace = store.loadWorkspace()
                selectedProjectID = project.id
                selectedSessionID = sessions(for: project).first?.id
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
        Button("Nach oben") { moveSession(id: session.id, direction: .up) }
        Button("Nach unten") { moveSession(id: session.id, direction: .down) }
        Divider()
        Button("In Work gruppieren") { setSessionGroup(id: session.id, groupName: "Work") }
        Button("In Research gruppieren") { setSessionGroup(id: session.id, groupName: "Research") }
        Button("Gruppe entfernen") { setSessionGroup(id: session.id, groupName: nil) }
        Divider()
        Menu("Tab-Farbe") {
            ForEach(AgentChatColor.palette, id: \.self) { color in
                Button {
                    setSessionColor(id: session.id, color: color)
                } label: {
                    Label(color, systemImage: "circle.fill")
                }
            }
            Button("Provider-Farbe verwenden") { setSessionColor(id: session.id, color: nil) }
        }
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

    var body: some View {
        Button {
            refresh()
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "memorychip")
                Text(summaryText)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(snapshot.runningSessionCount > 0 ? .primary : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Session-Ressourcen anzeigen")
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

    private var summaryText: String {
        guard snapshot.runningSessionCount > 0 else { return "0 running" }
        return "\(snapshot.runningSessionCount) running · \(AgentResourceFormat.cpu(snapshot.totalCPUPercent)) · \(AgentResourceFormat.memory(snapshot.totalMemoryBytes))"
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
                        Image(systemName: session.provider.systemImage)
                            .foregroundStyle(Color(hex: session.provider == .codex ? "#32D74B" : "#FF9F0A"))
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
    var onRename: (UUID, String) -> Void
    var onSetGroup: (UUID, String?) -> Void
    var onSetColor: (UUID, String?) -> Void
    var onMove: (UUID, AgentSessionMoveDirection) -> Void

    private var isSelected: Bool {
        selectedProjectID == project.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: onToggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)

                Button(action: onSelectProject) {
                    projectHeader
                }
                .buttonStyle(.plain)

                Button(action: onNewChat) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 25, height: 25)
                        .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Neuen Codex Chat im Projekt starten")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? AgentTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))

            if isExpanded {
                ForEach(groupedSessions.prefix(8), id: \.name) { group in
                    if group.name != nil {
                        Text(group.name ?? "")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 42)
                            .padding(.top, 4)
                    }

                    ForEach(group.sessions.prefix(10)) { session in
                        SessionListButton(
                            session: session,
                            isSelected: selectedSessionID == session.id,
                            relativeTime: relativeTime(session.lastActivityAt),
                            onSelect: { onSelectSession(session.id) }
                        )
                        .contextMenu {
                            Button("Nach oben") { onMove(session.id, .up) }
                            Button("Nach unten") { onMove(session.id, .down) }
                            Divider()
                            Button("In Work gruppieren") { onSetGroup(session.id, "Work") }
                            Button("In Research gruppieren") { onSetGroup(session.id, "Research") }
                            Button("Gruppe entfernen") { onSetGroup(session.id, nil) }
                            Divider()
                            Menu("Tab-Farbe") {
                                ForEach(AgentChatColor.palette, id: \.self) { color in
                                    Button(color) { onSetColor(session.id, color) }
                                }
                                Button("Provider-Farbe verwenden") { onSetColor(session.id, nil) }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var projectHeader: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(hex: project.color))
                .frame(width: 28, height: 28)
                .overlay(Text(project.name.prefix(1)).font(.callout.weight(.bold)).foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Label(project.lastBranch ?? "local", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(sessions.count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(AgentTheme.control, in: RoundedRectangle(cornerRadius: 5))
        }
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
    let relativeTime: String
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: AgentChatColor.fallback(for: session)))
                    .frame(width: 3, height: 18)

                Image(systemName: session.provider.systemImage)
                    .font(.caption)
                    .foregroundStyle(Color(hex: AgentChatColor.fallback(for: session)))
                    .frame(width: 14)

                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)

                Spacer()

                if session.status == .running {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                } else if session.status == .closed {
                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.status.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor(session.status))
                }
            }
            .padding(.leading, 36)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? AgentTheme.selection.opacity(0.95) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: AgentChatStatus) -> Color {
        switch status {
        case .pending:
            return .yellow
        case .running:
            return .green
        case .closed:
            return .secondary
        case .archived:
            return .secondary
        }
    }
}

private struct SidebarCommandRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ChatTabButton: View {
    let session: AgentChatSession
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(hex: AgentChatColor.fallback(for: session)))
                    .frame(height: isSelected ? 3 : 2)
                    .opacity(isSelected ? 1 : 0.75)

                HStack(spacing: 8) {
                    Image(systemName: session.provider.systemImage)
                        .font(.caption)
                        .foregroundStyle(Color(hex: AgentChatColor.fallback(for: session)))
                    Text(session.title)
                        .lineLimit(1)

                    if session.status == .running {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    } else {
                        Text(session.status.displayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: 240)
            .background(isSelected ? AgentTheme.selection : AgentTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color(hex: AgentChatColor.fallback(for: session)).opacity(0.7) : AgentTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                        Image(systemName: session.provider.systemImage)
                            .foregroundStyle(Color(hex: AgentChatColor.fallback(for: session)))
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
                .background(Color.black)
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
            Color.black

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
    static let background = Color(nsColor: NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.075, alpha: 1))
    static let sidebar = Color(nsColor: NSColor(calibratedRed: 0.10, green: 0.115, blue: 0.12, alpha: 1))
    static let surface = Color(nsColor: NSColor(calibratedRed: 0.095, green: 0.10, blue: 0.105, alpha: 1))
    static let panel = Color(nsColor: NSColor(calibratedRed: 0.13, green: 0.135, blue: 0.14, alpha: 1))
    static let control = Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.185, blue: 0.195, alpha: 1))
    static let selection = Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.225, blue: 0.235, alpha: 1))
    static let border = Color.white.opacity(0.08)
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
