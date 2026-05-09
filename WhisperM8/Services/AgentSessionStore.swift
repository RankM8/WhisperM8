import Foundation

struct AgentSessionStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func loadWorkspace() -> AgentWorkspace {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AgentWorkspace.self, from: data)
        } catch {
            Logger.debug("Failed to load agent sessions: \(error.localizedDescription)")
            return .empty
        }
    }

    func saveWorkspace(_ workspace: AgentWorkspace) throws {
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

    func upsertProject(path: String, name: String? = nil, color: String? = nil) throws -> AgentProject {
        var workspace = loadWorkspace()
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let index = workspace.projects.firstIndex(where: { $0.path == standardizedPath }) {
            workspace.projects[index].updatedAt = Date()
            workspace.projects[index].lastBranch = Self.currentGitBranch(at: standardizedPath)
            try saveWorkspace(workspace)
            return workspace.projects[index]
        }

        let project = AgentProject(
            name: name ?? URL(fileURLWithPath: standardizedPath).lastPathComponent,
            path: standardizedPath,
            color: color ?? AgentProjectColor.palette[workspace.projects.count % AgentProjectColor.palette.count],
            lastBranch: Self.currentGitBranch(at: standardizedPath)
        )
        workspace.projects.append(project)
        try saveWorkspace(workspace)
        return project
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

    func renameSession(id: UUID, title: String) throws {
        try updateSession(id: id) { session in
            session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func setSessionGroup(id: UUID, groupName: String?) throws {
        try updateSession(id: id) { session in
            let normalized = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.groupName = normalized?.isEmpty == false ? normalized : nil
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
        initialPrompt: String? = nil,
        imagePaths: [String] = [],
        shouldLaunchOnOpen: Bool = false
    ) throws -> AgentChatSession {
        let project = try upsertProject(path: projectPath)
        let session = AgentChatSession(
            provider: provider,
            projectID: project.id,
            title: title,
            model: model,
            reasoningEffort: reasoningEffort,
            initialPrompt: initialPrompt,
            imagePaths: imagePaths,
            shouldLaunchOnOpen: shouldLaunchOnOpen
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
        var workspace = loadWorkspace()
        guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }) else {
            return nil
        }

        guard workspace.sessions[index].externalSessionID == nil else {
            return workspace.sessions[index]
        }

        let standardizedPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let createdAt = workspace.sessions[index].createdAt
        guard let indexed = indexedSessions
            .filter({
                $0.provider == provider
                    && URL(fileURLWithPath: $0.cwd).standardizedFileURL.path == standardizedPath
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
        for indexed in indexedSessions {
            let projectPath = URL(fileURLWithPath: indexed.cwd).standardizedFileURL.path
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

struct IndexedAgentSession: Equatable {
    var provider: AgentProvider
    var externalSessionID: String
    var cwd: String
    var title: String
    var model: String?
    var reasoningEffort: String?
    var createdAt: Date
    var lastActivityAt: Date
}
