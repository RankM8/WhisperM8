import AppKit
import Foundation
import XCTest
@testable import WhisperM8

final class AgentChatsTests: XCTestCase {
    func testAgentCommandBuilderBuildsCodexNewAndResumeCommands() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
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
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
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
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
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
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { _ in [] }
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

    func testParseArgumentsHandlesWhitespaceAndQuotes() {
        XCTAssertEqual(AgentCommandBuilder.parseArguments(""), [])
        XCTAssertEqual(AgentCommandBuilder.parseArguments("   "), [])
        XCTAssertEqual(AgentCommandBuilder.parseArguments("--dangerously-skip-permissions"), ["--dangerously-skip-permissions"])
        XCTAssertEqual(
            AgentCommandBuilder.parseArguments("--ask-for-approval untrusted"),
            ["--ask-for-approval", "untrusted"]
        )
        XCTAssertEqual(
            AgentCommandBuilder.parseArguments("--text \"hello world\" --flag"),
            ["--text", "hello world", "--flag"]
        )
        // Quotes ohne Whitespace dazwischen werden konkateniert — POSIX-kompatibel.
        XCTAssertEqual(
            AgentCommandBuilder.parseArguments("--text 'mit ''doppelt'' tokens'"),
            ["--text", "mit doppelt tokens"]
        )
    }

