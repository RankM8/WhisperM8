import AppKit
import SwiftUI

struct AgentChatsView: View {
    @State private var store = AgentSessionStore()
    @State private var workspace = AgentWorkspace.empty
    @State private var selectedProjectID: UUID?
    @State private var selectedSessionID: UUID?
    @State private var errorMessage: String?
    @StateObject private var terminalRegistry = AgentTerminalRegistry()

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

    var body: some View {
        HStack(spacing: 0) {
            hashboardSidebar
                .frame(width: 276)

            Divider()

            mainWorkspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .frame(minWidth: 1180, minHeight: 720)
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

                    Text("Projekte")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)

                    ForEach(workspace.projects) { project in
                        ProjectChatGroup(
                            project: project,
                            sessions: sessions(for: project),
                            selectedProjectID: selectedProjectID,
                            selectedSessionID: selectedSessionID,
                            onSelectProject: {
                                selectProject(project.id)
                            },
                            onSelectSession: { sessionID in
                                selectedProjectID = project.id
                                selectedSessionID = sessionID
                                AppPreferences.shared.agentDefaultProjectPath = project.path
                            },
                            onNewChat: {
                                selectedProjectID = project.id
                                createSession(provider: .codex)
                            },
                            onRename: renameSession,
                            onSetGroup: setSessionGroup,
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
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor)
                .frame(width: 22, height: 22)
                .overlay(Text("#").font(.caption.weight(.bold)).foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 1) {
                Text("Hashboard")
                    .font(.headline.weight(.semibold))
                Text("Agent Chats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
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
                    onClose: { markSession(selectedSession.id, status: .closed) },
                    onArchive: { markSession(selectedSession.id, status: .archived) },
                    onRelaunch: { relaunch(selectedSession.id) },
                    onRename: renameSession,
                    onSetGroup: setSessionGroup,
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedProject?.name ?? "Kein Projekt")
                        .font(.headline.weight(.semibold))
                    Text(selectedProject?.path ?? "Projekt auswählen oder hinzufügen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Menu {
                    Button("Neuer Codex Chat") { createSession(provider: .codex) }
                    Button("Neuer Claude Chat") { createSession(provider: .claude) }
                } label: {
                    Label("Chat", systemImage: "plus")
                }
                .disabled(selectedProject == nil)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

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
        let sessions = workspace.sessions
            .filter { $0.projectID == projectID && $0.status != .archived }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        selectedSessionID = sessions.first?.id
        if let project = workspace.projects.first(where: { $0.id == projectID }) {
            AppPreferences.shared.agentDefaultProjectPath = project.path
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
                shouldLaunchOnOpen: true
            )
            workspace = store.loadWorkspace()
            selectedSessionID = session.id
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

private struct ProjectChatGroup: View {
    let project: AgentProject
    let sessions: [AgentChatSession]
    let selectedProjectID: UUID?
    let selectedSessionID: UUID?
    var onSelectProject: () -> Void
    var onSelectSession: (UUID) -> Void
    var onNewChat: () -> Void
    var onRename: (UUID, String) -> Void
    var onSetGroup: (UUID, String?) -> Void
    var onMove: (UUID, AgentSessionMoveDirection) -> Void

    private var isSelected: Bool {
        selectedProjectID == project.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onSelectProject) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: project.color))
                        .frame(width: 19, height: 19)
                        .overlay(Text(project.name.prefix(1)).font(.caption2.weight(.bold)).foregroundStyle(.white))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(project.lastBranch ?? "local")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(sessions.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(action: onNewChat) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Neuen Codex Chat im Projekt starten")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(isSelected ? AgentTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            ForEach(groupedSessions.prefix(6), id: \.name) { group in
                if group.name != nil {
                    Text(group.name ?? "")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                        .padding(.top, 4)
                }

                ForEach(group.sessions.prefix(8)) { session in
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
                    }
                }
            }
        }
        .padding(.horizontal, 8)
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
                Image(systemName: session.provider.systemImage)
                    .font(.caption)
                    .foregroundStyle(session.provider == .codex ? .green : .orange)
                    .frame(width: 14)

                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)

                Spacer()

                if session.status == .running {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                } else {
                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 34)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? AgentTheme.selection.opacity(0.95) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 7) {
                Image(systemName: session.provider.systemImage)
                    .font(.caption)
                    .foregroundStyle(session.provider == .codex ? .green : .orange)
                Text(session.title)
                    .lineLimit(1)
                Text(session.status.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: 220)
            .background(isSelected ? AgentTheme.selection : AgentTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : AgentTheme.border, lineWidth: 1)
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
                Text("Projekt")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    refreshPanel()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
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
    var onClose: () -> Void
    var onArchive: () -> Void
    var onRelaunch: () -> Void
    var onRename: (UUID, String) -> Void
    var onSetGroup: (UUID, String?) -> Void
    var onStateChanged: () -> Void

    @State private var store = AgentSessionStore()
    @State private var errorMessage: String?
    @State private var editableTitle: String = ""
    @State private var editableGroup: String = ""

    private var controller: AgentTerminalController? {
        terminalRegistry.controller(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if let controller {
                AgentTerminalView(controller: controller)
                .background(Color.black)
            } else {
                inactiveSessionPreview
            }
        }
        .onAppear {
            editableTitle = session.title
            editableGroup = session.groupName ?? ""
            if session.shouldLaunchOnOpen == true {
                prepareCommand()
            }
        }
        .onChange(of: session.id) { _, _ in
            errorMessage = nil
            editableTitle = session.title
            editableGroup = session.groupName ?? ""
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: session.provider.systemImage)
                .foregroundStyle(session.provider == .codex ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.headline)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            Text(session.model)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(controller == nil ? "Start Terminal" : "Restart", action: prepareCommand)
            Button("Close Terminal", action: closeTerminal)
            Button("Archive", role: .destructive, action: onArchive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AgentTheme.surface)
    }

    private var inactiveSessionPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(12)
                    .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Nicht gestartet")
                    .font(.title3.weight(.semibold))
                Text("Metadaten sind geladen, aber kein Codex-/Claude-Prozess läuft. Starte oder resume den Chat nur, wenn du ihn wirklich brauchst.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    prepareCommand()
                } label: {
                    Label(session.externalSessionID == nil ? "Chat starten" : "Chat resumen", systemImage: "play.fill")
                }
                .controlSize(.large)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgentTheme.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                Text("Verwalten")
                    .font(.headline)

                HStack {
                    TextField("Chat-Name", text: $editableTitle)
                        .textFieldStyle(.roundedBorder)
                    Button("Umbenennen") {
                        onRename(session.id, editableTitle)
                    }
                    .disabled(editableTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack {
                    TextField("Gruppe, z. B. Research", text: $editableGroup)
                        .textFieldStyle(.roundedBorder)
                    Button("Gruppe setzen") {
                        onSetGroup(session.id, editableGroup)
                    }
                    Button("Entfernen") {
                        editableGroup = ""
                        onSetGroup(session.id, nil)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgentTheme.border, lineWidth: 1))

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private func closeTerminal() {
        terminalRegistry.terminate(sessionID: session.id)
        onClose()
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
