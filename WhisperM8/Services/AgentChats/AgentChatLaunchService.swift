import Foundation

struct AgentChatLaunchResult {
    var session: AgentChatSession
    var project: AgentProject
}

struct AgentChatLaunchService {
    private let store: AgentSessionStore

    init(store: AgentSessionStore = AgentSessionStore()) {
        self.store = store
    }

    @discardableResult
    @MainActor
    func openCodexChat(
        title: String,
        prompt: String,
        imagePaths: [String],
        projectPath: String = AppPreferences.shared.agentDefaultProjectPath
    ) throws -> AgentChatLaunchResult {
        let project = try store.upsertProject(path: projectPath)
        let session = try store.createSession(
            provider: .codex,
            projectPath: project.path,
            title: title,
            model: AppPreferences.shared.resolvedCodexDefaultModelRaw(),
            reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
            initialPrompt: prompt,
            imagePaths: imagePaths,
            shouldLaunchOnOpen: true
        )
        WindowRequestCenter.shared.request(.agentChats)
        return AgentChatLaunchResult(session: session, project: project)
    }

    /// Startet eine neue Session über den Control-Socket (`whisperm8 chats new`)
    /// — verallgemeinert den Codex-Pfad auf beide Provider. `projectRef` ist
    /// ein Pfad ODER ein eindeutiger Workspace-Projektname/-Pfadfragment.
    /// Antwort erst nach Persistenz (Session-ID), damit der Aufrufer sofort
    /// `chats wait --ref` darauf setzen kann.
    struct ControlLaunchResult {
        var id: UUID
        var title: String
        var projectName: String
    }

    @MainActor
    func openChatViaControl(
        provider: AgentProvider,
        projectRef: String,
        title: String?,
        prompt: String?
    ) -> Result<ControlLaunchResult, ControlLaunchError> {
        // Projekt auflösen: existierender Pfad → direkt; sonst als
        // Name/Pfadfragment gegen den Workspace matchen (eindeutig).
        let projectPath: String
        if FileManager.default.fileExists(atPath: (projectRef as NSString).expandingTildeInPath) {
            projectPath = (projectRef as NSString).expandingTildeInPath
        } else {
            let workspace = AgentWorkspaceUIModel.shared.workspace
            let normalized = SessionRefResolver.normalize(projectRef)
            let matches = workspace.projects.filter {
                SessionRefResolver.normalize($0.name).contains(normalized)
                    || SessionRefResolver.normalize(($0.path as NSString).lastPathComponent).contains(normalized)
            }
            guard matches.count == 1 else {
                if matches.isEmpty {
                    return .failure(ControlLaunchError(message: "Kein Projekt gefunden fuer: \(projectRef) (Pfad existiert nicht, kein Name-Match)"))
                }
                return .failure(ControlLaunchError(message: "Projekt \(projectRef) ist mehrdeutig (\(matches.count) Treffer) — Pfad angeben"))
            }
            projectPath = matches[0].path
        }

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = (trimmedTitle?.isEmpty == false ? trimmedTitle! : "Neue Session")
        do {
            let project = try store.upsertProject(path: projectPath)
            let session: AgentChatSession
            switch provider {
            case .codex:
                session = try store.createSession(
                    provider: .codex, projectPath: project.path, title: effectiveTitle,
                    model: AppPreferences.shared.resolvedCodexDefaultModelRaw(),
                    reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                    initialPrompt: prompt, shouldLaunchOnOpen: true)
            case .claude:
                session = try store.createSession(
                    provider: .claude, projectPath: project.path, title: effectiveTitle,
                    initialPrompt: prompt, shouldLaunchOnOpen: true)
            }
            WindowRequestCenter.shared.request(.agentChats)
            WindowRequestCenter.shared.requestSessionFocus(sessionID: session.id)
            return .success(ControlLaunchResult(id: session.id, title: session.title, projectName: project.name))
        } catch {
            return .failure(ControlLaunchError(message: error.localizedDescription))
        }
    }
}

struct ControlLaunchError: Error {
    var message: String
}