    func testAgentCommandBuilderPrependsClaudeExtraArgumentsForResume() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { provider in
            provider == .claude ? ["--dangerously-skip-permissions"] : []
        }
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "claude-session",
            title: "Claude",
            hasLaunchedInitialPrompt: true
        )

        let command = try builder.command(for: session, project: project)

        // Extra-Args MÜSSEN vor `--resume` stehen, sonst würden sie als Sub-Command-Args behandelt.
        XCTAssertEqual(command.arguments, ["--dangerously-skip-permissions", "--resume", "claude-session"])
    }

    func testAgentCommandBuilderPrependsCodexExtraArgumentsForNewAndResume() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { command in "/usr/local/bin/\(command)" })
        builder.extraArgumentsResolver = { provider in
            provider == .codex ? ["--ask-for-approval", "untrusted"] : []
        }

        let newSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            title: "New",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            initialPrompt: "Do it"
        )
        let newCommand = try builder.command(for: newSession, project: project)
        XCTAssertEqual(Array(newCommand.arguments.prefix(2)), ["--ask-for-approval", "untrusted"])
        XCTAssertTrue(newCommand.arguments.contains("-C"))
        XCTAssertEqual(newCommand.arguments.last, "Do it")

        let resumeSession = AgentChatSession(
            provider: .codex,
            projectID: project.id,
            externalSessionID: "abc",
            title: "Resume",
            hasLaunchedInitialPrompt: true
        )
        let resumeCommand = try builder.command(for: resumeSession, project: project)
        // `resume` Sub-Command muss als erstes stehen; Extras kommen direkt danach.
        XCTAssertEqual(Array(resumeCommand.arguments.prefix(3)), ["resume", "--ask-for-approval", "untrusted"])
        XCTAssertEqual(resumeCommand.arguments.last, "abc")
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

    func testCodexSessionIndexerReadsOnlyBoundedMetadataPrefixAndUsesCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexBoundedIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("large-rollout.jsonl")
        let largeBody = String(repeating: "x", count: 2 * 1024 * 1024)
        try """
        {"type":"session_meta","timestamp":"2026-05-09T12:00:00.000Z","payload":{"id":"large-session","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}
        \(largeBody)
        """.write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let first = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)
        let second = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(first.sessions.first?.externalSessionID, "large-session")
        XCTAssertLessThanOrEqual(first.stats.bytesRead, 256 * 1024)
        XCTAssertEqual(first.stats.cacheMisses, 1)
        XCTAssertEqual(second.stats.cacheHits, 1)
        XCTAssertEqual(second.stats.bytesRead, 0)
    }

    func testCodexSessionIndexCacheInvalidatesWhenFileSizeChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexCacheInvalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout.jsonl")
        try """
        {"type":"session_meta","timestamp":"2026-05-09T12:00:00.000Z","payload":{"id":"session-id","cwd":"/tmp/repo","timestamp":"2026-05-09T12:00:00.000Z","model":"gpt-5.5"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        _ = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data("\n{\"type\":\"event_msg\"}".utf8))
        try handle.close()

        let refreshed = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(refreshed.stats.cacheMisses, 1)
        XCTAssertEqual(refreshed.stats.cacheHits, 0)
        XCTAssertEqual(refreshed.sessions.first?.externalSessionID, "session-id")
    }

    func testCodexSessionIndexCacheRemembersSkippedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8CodexSkippedCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("not-a-session.jsonl")
        try #"{"type":"event_msg","payload":{"type":"started"}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        var cache = AgentSessionIndexCache()
        let first = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)
        let second = CodexSessionIndexer(sessionsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(first.sessions.count, 0)
        XCTAssertEqual(first.stats.cacheMisses, 1)
        XCTAssertGreaterThan(first.stats.bytesRead, 0)
        XCTAssertEqual(second.sessions.count, 0)
        XCTAssertEqual(second.stats.cacheHits, 1)
        XCTAssertEqual(second.stats.bytesRead, 0)
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

    func testClaudeSessionIndexerReadsBoundedLinesAndCachesResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ClaudeBoundedIndex-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("-Users-test-repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)

        let trailingLines = (0..<500).map { index in
            #"{"type":"assistant","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","message":{"content":"line \#(index)"}}"#
        }.joined(separator: "\n")
        try """
        {"type":"ai-title","aiTitle":"Bounded Claude","sessionId":"11111111-1111-4111-8111-111111111111"}
        {"type":"user","timestamp":"2026-05-09T12:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/Users/test/repo","message":{"role":"user","content":"Fix this"}}
        \(trailingLines)
        """.write(
            to: projectDirectory.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var cache = AgentSessionIndexCache()
        let first = ClaudeSessionIndexer(projectsDirectory: root).indexedSessionResult(cache: &cache)
        let second = ClaudeSessionIndexer(projectsDirectory: root).indexedSessionResult(cache: &cache)

        XCTAssertEqual(first.sessions.first?.title, "Bounded Claude")
        XCTAssertLessThanOrEqual(first.stats.bytesRead, 1 * 1024 * 1024)
        XCTAssertEqual(first.stats.cacheMisses, 1)
        XCTAssertEqual(second.stats.cacheHits, 1)
        XCTAssertEqual(second.stats.bytesRead, 0)
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

    func testAgentResourceMonitorAggregatesSyntheticProcessTree() {
        let sessionID = UUID()
        let monitor = AgentResourceMonitor(
            processSamples: {
                [
                    AgentResourceProcessSample(pid: 10, parentPID: 1, cpuPercent: 0.6, memoryBytes: 100_000, command: "codex"),
                    AgentResourceProcessSample(pid: 11, parentPID: 10, cpuPercent: 0.4, memoryBytes: 50_000, command: "node"),
                    AgentResourceProcessSample(pid: 99, parentPID: 1, cpuPercent: 9.0, memoryBytes: 900_000, command: "other")
                ]
            },
            totalMemoryBytes: { 1_000_000 }
        )

        let snapshot = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(
                id: sessionID,
                projectName: "Repo",
                projectPath: "/tmp/repo",
                title: "Codex Chat",
                provider: .codex,
                rootProcessID: 10
            )
        ])

        XCTAssertEqual(snapshot.runningSessionCount, 1)
        XCTAssertEqual(snapshot.totalCPUPercent, 1.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalMemoryBytes, 150_000)
        XCTAssertEqual(snapshot.projects.first?.sessions.first?.processes.map(\.pid), [10, 11])
        XCTAssertEqual(try XCTUnwrap(snapshot.ramSharePercent), 15.0, accuracy: 0.001)
    }

    func testAgentResourceMonitorOmitsRamShareWithoutTotalMemory() {
        let monitor = AgentResourceMonitor(
            processSamples: {
                [AgentResourceProcessSample(pid: 10, parentPID: 1, cpuPercent: 0.1, memoryBytes: 100_000, command: "codex")]
            },
            totalMemoryBytes: { nil }
        )

        let snapshot = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(
                id: UUID(),
                projectName: "Repo",
                projectPath: "/tmp/repo",
                title: "Codex Chat",
                provider: .codex,
                rootProcessID: 10
            )
        ])

        XCTAssertNil(snapshot.ramSharePercent)
    }

    func testAgentResourceMonitorIgnoresDescriptorsWithoutRunningProcess() {
        let monitor = AgentResourceMonitor(
            processSamples: {
                [AgentResourceProcessSample(pid: 10, parentPID: 1, cpuPercent: 0.1, memoryBytes: 100_000, command: "codex")]
            },
            totalMemoryBytes: { 1_000_000 }
        )

        let snapshot = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(
                id: UUID(),
                projectName: "Repo",
                projectPath: "/tmp/repo",
                title: "Closed Chat",
                provider: .codex,
                rootProcessID: nil
            )
        ])

        XCTAssertEqual(snapshot.runningSessionCount, 0)
        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    func testClaudeRuntimeDisplayDoesNotUseCodexModel() {
        let claude = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "Claude Chat",
            model: "gpt-5.5"
        )
        let codex = AgentChatSession(
            provider: .codex,
            projectID: UUID(),
            title: "Codex Chat",
            model: "gpt-5.5",
            reasoningEffort: "medium"
        )

        XCTAssertEqual(claude.runtimeDisplayText, "Claude · Claude Code")
        XCTAssertEqual(codex.runtimeDisplayText, "Codex · gpt-5.5 · medium")
    }

    // MARK: - Auto-Chat-Context

    func testTranscriptContextBundleIsNotEmptyWhenAgentChatPresent() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: nil
        )
        let bundle = TranscriptContextBundle(agentChat: ref)
        XCTAssertFalse(bundle.isEmpty)
    }

    func testTranscriptContextBundleDisplaySummaryShowsChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .codex,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Codex Chat",
            externalSessionID: nil
        )
        let bundle = TranscriptContextBundle(agentChat: ref)
        XCTAssertEqual(bundle.displaySummary, "Chat")
    }

    func testTranscriptContextBundleDisplaySummaryCombinesChatWithText() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: nil
        )
        let selected = SelectedContext(
            text: "hello",
            sourceAppName: "Cursor",
            sourceBundleIdentifier: "com.cursor.app"
        )
        let bundle = TranscriptContextBundle(selectedText: selected, agentChat: ref)
        XCTAssertEqual(bundle.displaySummary, "Chat + Text")
    }

    func testTranscriptContextBundleCompactSummaryPrefersChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "x",
            projectPath: "/tmp/x",
            title: "Chat",
            externalSessionID: nil
        )
        // Selbst wenn Screenshots da sind, gewinnt Chat im Compact-Slot.
        let shot = ContextAttachment(
            kind: .screenshot,
            fileURL: URL(fileURLWithPath: "/tmp/shot.png")
        )
        let bundle = TranscriptContextBundle(agentChat: ref, screenshots: [shot])
        XCTAssertEqual(bundle.compactSummary, "Chat")
    }

    func testTranscriptContextBundleFromHelperPropagatesAgentChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: "ext-id"
        )
        let bundle = TranscriptContextBundle.from(
            selectedContext: .empty,
            sourceApp: nil,
            agentChat: ref
        )
        XCTAssertEqual(bundle.agentChat, ref)
        XCTAssertEqual(bundle.displaySummary, "Chat")
    }

    func testTranscriptContextBundleNoChatStillReportsNoContext() {
        let bundle = TranscriptContextBundle()
        XCTAssertTrue(bundle.isEmpty)
        XCTAssertEqual(bundle.displaySummary, "No Context")
    }

    // MARK: - Terminal Keyboard Shortcuts (Claude Code / Codex / Readline)

    func testTerminalShortcutOptionBackspaceMapsToCtrlW() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.option],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x17])
    }

    func testTerminalShortcutCommandBackspaceMapsToCtrlU() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.command],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x15])
    }

    func testTerminalShortcutCommandZMapsToReadlineUndo() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.command],
            characters: "z"
        )
        XCTAssertEqual(bytes, [0x1f])
    }

    func testTerminalShortcutCommandShiftZIsNotIntercepted() {
        // Cmd+Shift+Z (Redo) → durchreichen, Readline kennt kein Redo.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.command, .shift],
            characters: "Z"
        )
        XCTAssertNil(bytes)
    }

    func testTerminalShortcutOptionArrowsMapToWordMovement() {
        let leftBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.leftArrow,
            modifiers: [.option],
            characters: nil
        )
        let rightBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.rightArrow,
            modifiers: [.option],
            characters: nil
        )
        XCTAssertEqual(leftBytes, [0x1b, 0x62])   // Esc+B
        XCTAssertEqual(rightBytes, [0x1b, 0x66])  // Esc+F
    }

    func testTerminalShortcutCommandArrowsMapToLineMovement() {
        let leftBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.leftArrow,
            modifiers: [.command],
            characters: nil
        )
        let rightBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.rightArrow,
            modifiers: [.command],
            characters: nil
        )
        XCTAssertEqual(leftBytes, [0x01])  // Ctrl+A
        XCTAssertEqual(rightBytes, [0x05]) // Ctrl+E
    }

    func testTerminalShortcutPlainBackspaceIsNotIntercepted() {
        // Ohne Modifier soll SwiftTerms Default greifen (sendet 0x7f).
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [],
            characters: nil
        )
        XCTAssertNil(bytes)
    }

    // MARK: - Login Shell Environment

    func testLoginShellEnvironmentMergesUserPathWithFallback() {
        let env = LoginShellEnvironment(pathLoader: {
            "/Users/test/.mise/shims:/Users/test/bin:/opt/homebrew/bin:/usr/bin:/bin"
        })
        let path = env.path
        // User-spezifische Pfade müssen vorne stehen (mise/asdf-shims gewinnen).
        XCTAssertTrue(path.hasPrefix("/Users/test/.mise/shims:/Users/test/bin"))
        // Fallback-Pfade dürfen nur einmal vorkommen (Dedup).
        let occurrences = path.components(separatedBy: "/usr/bin").count - 1
        XCTAssertEqual(occurrences, 1)
        // Fallback-Pfade müssen vorhanden sein, auch wenn nicht im User-PATH.
        XCTAssertTrue(path.contains("/usr/sbin"))
        XCTAssertTrue(path.contains("/sbin"))
    }

    func testLoginShellEnvironmentFallsBackOnEmptyResult() {
        let env = LoginShellEnvironment(pathLoader: { "" })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
    }

    func testLoginShellEnvironmentFallsBackOnNil() {
        let env = LoginShellEnvironment(pathLoader: { nil })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
    }

    func testLoginShellEnvironmentCachesResult() {
        var calls = 0
        let env = LoginShellEnvironment(pathLoader: {
            calls += 1
            return "/opt/homebrew/bin:/usr/bin"
        })
        _ = env.path
        _ = env.path
        _ = env.path
        XCTAssertEqual(calls, 1, "PATH-Loader darf nur einmal aufgerufen werden (Cache)")
    }

    func testLoginShellEnvironmentProcessEnvironmentInjectsPath() {
        let env = LoginShellEnvironment(pathLoader: { "/opt/homebrew/bin:/usr/bin" })
        let envDict = env.processEnvironment(base: ["HOME": "/Users/test", "PATH": "/old"])
        XCTAssertEqual(envDict["HOME"], "/Users/test", "Andere ENV-Vars bleiben erhalten")
        XCTAssertTrue(envDict["PATH"]?.contains("/opt/homebrew/bin") == true)
        XCTAssertNotEqual(envDict["PATH"], "/old", "Alter PATH wird ersetzt")
    }

    func testLoginShellEnvironmentTerminalEnvironmentArrayHasPathKey() {
        let env = LoginShellEnvironment(pathLoader: { "/opt/homebrew/bin:/usr/bin" })
        let array = env.terminalEnvironmentArray(base: ["HOME": "/Users/test"])
        XCTAssertTrue(array.contains { $0.hasPrefix("PATH=") && $0.contains("/opt/homebrew/bin") })
        XCTAssertTrue(array.contains("HOME=/Users/test"))
    }

    func testLoginShellEnvironmentSetsTerminalColorDefaults() {
        // Regression: ohne TERM/COLORTERM rendern Claude Code & Codex CLI monochrom,
        // weil GUI-Apps diese Vars nicht von launchd erben.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [:])
        XCTAssertEqual(envDict["TERM"], "xterm-256color")
        XCTAssertEqual(envDict["COLORTERM"], "truecolor")
        XCTAssertEqual(envDict["CLICOLOR"], "1")
        XCTAssertEqual(envDict["LANG"], "en_US.UTF-8")
    }

    func testLoginShellEnvironmentRespectsExistingTerminalVars() {
        // User-Profile (z. B. iTerm-User mit TERM=xterm-kitty) sollen nicht
        // überschrieben werden — wir füllen nur Lücken.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "TERM": "xterm-kitty",
            "COLORTERM": "24bit",
            "LC_ALL": "de_DE.UTF-8"
        ])
        XCTAssertEqual(envDict["TERM"], "xterm-kitty")
        XCTAssertEqual(envDict["COLORTERM"], "24bit")
        XCTAssertEqual(envDict["LC_ALL"], "de_DE.UTF-8")
        XCTAssertNil(envDict["LANG"], "LANG nicht gesetzt, weil LC_ALL bereits eine Locale liefert")
    }

    func testFallbackPathContainsCommonLocations() {
        // Sanity-Check: alle wichtigen Pfade abgedeckt für Apple Silicon + Intel
        let fallback = LoginShellEnvironment.fallbackPath
        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            XCTAssertTrue(fallback.contains(expected), "fallbackPath muss \(expected) enthalten")
        }
    }

    func testTerminalShortcutControlCombosAreNotIntercepted() {
        // Wenn der User Control hält, soll SwiftTerm seine Standard-Control-
        // Sequences durchgeben (Ctrl+W = 0x17, Ctrl+U = 0x15 etc.) — wir
        // konkurrieren nicht damit.
        XCTAssertNil(TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.control, .option],
            characters: nil
        ))
        XCTAssertNil(TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.control, .command],
            characters: "z"
        ))
    }

    // MARK: - Transcript Parser & Status Decider

    func testTranscriptParserClaudeUserMessage() {
        let line = #"{"type":"user","timestamp":"2026-05-10T12:00:00Z","message":{"role":"user","content":"hallo"}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case .userMessage = event else {
            return XCTFail("Erwartete .userMessage, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserClaudeToolResultIsNotUserMessage() {
        // Tool-Results sind in Claude technisch User-Messages mit tool_result-
        // Content-Block — wir behandeln sie als eigene Kategorie.
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x"}]}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case .toolResult = event else {
            return XCTFail("Erwartete .toolResult, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserClaudeAssistantStopped() {
        let line = #"{"type":"assistant","timestamp":"2026-05-10T12:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case let .assistantMessageStopped(_, reason) = event else {
            return XCTFail("Erwartete .assistantMessageStopped, bekam \(String(describing: event))")
        }
        XCTAssertEqual(reason, "end_turn")
    }

    func testTranscriptParserClaudeAssistantOngoing() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .claude)
        guard case .assistantMessageOngoing = event else {
            return XCTFail("Erwartete .assistantMessageOngoing, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserCodexTurnCompleted() {
        let line = #"{"type":"event","subtype":"turn.completed","timestamp":"2026-05-10T12:00:00Z"}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .codex)
        guard case .assistantMessageStopped = event else {
            return XCTFail("Erwartete .assistantMessageStopped für Codex, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserCodexUserItem() {
        let line = #"{"type":"item","subtype":"user_message","content":[{"text":"go"}]}"#
        let event = AgentTranscriptParser.parseLine(line, provider: .codex)
        guard case .userMessage = event else {
            return XCTFail("Erwartete .userMessage für Codex, bekam \(String(describing: event))")
        }
    }

    func testTranscriptParserReturnsNilForGarbageLine() {
        XCTAssertNil(AgentTranscriptParser.parseLine("not json", provider: .claude))
        XCTAssertNil(AgentTranscriptParser.parseLine("", provider: .codex))
    }

    func testTranscriptParserPicksLastValidLineFromTail() {
        // Tail-Reads beginnen oft mit einer halben Zeile — der Parser muss
        // robust nur die letzte vollständige Zeile auswerten.
        let truncated = "\"xxxx incomplete pre-line\"\n"
            + #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"#
            + "\n"
        let event = AgentTranscriptParser.lastEvent(in: truncated, provider: .claude)
        guard case .assistantMessageStopped = event else {
            return XCTFail("Erwartete .assistantMessageStopped als letzte Zeile, bekam \(String(describing: event))")
        }
    }

    func testStatusDeciderReportsWorkingForRecentUserMessage() {
        let now = Date()
        let event: AgentTranscriptEvent = .userMessage(timestamp: now)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: now,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .working)
        XCTAssertFalse(decision.turnFinished)
    }

    func testStatusDeciderReportsIdleAndTurnFinishedAfterStop() {
        let now = Date()
        let stopped = now.addingTimeInterval(-1)
        let event: AgentTranscriptEvent = .assistantMessageStopped(timestamp: stopped, stopReason: "end_turn")
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: stopped,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .idle)
        XCTAssertTrue(decision.turnFinished, "Erstes Stop-Event muss als turnFinished melden")
    }

    func testStatusDeciderSuppressesTurnFinishedReDetection() {
        let now = Date()
        let stoppedAt = now.addingTimeInterval(-2)
        let event: AgentTranscriptEvent = .assistantMessageStopped(timestamp: stoppedAt, stopReason: "end_turn")
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: stoppedAt,
            now: now,
            priorTurnFinishedAt: stoppedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(decision.status, .idle)
        XCTAssertFalse(decision.turnFinished, "Älteres oder gleiches Stop-Event darf nicht als neuer Turn melden")
    }

    func testStatusDeciderEscalatesOngoingToAwaitingInputAfterTimeout() {
        let now = Date()
        let event: AgentTranscriptEvent = .assistantMessageOngoing(timestamp: now)
        // mtime liegt weiter zurück als der Heuristik-Schwellwert
        let mtime = now.addingTimeInterval(-(AgentTranscriptStatusDecider.awaitingInputAfterSeconds + 1))
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: mtime,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .awaitingInput)
    }

    func testStatusDeciderTreatsRecentOngoingAsWorking() {
        let now = Date()
        let event: AgentTranscriptEvent = .assistantMessageOngoing(timestamp: now)
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: event,
            fileMTime: now,
            now: now,
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .working)
    }

    func testStatusDeciderHandlesEmptyTranscriptAsWorking() {
        // Frisch gestartete Session: Datei noch leer / unparseable.
        let decision = AgentTranscriptStatusDecider.decide(
            lastEvent: nil,
            fileMTime: Date(),
            now: Date(),
            priorTurnFinishedAt: nil
        )
        XCTAssertEqual(decision.status, .working)
    }

    // MARK: - Title Generator Cleanup

    func testTitleGeneratorCleanupStripsQuotesAndPunctuation() {
        XCTAssertEqual(AgentTitleGenerator.cleanTitle("\"Refactor login UI\""), "Refactor login UI")
        XCTAssertEqual(AgentTitleGenerator.cleanTitle("Refactor login UI."), "Refactor login UI")
        XCTAssertEqual(AgentTitleGenerator.cleanTitle("Title: Database Migration!"), "Database Migration")
    }

    func testTitleGeneratorCleanupTakesFirstLineOnly() {
        let raw = "Refactor login UI\nSome explanation goes here"
        XCTAssertEqual(AgentTitleGenerator.cleanTitle(raw), "Refactor login UI")
    }

    func testTitleGeneratorCleanupCapsLength() {
        let long = String(repeating: "A", count: 120)
        let cleaned = AgentTitleGenerator.cleanTitle(long)
        XCTAssertLessThanOrEqual(cleaned.count, 60)
    }

    // MARK: - Auto-Title Flag

    func testCanAutoRenameTitleAllowsLegacyDefaultName() {
        // Legacy-Sessions ohne Flag, aber mit Default-Name → Auto-Rename erlaubt.
        let session = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "Claude Chat"
        )
        XCTAssertTrue(session.canAutoRenameTitle)
    }

    func testCanAutoRenameTitleBlocksUserSuppliedName() {
        // Wenn der User explizit umbenannt hat, kommt das Flag = false rein.
        var session = AgentChatSession(
            provider: .claude,
            projectID: UUID(),
            title: "My Custom Project Name"
        )
        session.titleIsAutoGenerated = false
        XCTAssertFalse(session.canAutoRenameTitle)
    }

    func testCanAutoRenameTitleAllowsAutoGeneratedReplacement() {
        // Auto-generierter Name darf vom Auto-Namer überschrieben werden
        // (nützlich, falls die Session weiterläuft und sich neu fokussiert).
        var session = AgentChatSession(
            provider: .codex,
            projectID: UUID(),
            title: "Initial auto title"
        )
        session.titleIsAutoGenerated = true
        XCTAssertTrue(session.canAutoRenameTitle)
    }

    func testApplyAutoGeneratedTitleRespectsManualRename() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        // User benennt manuell um → Flag = false.
        try store.renameSession(id: session.id, title: "Important Bugfix")
        // Auto-Namer versucht zu schreiben — darf nicht durchkommen.
        try store.applyAutoGeneratedTitle(id: session.id, title: "Generic Auto Name")
        let workspace = store.loadWorkspace()
        let updated = workspace.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Important Bugfix")
        XCTAssertEqual(updated?.titleIsAutoGenerated, false)
    }

    func testApplyAutoGeneratedTitleAcceptsLegacyDefaultName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        try store.applyAutoGeneratedTitle(id: session.id, title: "Login UI Refactor")
        let workspace = store.loadWorkspace()
        let updated = workspace.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Login UI Refactor")
        XCTAssertEqual(updated?.titleIsAutoGenerated, true)
    }

    func testRecordTurnEndedSetsLastTurnAt() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try store.recordTurnEnded(id: session.id, at: timestamp)
        let workspace = store.loadWorkspace()
        let updated = workspace.sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.lastTurnAt, timestamp)
    }

    // MARK: - Transcript Locator

    func testClaudeCwdEncodingMatchesActualEncoding() {
        // Claude ersetzt jeden Nicht-Alphanumerik-Char durch `-`.
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/Users/foo/repos/heartbeat"),
            "-Users-foo-repos-heartbeat"
        )
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/var/lib/data_2"),
            "-var-lib-data-2"
        )
    }

    // MARK: - Helpers

    private func makeTempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AgentSessions.json")
    }
}
