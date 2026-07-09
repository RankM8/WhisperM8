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
}
