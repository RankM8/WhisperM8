import Foundation

struct AgentSessionStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func loadWorkspace() -> AgentWorkspace {
        let startedAt = Date()
        defer {
            Logger.agentPerformance.debug("agent_store_load durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let workspace = try decoder.decode(AgentWorkspace.self, from: data)
            let migrated = Self.migratedWorkspace(workspace)
            if migrated != workspace {
                try? saveWorkspace(migrated)
            }
            return migrated
        } catch {
            Logger.debug("Failed to load agent sessions: \(error.localizedDescription)")
            return .empty
        }
    }

    func saveWorkspace(_ workspace: AgentWorkspace) throws {
        let startedAt = Date()
        defer {
            Logger.agentPerformance.debug("agent_store_save durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) projects=\(workspace.projects.count) sessions=\(workspace.sessions.count)")
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(workspace)
        try data.write(to: fileURL, options: .atomic)
    }

    func upsertProject(path: String, name: String? = nil, color: String? = nil, createdManually: Bool = false) throws -> AgentProject {
        var workspace = loadWorkspace()
        let standardizedPath = Self.canonicalProjectPath(path)
        if let index = workspace.projects.firstIndex(where: { $0.path == standardizedPath }) {
            workspace.projects[index].updatedAt = Date()
            workspace.projects[index].lastBranch = Self.currentGitBranch(at: standardizedPath)
            if createdManually {
                workspace.projects[index].createdManually = true
            }
            try saveWorkspace(workspace)
            return workspace.projects[index]
        }

        let project = AgentProject(
            name: name ?? URL(fileURLWithPath: standardizedPath).lastPathComponent,
            path: standardizedPath,
            color: color ?? AgentProjectColor.palette[workspace.projects.count % AgentProjectColor.palette.count],
            lastBranch: Self.currentGitBranch(at: standardizedPath),
            createdManually: createdManually ? true : nil
        )
        workspace.projects.append(project)
        try saveWorkspace(workspace)
        return project
    }

    // MARK: - Project metadata mutators

    /// Generic Mutator analog zu `updateSession` — bewusst nicht `inout`-Closure
    /// Capture, damit der Aufrufer den Update als `(inout AgentProject) -> Void`
    /// reichen kann.
    func updateProject(id: UUID, _ update: (inout AgentProject) -> Void) throws {
        var workspace = loadWorkspace()
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
        update(&workspace.projects[index])
        workspace.projects[index].updatedAt = Date()
        try saveWorkspace(workspace)
    }

    func renameProject(id: UUID, name: String) throws {
        try updateProject(id: id) { project in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            project.name = trimmed
        }
    }

    func setProjectColor(id: UUID, color: String) throws {
        try updateProject(id: id) { project in
            let trimmed = color.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            project.color = trimmed
        }
    }

    /// Vom User explizit ausgewähltes Icon (File-Picker auf ein Bild beliebiger
    /// Lage). Hat Vorrang vor `iconRelativePath`.
    func setProjectCustomIcon(id: UUID, absolutePath: String?) throws {
        try updateProject(id: id) { project in
            let trimmed = absolutePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            project.customIconAbsolutePath = (trimmed?.isEmpty == false) ? trimmed : nil
        }
    }

    /// Vom Auto-Resolver gefundenes Icon im Projekt-Repo. `relativePath = nil`
    /// markiert nur, dass der Lookup gelaufen ist, aber nichts gefunden wurde —
    /// damit der nächste Workspace-Reload nicht erneut scannt.
    func applyAutoResolvedProjectIcon(id: UUID, relativePath: String?) throws {
        try updateProject(id: id) { project in
            project.iconRelativePath = relativePath
            project.iconAutoLookupAttempted = true
        }
    }

    /// Setzt den Lookup-Status zurück und entfernt beide Icon-Slots — Trigger
    /// für "Auto-Icon erneut erkennen".
    func clearProjectIcon(id: UUID) throws {
        try updateProject(id: id) { project in
            project.iconRelativePath = nil
            project.customIconAbsolutePath = nil
            project.iconAutoLookupAttempted = nil
        }
    }

    func upsertSession(_ session: AgentChatSession) throws -> AgentChatSession {
        var workspace = loadWorkspace()
        if let index = workspace.sessions.firstIndex(where: { $0.id == session.id }) {
            workspace.sessions[index] = session
        } else {
            workspace.sessions.append(session)
        }
        try saveWorkspace(workspace)
        return session
    }

    func updateSession(id: UUID, _ update: (inout AgentChatSession) -> Void) throws {
        var workspace = loadWorkspace()
        guard let index = workspace.sessions.firstIndex(where: { $0.id == id }) else { return }
        update(&workspace.sessions[index])
        workspace.sessions[index].lastActivityAt = Date()
        try saveWorkspace(workspace)
    }

    /// Manuelle Umbenennung durch den Nutzer. Setzt `titleIsAutoGenerated = false`,
    /// damit der Auto-Namer den Namen nie wieder überschreibt.
    func renameSession(id: UUID, title: String) throws {
        try updateSession(id: id) { session in
            session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            session.titleIsAutoGenerated = false
        }
    }

    /// Automatische Umbenennung durch den Auto-Namer. Wird nur ausgeführt, wenn
    /// die Session laut `canAutoRenameTitle` für Auto-Rename freigegeben ist —
    /// sonst no-op. Setzt `titleIsAutoGenerated = true`.
    func applyAutoGeneratedTitle(id: UUID, title: String) throws {
        try updateSession(id: id) { session in
            guard session.canAutoRenameTitle else { return }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            session.title = trimmed
            session.titleIsAutoGenerated = true
        }
    }

    /// Vom Runtime-Watcher beim Erkennen eines abgeschlossenen Agent-Turns gesetzt.
    /// Dient dem Auto-Namer als Vorbedingung („mindestens ein Turn ist gelaufen").
    func recordTurnEnded(id: UUID, at date: Date = Date()) throws {
        try updateSession(id: id) { session in
            session.lastTurnAt = date
        }
    }

    /// Vom `AgentSessionSummarizer` nach erfolgreicher Headless-Generierung
    /// aufgerufen. Setzt `summary` ohne andere Felder zu berühren.
    func setSessionSummary(id: UUID, summary: AgentSessionSummary?) throws {
        try updateSession(id: id) { session in
            session.summary = summary
        }
    }

    func setSessionGroup(id: UUID, groupName: String?) throws {
        try updateSession(id: id) { session in
            let normalized = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.groupName = normalized?.isEmpty == false ? normalized : nil
        }
    }

    func setSessionColor(id: UUID, color: String?) throws {
        try updateSession(id: id) { session in
            let normalized = color?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.color = normalized?.isEmpty == false ? normalized : nil
        }
    }

    func moveSession(id: UUID, direction: AgentSessionMoveDirection) throws {
        var workspace = loadWorkspace()
        guard let current = workspace.sessions.first(where: { $0.id == id }) else { return }
        let sorted = Self.sortedSessions(
            workspace.sessions.filter { $0.projectID == current.projectID && $0.status != .archived }
        )
        guard let currentSortedIndex = sorted.firstIndex(where: { $0.id == id }) else { return }

        let targetSortedIndex: Int
        switch direction {
        case .up:
            targetSortedIndex = max(0, currentSortedIndex - 1)
        case .down:
            targetSortedIndex = min(sorted.count - 1, currentSortedIndex + 1)
        }
        guard targetSortedIndex != currentSortedIndex else { return }

        var reordered = sorted
        reordered.swapAt(currentSortedIndex, targetSortedIndex)
        for (index, session) in reordered.enumerated() {
            if let workspaceIndex = workspace.sessions.firstIndex(where: { $0.id == session.id }) {
                workspace.sessions[workspaceIndex].sortIndex = index
                workspace.sessions[workspaceIndex].lastActivityAt = Date()
            }
        }
        try saveWorkspace(workspace)
    }

    func markStaleRunningSessionsClosed(excluding activeSessionIDs: Set<UUID> = []) throws {
        var workspace = loadWorkspace()
        var changed = false
        for index in workspace.sessions.indices where workspace.sessions[index].status == .running {
            guard workspace.sessions[index].shouldLaunchOnOpen != true else { continue }
            guard !activeSessionIDs.contains(workspace.sessions[index].id) else { continue }
            workspace.sessions[index].status = .closed
            changed = true
        }
        if changed {
            try saveWorkspace(workspace)
        }
    }

    @discardableResult
    func createSession(
        provider: AgentProvider,
        projectPath: String,
        title: String,
        model: String = AppPreferences.shared.codexPostProcessingModelRaw,
        reasoningEffort: String = AppPreferences.shared.codexReasoningEffortRaw,
        externalSessionID: String? = nil,
        initialPrompt: String? = nil,
        imagePaths: [String] = [],
        shouldLaunchOnOpen: Bool = false,
        createdManually: Bool = true
    ) throws -> AgentChatSession {
        let project = try upsertProject(path: projectPath, createdManually: createdManually)
        let session = AgentChatSession(
            provider: provider,
            projectID: project.id,
            externalSessionID: externalSessionID,
            title: title,
            model: model,
            reasoningEffort: reasoningEffort,
            initialPrompt: initialPrompt,
            imagePaths: imagePaths,
            shouldLaunchOnOpen: shouldLaunchOnOpen,
            createdManually: createdManually ? true : nil
        )
        return try upsertSession(session)
    }

    @discardableResult
    func bindLatestIndexedSession(
        localSessionID: UUID,
        provider: AgentProvider,
        projectPath: String,
        indexedSessions: [IndexedAgentSession]
    ) throws -> AgentChatSession? {
        guard !Self.isClaudeWorktreePath(projectPath) else { return nil }
        var workspace = loadWorkspace()
        guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }) else {
            return nil
        }

