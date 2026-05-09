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
        try store.moveSession(id: second.id, direction: .up)

        let sessions = AgentSessionStore.sortedSessions(store.loadWorkspace().sessions)
        XCTAssertEqual(sessions.first?.id, second.id)
        XCTAssertEqual(sessions.first?.groupName, "Research")
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
}
