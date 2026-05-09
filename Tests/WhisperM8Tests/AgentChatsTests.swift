import Foundation
import XCTest
@testable import WhisperM8

final class AgentChatsTests: XCTestCase {
    func testAgentCommandBuilderBuildsCodexNewAndResumeCommands() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        let newSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "New",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            initialPrompt: "Do the thing",
            imagePaths: ["/tmp/shot.png"]
        )

        let newCommand = try builder.command(for: newSession, project: project)

        XCTAssertEqual(newCommand.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(newCommand.workingDirectory, project.path)
        XCTAssertTrue(newCommand.arguments.contains("-C"))
        XCTAssertTrue(newCommand.arguments.contains(project.path))
        XCTAssertTrue(newCommand.arguments.contains("--image"))
        XCTAssertTrue(newCommand.arguments.contains("/tmp/shot.png"))
        XCTAssertEqual(newCommand.arguments.last, "Do the thing")

        let resumeSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            externalSessionID: "abc",
            title: "Resume",
            hasLaunchedInitialPrompt: true
        )
        let resumeCommand = try builder.command(for: resumeSession, project: project)

        XCTAssertEqual(resumeCommand.arguments.first, "resume")
        XCTAssertTrue(resumeCommand.arguments.contains("abc"))
    }

    func testAgentCommandBuilderBuildsClaudeCommands() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "claude-session",
            title: "Claude",
            hasLaunchedInitialPrompt: true
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/usr/local/bin/claude")
        XCTAssertEqual(command.arguments, ["--resume", "claude-session"])
        XCTAssertEqual(command.workingDirectory, project.path)
    }

    func testAgentCommandBuilderBuildsClaudeNewSessionWithStableSessionID() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "4D8F1E1D-7B4B-4F0B-9B6E-1552E2E827AA",
            title: "Claude"
        )

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.executablePath, "/usr/local/bin/claude")
        XCTAssertEqual(command.arguments, ["--session-id", "4D8F1E1D-7B4B-4F0B-9B6E-1552E2E827AA"])
        XCTAssertEqual(command.workingDirectory, project.path)
    }

    func testAgentCommandBuilderDoesNotSilentlyCreateNewSessionWhenResumeIDIsMissing() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        let launchedSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "Running Task",
            hasLaunchedInitialPrompt: true
        )

        XCTAssertThrowsError(try builder.command(for: launchedSession, project: project)) { error in
            XCTAssertEqual(error as? AgentCommandError, .missingExternalSessionID("Running Task"))
        }
    }

    func testCodexSessionIndexerReadsSessionMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout.jsonl")
        try """
        {"type":"session_meta","timestamp":"2026-05-09T12:00:00.000Z","payload":{"id":"session-id","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}
        {"type":"event_msg","payload":{"type":"started"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = CodexSessionIndexer(sessionsDirectory: root).indexedSessions()

        XCTAssertEqual(sessions.first?.provider, .codex)
        XCTAssertEqual(sessions.first?.externalSessionID, "session-id")
        XCTAssertEqual(sessions.first?.cwd, "/tmp/repo")
        XCTAssertEqual(sessions.first?.model, "gpt-5.5")
    }

    func testClaudeSessionIndexerReadsProjectJsonlMetadataAndSkipsWorktrees() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ClaudeIndex-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-Users-test-repo", isDirectory: true)
        let worktreeDirectory = root.appendingPathComponent("-Users-test-repo--claude-worktrees-temp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeDirectory, withIntermediateDirectories: true)

        try """
        {"type":"ai-title","aiTitle":"Fix hooks","sessionId":"11111111-1111-4111-8111-111111111111"}
        {"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/Users/test/repo","message":{"role":"user","content":"Fix this"}}
        """.write(
            to: projectDirectory.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"22222222-2222-4222-8222-222222222222","cwd":"/Users/test/repo/.claude/worktrees/temp","message":{"role":"user","content":"Ignore this"}}
        """.write(
            to: worktreeDirectory.appendingPathComponent("22222222-2222-4222-8222-222222222222.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sessions = ClaudeSessionIndexer(projectsDirectory: root).indexedSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.provider, .claude)
        XCTAssertEqual(sessions.first?.externalSessionID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(sessions.first?.cwd, "/Users/test/repo")
        XCTAssertEqual(sessions.first?.title, "Fix hooks")
    }

    func testAgentSessionStorePersistsProjectsAndSessions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentSessions-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = AgentSessionStore(fileURL: fileURL)
        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Voice Task",
            initialPrompt: "Prompt"
        )
        let workspace = store.loadWorkspace()

        XCTAssertEqual(workspace.projects.count, 1)
        XCTAssertEqual(workspace.sessions.first?.id, session.id)
        XCTAssertEqual(workspace.sessions.first?.initialPrompt, "Prompt")
    }

    func testAgentSessionStorePersistsLaunchOnOpenFlagForExplicitStarts() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentLaunch-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = AgentSessionStore(fileURL: fileURL)
        _ = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Explicit",
            initialPrompt: "Prompt",
            shouldLaunchOnOpen: true
        )

        XCTAssertEqual(store.loadWorkspace().sessions.first?.shouldLaunchOnOpen, true)
    }

    func testAgentSessionStoreSupportsManualOrderingAndGrouping() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentOrdering-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = AgentSessionStore(fileURL: fileURL)
        let first = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "First"
        )
        let second = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Second"
        )

        try store.setSessionGroup(id: second.id, groupName: "Research")
        try store.setSessionColor(id: second.id, color: AgentChatColor.palette[2])
        try store.moveSession(id: second.id, direction: .up)

        let sessions = AgentSessionStore.sortedSessions(store.loadWorkspace().sessions)
        XCTAssertEqual(sessions.first?.id, second.id)
        XCTAssertEqual(sessions.first?.groupName, "Research")
        XCTAssertEqual(sessions.first?.color, AgentChatColor.palette[2])
        XCTAssertNil(sessions.last { $0.id == first.id }?.groupName)
    }

    func testAgentSessionStoreClosesStaleRunningMetadataWithoutLaunching() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentStale-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Stale"
        )
        session.status = .running
        _ = try store.upsertSession(session)

        try store.markStaleRunningSessionsClosed()

        XCTAssertEqual(store.loadWorkspace().sessions.first?.status, .closed)
    }

    func testAgentSessionStoreKeepsActiveRunningSessionsOpen() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentActive-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Active"
        )
        session.status = .running
        _ = try store.upsertSession(session)

        try store.markStaleRunningSessionsClosed(excluding: [session.id])

        XCTAssertEqual(store.loadWorkspace().sessions.first?.status, .running)
    }

    func testAgentSessionStoreBindsLaunchedSessionToIndexedSessionID() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentBind-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let projectPath = FileManager.default.temporaryDirectory.path
        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .codex,
            projectPath: projectPath,
            title: "Codex Chat"
        )
        session.status = .running
        session.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(session)

        let indexed = IndexedAgentSession(
            provider: .codex,
            externalSessionID: "indexed-session",
            cwd: projectPath,
            title: "Indexed Title",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            createdAt: Date(),
            lastActivityAt: Date()
        )

        let updated = try store.bindLatestIndexedSession(
            localSessionID: session.id,
            provider: .codex,
            projectPath: projectPath,
            indexedSessions: [indexed]
        )

        XCTAssertEqual(updated?.externalSessionID, "indexed-session")
        XCTAssertEqual(store.loadWorkspace().sessions.first?.externalSessionID, "indexed-session")
    }

    func testAgentSessionStoreSkipsClaudeWorktreeSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentWorktree-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("heartbeat", isDirectory: true)
        let worktree = repo
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("peaceful-mcclintock-67ade3", isDirectory: true)
        let fileURL = root.appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let store = AgentSessionStore(fileURL: fileURL)
        try store.mergeIndexedSessions([
            IndexedAgentSession(
                provider: .codex,
                externalSessionID: "worktree-session",
                cwd: worktree.path,
                title: "Worktree Task",
                model: "gpt-5.5",
                reasoningEffort: "medium",
                createdAt: Date(),
                lastActivityAt: Date()
            )
        ])

        let workspace = store.loadWorkspace()
        XCTAssertEqual(workspace.projects.count, 0)
        XCTAssertEqual(workspace.sessions.count, 0)

        let project = try store.upsertProject(path: worktree.path)
        XCTAssertEqual(project.path, repo.path)
    }

    func testAgentSessionStoreRemovesExistingWorktreeProjectsAndSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentWorktreeMigration-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("heartbeat", isDirectory: true)
        let worktree = repo
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("sad-yonath-7da672", isDirectory: true)
        let fileURL = root.appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let worktreeProject = AgentProject(
            name: "sad-yonath-7da672",
            path: worktree.path,
            color: AgentProjectColor.palette[3]
        )
        let session = AgentChatSession(
            provider: .claude,
            projectID: worktreeProject.id,
            externalSessionID: "claude-session",
            title: "Claude Worktree"
        )
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [worktreeProject], sessions: [session]))

        try store.mergeIndexedSessions([])

        let workspace = store.loadWorkspace()
        XCTAssertEqual(workspace.projects.count, 0)
        XCTAssertEqual(workspace.sessions.count, 0)
    }

    func testAgentSessionStoreRemovesUnresumableClaudeSessions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentUnresumable-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let unresumable = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true
        )
        let resumable = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "11111111-1111-4111-8111-111111111111",
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true
        )
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: [unresumable, resumable]))

        try store.mergeIndexedSessions([])

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, resumable.id)
    }

    func testAgentSessionStoreMigratesUnresumableClaudeSessionsOnLoad() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentLoadMigration-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let unresumable = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true
        )
        let resumable = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "22222222-2222-4222-8222-222222222222",
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true
        )
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: [unresumable, resumable]))

        let loaded = store.loadWorkspace()
        XCTAssertEqual(loaded.sessions.count, 1)
        XCTAssertEqual(loaded.sessions.first?.id, resumable.id)
        XCTAssertEqual(store.loadWorkspace().sessions.count, 1)
    }
}