        guard workspace.sessions[index].externalSessionID == nil else {
            return workspace.sessions[index]
        }

        let standardizedPath = Self.canonicalProjectPath(projectPath)
        let createdAt = workspace.sessions[index].createdAt
        guard let indexed = indexedSessions
            .filter({
                $0.provider == provider
                    && !Self.isClaudeWorktreePath($0.cwd)
                    && Self.canonicalProjectPath($0.cwd) == standardizedPath
                    && $0.createdAt >= createdAt.addingTimeInterval(-5)
            })
            .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
            .first
        else {
            return nil
        }

        workspace.sessions[index].externalSessionID = indexed.externalSessionID
        workspace.sessions[index].lastActivityAt = max(indexed.lastActivityAt, workspace.sessions[index].lastActivityAt)
        if workspace.sessions[index].title.hasSuffix(" Chat") || workspace.sessions[index].title.isEmpty {
            workspace.sessions[index].title = indexed.title
        }
        try saveWorkspace(workspace)
        return workspace.sessions[index]
    }

    func mergeIndexedSessions(_ indexedSessions: [IndexedAgentSession]) throws {
        var workspace = loadWorkspace()
        Self.removeClaudeWorktreeProjectsAndSessions(from: &workspace)
        Self.removeUnresumableClaudeSessions(from: &workspace)
        for indexed in indexedSessions {
            guard !Self.isClaudeWorktreePath(indexed.cwd) else { continue }
            let projectPath = Self.canonicalProjectPath(indexed.cwd)
            let project: AgentProject
            if let existingProject = workspace.projects.first(where: { $0.path == projectPath }) {
                project = existingProject
            } else {
                project = AgentProject(
                    name: URL(fileURLWithPath: projectPath).lastPathComponent,
                    path: projectPath,
                    color: AgentProjectColor.palette[workspace.projects.count % AgentProjectColor.palette.count],
                    lastBranch: Self.currentGitBranch(at: projectPath)
                )
                workspace.projects.append(project)
            }

            if let index = workspace.sessions.firstIndex(where: { $0.provider == indexed.provider && $0.externalSessionID == indexed.externalSessionID }) {
                workspace.sessions[index].projectID = project.id
                workspace.sessions[index].lastActivityAt = indexed.lastActivityAt
                if workspace.sessions[index].title.isEmpty {
                    workspace.sessions[index].title = indexed.title
                }
            } else if let index = workspace.sessions.firstIndex(where: {
                $0.provider == indexed.provider
                    && $0.externalSessionID == nil
                    && $0.projectID == project.id
                    && $0.hasLaunchedInitialPrompt
                    && $0.createdAt <= indexed.createdAt.addingTimeInterval(5)
                    && indexed.createdAt >= $0.createdAt.addingTimeInterval(-5)
            }) {
                workspace.sessions[index].externalSessionID = indexed.externalSessionID
                workspace.sessions[index].lastActivityAt = max(indexed.lastActivityAt, workspace.sessions[index].lastActivityAt)
                if workspace.sessions[index].title.hasSuffix(" Chat") || workspace.sessions[index].title.isEmpty {
                    workspace.sessions[index].title = indexed.title
                }
            } else {
                workspace.sessions.append(
                    AgentChatSession(
                        provider: indexed.provider,
                        projectID: project.id,
                        externalSessionID: indexed.externalSessionID,
                        title: indexed.title,
                        model: indexed.model ?? AppPreferences.shared.codexPostProcessingModelRaw,
                        reasoningEffort: indexed.reasoningEffort ?? AppPreferences.shared.codexReasoningEffortRaw,
                        status: .closed,
                        hasLaunchedInitialPrompt: true,
                        createdAt: indexed.createdAt,
                        lastActivityAt: indexed.lastActivityAt
                    )
                )
            }
        }
        Self.removeClaudeWorktreeProjectsAndSessions(from: &workspace)
        Self.removeUnresumableClaudeSessions(from: &workspace)
        try saveWorkspace(workspace)
    }

    static func sortedSessions(_ sessions: [AgentChatSession]) -> [AgentChatSession] {
        sessions.sorted { lhs, rhs in
            switch (lhs.sortIndex, rhs.sortIndex) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
        }
    }

    private static func currentGitBranch(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "branch", "--show-current"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return branch?.isEmpty == false ? branch : nil
        } catch {
            return nil
        }
    }

    static func canonicalProjectPath(_ path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let marker = "/.claude/worktrees/"
        guard let range = standardizedPath.range(of: marker) else {
            return standardizedPath
        }
        return String(standardizedPath[..<range.lowerBound])
    }

    static func isClaudeWorktreePath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.contains("/.claude/worktrees/")
    }

    private static func removeClaudeWorktreeProjectsAndSessions(from workspace: inout AgentWorkspace) {
        let worktreeProjectIDs = Set(
            workspace.projects
                .filter { isClaudeWorktreePath($0.path) }
                .map(\.id)
        )
        guard !worktreeProjectIDs.isEmpty else {
            return
        }

        workspace.sessions.removeAll { worktreeProjectIDs.contains($0.projectID) }
        workspace.projects.removeAll { worktreeProjectIDs.contains($0.id) }
    }

    private static func removeUnresumableClaudeSessions(from workspace: inout AgentWorkspace) {
        workspace.sessions.removeAll { session in
            session.provider == .claude
                && session.hasLaunchedInitialPrompt
                && session.externalSessionID == nil
                && session.initialPrompt == nil
        }
    }

    private static func migratedWorkspace(_ workspace: AgentWorkspace) -> AgentWorkspace {
        var migrated = workspace
        removeClaudeWorktreeProjectsAndSessions(from: &migrated)
        removeUnresumableClaudeSessions(from: &migrated)
        return migrated
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("AgentSessions.json")
    }
}

enum AgentSessionMoveDirection {
    case up
    case down
}

struct IndexedAgentSession: Codable, Equatable {
    var provider: AgentProvider
    var externalSessionID: String
    var cwd: String
    var title: String
    var model: String?
    var reasoningEffort: String?
    var createdAt: Date
    var lastActivityAt: Date
}
