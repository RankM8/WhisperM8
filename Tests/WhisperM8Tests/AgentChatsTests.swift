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

    func testAgentSessionStoreLoadsLegacyWorkspaceWithoutRecentSessionFields() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let projectID = UUID()
        let sessionID = UUID()
        try """
        {
          "projects": [
            {
              "id": "\(projectID.uuidString)",
              "name": "Legacy Repo",
              "path": "/tmp/legacy-repo",
              "color": "#0A84FF",
              "createdAt": "2026-05-09T12:00:00Z",
              "updatedAt": "2026-05-09T12:00:00Z"
            }
          ],
          "sessions": [
            {
              "id": "\(sessionID.uuidString)",
              "provider": "codex",
              "projectID": "\(projectID.uuidString)",
              "title": "Codex Chat",
              "model": "gpt-5.5",
              "reasoningEffort": "medium",
              "status": "pending",
              "createdAt": "2026-05-09T12:00:00Z",
              "lastActivityAt": "2026-05-09T12:00:00Z"
            }
          ]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let workspace = AgentSessionStore(fileURL: fileURL).loadWorkspace()

        XCTAssertEqual(workspace.schemaVersion, AgentWorkspace.currentSchemaVersion)
        XCTAssertEqual(workspace.sessions.first?.id, sessionID)
        XCTAssertEqual(workspace.sessions.first?.imagePaths, [])
        XCTAssertEqual(workspace.sessions.first?.hasLaunchedInitialPrompt, false)
    }

    func testAgentSessionStoreBacksUpUnreadableWorkspaceBeforeReturningEmpty() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try "{ not valid json".write(to: fileURL, atomically: true, encoding: .utf8)

        let workspace = AgentSessionStore(fileURL: fileURL).loadWorkspace()
        let backups = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("decode-failed") && $0.pathExtension == "bak" }

        XCTAssertEqual(workspace.projects.count, 0)
        XCTAssertEqual(workspace.sessions.count, 0)
        XCTAssertEqual(backups.count, 1)
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

    func testAgentSessionStoreRebindsInvalidClaudeResumeIDBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentClaudeRebind-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("workspace.json")
        let projectPath = root.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let createdAt = Date(timeIntervalSince1970: 100)
        let project = AgentProject(name: "Repo", path: projectPath.path)
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "stale-local-id",
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true,
            createdAt: createdAt,
            lastActivityAt: createdAt.addingTimeInterval(120)
        )
        let indexed = IndexedAgentSession(
            provider: .claude,
            externalSessionID: "real-claude-id",
            cwd: projectPath.path,
            title: "Recovered Claude Chat",
            model: nil,
            reasoningEffort: nil,
            createdAt: createdAt.addingTimeInterval(4),
            lastActivityAt: createdAt.addingTimeInterval(180)
        )
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: [session]))

        let result = try store.repairResumeStateBeforeLaunch(
            localSessionID: session.id,
            projectPath: projectPath.path,
            indexedSessions: [indexed],
            now: createdAt.addingTimeInterval(300)
        )

        XCTAssertEqual(result?.outcome, .rebound(from: "stale-local-id", to: "real-claude-id"))
        XCTAssertEqual(result?.session.externalSessionID, "real-claude-id")
        XCTAssertEqual(store.loadWorkspace().sessions.first?.externalSessionID, "real-claude-id")
    }

    func testAgentSessionStoreKeepsValidClaudeResumeIDBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentClaudeValid-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("workspace.json")
        let projectPath = root.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let createdAt = Date(timeIntervalSince1970: 100)
        let project = AgentProject(name: "Repo", path: projectPath.path)
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "valid-claude-id",
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true,
            createdAt: createdAt,
            lastActivityAt: createdAt.addingTimeInterval(120)
        )
        let indexed = IndexedAgentSession(
            provider: .claude,
            externalSessionID: "valid-claude-id",
            cwd: projectPath.path,
            title: "Claude Chat",
            model: nil,
            reasoningEffort: nil,
            createdAt: createdAt,
            lastActivityAt: createdAt.addingTimeInterval(180)
        )
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: [session]))

        let result = try store.repairResumeStateBeforeLaunch(
            localSessionID: session.id,
            projectPath: projectPath.path,
            indexedSessions: [indexed],
            now: createdAt.addingTimeInterval(300)
        )

        XCTAssertEqual(result?.outcome, .unchanged)
        XCTAssertEqual(result?.session.externalSessionID, "valid-claude-id")
        XCTAssertEqual(store.loadWorkspace().sessions.first?.externalSessionID, "valid-claude-id")
    }

    func testAgentSessionStoreResetsInvalidClaudeResumeIDWhenNoConversationExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentClaudeReset-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("workspace.json")
        let projectPath = root.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let createdAt = Date(timeIntervalSince1970: 100)
        let project = AgentProject(name: "Repo", path: projectPath.path)
        let session = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            externalSessionID: "missing-claude-id",
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true,
            createdAt: createdAt,
            lastActivityAt: createdAt.addingTimeInterval(120)
        )
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: [session]))

        let result = try store.repairResumeStateBeforeLaunch(
            localSessionID: session.id,
            projectPath: projectPath.path,
            indexedSessions: [],
            now: createdAt.addingTimeInterval(300)
        )
        let repaired = try XCTUnwrap(result?.session)
        let command = try AgentCommandBuilder(commandResolver: { _ in "/usr/local/bin/claude" })
            .command(for: repaired, project: project)

        XCTAssertEqual(result?.outcome, .resetInvalid("missing-claude-id"))
        XCTAssertNil(repaired.externalSessionID)
        XCTAssertFalse(repaired.hasLaunchedInitialPrompt)
        XCTAssertFalse(command.arguments.contains("--resume"))
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

    func testAgentSessionStoreKeepsManualClaudeSessionWithoutExternalIDDuringRecoveryStart() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8AgentManualRecovery-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let recovering = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude Chat",
            status: .running,
            hasLaunchedInitialPrompt: true,
            createdManually: true
        )
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: [recovering]))

        try store.mergeIndexedSessions([])

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, recovering.id)
        XCTAssertEqual(sessions.first?.status, .running)
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

    func testLoginShellEnvironmentRepairsMonochromeLauncherEnvironment() {
        // Regression: `make dev` aus Codex kann die App mit TERM=dumb und
        // NO_COLOR=1 starten. Diese Werte dürfen nicht an SwiftTerm-Child-
        // Prozesse weitergereicht werden, sonst rendert Claude/Codex grau.
        let env = LoginShellEnvironment(pathLoader: { "/usr/bin" })
        let envDict = env.processEnvironment(base: [
            "TERM": "dumb",
            "COLORTERM": "",
            "NO_COLOR": "1"
        ])

        XCTAssertEqual(envDict["TERM"], "xterm-256color")
        XCTAssertEqual(envDict["COLORTERM"], "truecolor")
        XCTAssertEqual(envDict["CLICOLOR"], "1")
        XCTAssertNil(envDict["NO_COLOR"])
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

    func testAgentHeadlessCLIReturnsStdout() async throws {
        let output = try await AgentHeadlessCLI(timeout: 2).run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            environment: [:]
        )

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testAgentHeadlessCLIReportsNonZeroExit() async throws {
        do {
            _ = try await AgentHeadlessCLI(timeout: 2).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo nope >&2; exit 7"],
                environment: [:]
            )
            XCTFail("Expected non-zero exit")
        } catch AgentHeadlessCLIError.nonZeroExit(let code, let stderr) {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(stderr.contains("nope"))
        }
    }

    func testAgentHeadlessCLITimesOut() async throws {
        do {
            _ = try await AgentHeadlessCLI(timeout: 0.05).run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                environment: [:]
            )
            XCTFail("Expected timeout")
        } catch AgentHeadlessCLIError.timedOut {
            // Expected.
        }
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

    func testForceGenerateTitleBypassesLastTurnAtAndAttemptedSet() async throws {
        // Force-Pfad: gescannte alte Session hat schon `lastTurnAt` und der
        // Namer hat sie ggf. in `alreadyAttempted`. Beides muss `forceGenerateTitle`
        // ignorieren — solange `canAutoRenameTitle == true` bleibt.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)

        // Echtes Claude-Transcript anlegen, damit der Locator + Excerpt-Builder Daten sehen.
        let projectDir = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectDir) }
        let externalSessionID = "11111111-2222-3333-4444-555555555555"
        let claudeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(AgentTranscriptLocator.encodeClaudeCwd(projectDir.path))
        try? FileManager.default.createDirectory(at: claudeBase, withIntermediateDirectories: true)
        let transcriptURL = claudeBase.appendingPathComponent("\(externalSessionID).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        let transcript = #"""
        {"type":"user","message":{"role":"user","content":"refactor my login flow"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here is a plan."}],"stop_reason":"end_turn"}}
        """#
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        var session = try store.createSession(
            provider: .claude,
            projectPath: projectDir.path,
            title: "Claude Chat"
        )
        session.externalSessionID = externalSessionID
        session.lastTurnAt = Date()  // simuliert Resume-Session, blockt normalerweise Auto-Naming
        _ = try store.upsertSession(session)

        let stub = AgentTitleGenerator(
            executableResolver: { _ in "/usr/bin/true" },
            runner: { _, _, _ in "Login Flow Refactor" }
        )
        let namer = await AgentSessionAutoNamer(store: store, titleGenerator: stub)
        await namer.resetAttemptTracking()
        // Auch wenn sie zuvor schon mal blockiert war, force soll es trotzdem tun.
        await namer.handleTurnFinished(session: session, cwd: projectDir.path)

        let snapshotAfterRegular = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(snapshotAfterRegular?.title, "Claude Chat",
                       "handleTurnFinished blockt erwartungsgemäß bei lastTurnAt != nil")

        // Force-Pfad: blocking flags werden ignoriert, Title wird gesetzt.
        let expectation = expectation(description: "force-naming completes")
        await namer.forceGenerateTitle(session: session, cwd: projectDir.path) { result in
            if case .success = result { expectation.fulfill() }
        }
        await fulfillment(of: [expectation], timeout: 5)

        let updated = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(updated?.title, "Login Flow Refactor")
        XCTAssertEqual(updated?.titleIsAutoGenerated, true)
    }

    func testForceGenerateTitleStillRespectsManualRename() async throws {
        // canAutoRenameTitle == false (User hat manuell umbenannt) → force darf NICHT überschreiben.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        var session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Manual Important Name"
        )
        session.titleIsAutoGenerated = false  // wie nach manuellem Rename
        session.externalSessionID = "abc-123"
        _ = try store.upsertSession(session)

        let stub = AgentTitleGenerator(
            executableResolver: { _ in "/usr/bin/true" },
            runner: { _, _, _ in "Should Never Be Set" }
        )
        let namer = await AgentSessionAutoNamer(store: store, titleGenerator: stub)
        let expectation = expectation(description: "force call returns or skips")
        expectation.isInverted = true
        await namer.forceGenerateTitle(session: session, cwd: NSTemporaryDirectory()) { _ in
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 1)

        let snap = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(snap?.title, "Manual Important Name")
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

    // MARK: - Terminal drag-drop payload

    func testTerminalDropPayloadEscapesNothingForSimplePath() {
        XCTAssertEqual(
            TerminalDropPayload.build(from: ["/Users/me/repos/whisperm8/file.md"]),
            "/Users/me/repos/whisperm8/file.md"
        )
    }

    func testTerminalDropPayloadEscapesSpacesAndSpecialChars() {
        XCTAssertEqual(
            TerminalDropPayload.shellEscape("/Users/me/Tim AI/2026-05-11 plan.md"),
            "/Users/me/Tim\\ AI/2026-05-11\\ plan.md"
        )
    }

    func testTerminalDropPayloadEscapesUmlauts() {
        // Umlaute sind nicht im "safe"-Set, müssen also escapt werden, damit
        // die Shell sie nicht als Argument-Trennzeichen oder Glob behandelt.
        let escaped = TerminalDropPayload.shellEscape("/Users/me/Übersicht.md")
        XCTAssertTrue(escaped.contains("\\Ü"))
    }

    func testTerminalDropPayloadJoinsMultiplePathsWithSpaces() {
        let result = TerminalDropPayload.build(from: [
            "/tmp/a.md",
            "/tmp/b c.md"
        ])
        XCTAssertEqual(result, "/tmp/a.md /tmp/b\\ c.md")
    }

    func testTerminalDropPayloadEmptyInput() {
        XCTAssertEqual(TerminalDropPayload.build(from: []), "")
    }

    // MARK: - Summary excerpt + parser

    func testBuildExtendedKeepsFirstAndLastMessagesWithMarker() {
        var lines: [String] = []
        for i in 1...30 {
            let role = i.isMultiple(of: 2) ? "assistant" : "user"
            let content = "msg-\(i)"
            if role == "assistant" {
                lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(content)"}],"stop_reason":"end_turn"}}"#)
            } else {
                lines.append(#"{"type":"user","message":{"role":"user","content":"\#(content)"}}"#)
            }
        }
        let text = lines.joined(separator: "\n")
        let result = AgentTranscriptExcerpt.buildExtended(fromText: text, provider: .claude)

        XCTAssertTrue(result.contains("msg-1"), "Anfangs-Messages müssen erhalten bleiben")
        XCTAssertTrue(result.contains("msg-30"), "Ende-Messages müssen erhalten bleiben")
        XCTAssertTrue(result.contains("trimmed for brevity"), "Truncation-Marker erwartet bei > 24 Messages")
    }

    func testBuildExtendedShortSessionContainsAllMessages() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn"}}"#
        ]
        let result = AgentTranscriptExcerpt.buildExtended(fromText: lines.joined(separator: "\n"), provider: .claude)
        XCTAssertTrue(result.contains("hi"))
        XCTAssertTrue(result.contains("hello"))
        XCTAssertFalse(result.contains("trimmed"))
    }

    func testParseSummaryExtractsHeadlineAndDetails() {
        let raw = """
        HEADLINE: Refactor login flow with new validation rules
        DETAILS:
        - Aufgabe: Login-Flow überarbeiten
        - Änderungen: neue Validatoren, Tests grün
        - Stand: Branch ready für Review
        """
        let parsed = AgentSessionSummarizer.parseSummary(raw)
        XCTAssertEqual(parsed.headline, "Refactor login flow with new validation rules")
        XCTAssertTrue(parsed.details.contains("Login-Flow überarbeiten"))
        XCTAssertTrue(parsed.details.contains("Branch ready"))
    }

    func testParseSummaryToleratesPreambleAndStripsTrailingPunctuation() {
        let raw = """
        Sure, here is the summary:
        HEADLINE: Token rotation fix.
        DETAILS:
        Some details here.
        """
        let parsed = AgentSessionSummarizer.parseSummary(raw)
        XCTAssertEqual(parsed.headline, "Token rotation fix")
        XCTAssertEqual(parsed.details, "Some details here.")
    }

    func testParseSummaryReturnsEmptyOnGarbage() {
        let parsed = AgentSessionSummarizer.parseSummary("")
        XCTAssertEqual(parsed.headline, "")
        XCTAssertEqual(parsed.details, "")
    }

    // MARK: - Session summary persistence

    func testSetSessionSummaryPersistsValue() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        let summary = AgentSessionSummary(
            headline: "Auth flow refactor",
            details: "Touched login.rs and session.rs",
            generatedAt: Date(timeIntervalSinceReferenceDate: 1_000_000),
            transcriptDigest: "size=1234;mtime=5678"
        )
        try store.setSessionSummary(id: session.id, summary: summary)
        let stored = store.loadWorkspace().sessions.first { $0.id == session.id }?.summary
        XCTAssertEqual(stored?.headline, "Auth flow refactor")
        XCTAssertEqual(stored?.details, "Touched login.rs and session.rs")
        XCTAssertEqual(stored?.transcriptDigest, "size=1234;mtime=5678")
    }

    func testSetSessionSummaryWithNilClearsValue() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let session = try store.createSession(
            provider: .claude,
            projectPath: NSTemporaryDirectory(),
            title: "Claude Chat"
        )
        try store.setSessionSummary(
            id: session.id,
            summary: AgentSessionSummary(headline: "x", details: "y", generatedAt: Date())
        )
        try store.setSessionSummary(id: session.id, summary: nil)
        XCTAssertNil(store.loadWorkspace().sessions.first { $0.id == session.id }?.summary)
    }

    // MARK: - Project icon resolver

    func testProjectIconResolverPicksPublicFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let favicon = publicDir.appendingPathComponent("favicon.png")
        try Data([0x89]).write(to: favicon)

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/favicon.png")
    }

    func testProjectIconResolverPrefersAppleTouchIconOverFavicon() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let publicDir = projectURL.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        try Data([0x89]).write(to: publicDir.appendingPathComponent("favicon.ico"))
        try Data([0x89]).write(to: publicDir.appendingPathComponent("apple-touch-icon.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "public/apple-touch-icon.png", "PNG mit hoher Auflösung muss vor .ico gewinnen")
    }

    func testProjectIconResolverFallsBackToRepoRoot() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let result = AgentProjectIconResolver.findIconRelativePath(in: projectURL.path)
        XCTAssertEqual(result, "logo.png")
    }

    func testProjectIconResolverReturnsNilForEmptyRepo() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        XCTAssertNil(AgentProjectIconResolver.findIconRelativePath(in: projectURL.path))
    }

    // MARK: - Project metadata persistence

    func testRenameProjectPersistsTrimmedName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Old Name")
        try store.renameProject(id: project.id, name: "  New Name  ")
        let workspace = store.loadWorkspace()
        XCTAssertEqual(workspace.projects.first?.name, "New Name")
    }

    func testRenameProjectIgnoresEmptyName() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "Stable Name")
        try store.renameProject(id: project.id, name: "   ")
        XCTAssertEqual(store.loadWorkspace().projects.first?.name, "Stable Name")
    }

    func testSetProjectColorPersists() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectColor(id: project.id, color: "#FF453A")
        XCTAssertEqual(store.loadWorkspace().projects.first?.color, "#FF453A")
    }

    func testApplyAutoResolvedProjectIconStoresPathAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        let updated = store.loadWorkspace().projects.first
        XCTAssertEqual(updated?.iconRelativePath, "public/favicon.png")
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testApplyAutoResolvedWithNilStillMarksAttempted() throws {
        // Wenn kein Icon gefunden wurde, müssen wir trotzdem `attempted=true`
        // setzen, damit der nächste Reload nicht erneut scannt.
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: nil)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertEqual(updated?.iconAutoLookupAttempted, true)
    }

    func testClearProjectIconResetsBothSlotsAndAttemptedFlag() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory(), name: "p")
        try store.setProjectCustomIcon(id: project.id, absolutePath: "/tmp/x.png")
        try store.applyAutoResolvedProjectIcon(id: project.id, relativePath: "public/favicon.png")
        try store.clearProjectIcon(id: project.id)
        let updated = store.loadWorkspace().projects.first
        XCTAssertNil(updated?.iconRelativePath)
        XCTAssertNil(updated?.customIconAbsolutePath)
        XCTAssertNil(updated?.iconAutoLookupAttempted)
    }

    func testProjectResolvedIconURLPrefersCustomOverRelative() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let custom = projectURL.appendingPathComponent("custom.png")
        try Data([0x89]).write(to: custom)
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: custom.path
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "custom.png")
    }

    func testProjectResolvedIconURLFallsBackToRelativeWhenCustomMissing() throws {
        let projectURL = try makeTempProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try Data([0x89]).write(to: projectURL.appendingPathComponent("logo.png"))

        let project = AgentProject(
            name: "p",
            path: projectURL.path,
            iconRelativePath: "logo.png",
            customIconAbsolutePath: "/nonexistent/path.png"
        )
        XCTAssertEqual(project.resolvedIconURL?.lastPathComponent, "logo.png")
    }

    // MARK: - Helpers

    private func makeTempProjectDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AgentSessions.json")
    }

    // MARK: - Drag-and-drop reordering

    func testReorderProjectsAssignsSequentialSortIndices() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        // Drei Test-Projekte mit unterschiedlichen Pfaden anlegen.
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "p2", name: "B", createdManually: true)
        let p3 = try store.upsertProject(path: NSTemporaryDirectory() + "p3", name: "C", createdManually: true)

        // C, A, B — eine vom Default-Order abweichende Reihenfolge.
        try store.reorderProjects(orderedIDs: [p3.id, p1.id, p2.id])

        let sorted = AgentSessionStore.sortedProjects(store.loadWorkspace().projects)
        XCTAssertEqual(sorted.map(\.id), [p3.id, p1.id, p2.id])
        XCTAssertEqual(sorted.map(\.sortIndex), [0, 1, 2])
    }

    func testReorderSessionsAffectsOnlyTargetProject() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "drag-p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "drag-p2", name: "B", createdManually: true)
        let s1 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S1")
        let s2 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S2")
        let s3 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S3")
        let other = try store.createSession(provider: .claude, projectPath: p2.path, title: "Other")

        // Innerhalb p1 umordnen: S3, S1, S2
        try store.reorderSessions(in: p1.id, orderedIDs: [s3.id, s1.id, s2.id])

        let workspace = store.loadWorkspace()
        let p1Sessions = AgentSessionStore.sortedSessions(
            workspace.sessions.filter { $0.projectID == p1.id }
        )
        XCTAssertEqual(p1Sessions.map(\.id), [s3.id, s1.id, s2.id])
        // Andere Projekt-Session unverändert.
        let otherSnapshot = workspace.sessions.first { $0.id == other.id }
        XCTAssertNotNil(otherSnapshot)
        XCTAssertEqual(otherSnapshot?.projectID, p2.id)
    }

    func testReorderSessionsWithSameOrderIsNoOpAfterSortIndicesExist() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "noop-p1", name: "A", createdManually: true)
        let first = try store.createSession(provider: .claude, projectPath: project.path, title: "S1")
        let second = try store.createSession(provider: .claude, projectPath: project.path, title: "S2")
        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])
        let before = store.loadWorkspace()

        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])

        XCTAssertEqual(store.loadWorkspace(), before)
    }

    func testReorderAndMoveIgnoreStaleIDs() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "stale-p1", name: "A", createdManually: true)
        let session = try store.createSession(provider: .claude, projectPath: project.path, title: "S1")
        let before = store.loadWorkspace()

        try store.reorderSessions(in: project.id, orderedIDs: [UUID()])
        try store.moveSessionToProject(sessionID: session.id, newProjectID: UUID(), targetIndex: 0)

        XCTAssertEqual(store.loadWorkspace(), before)
    }

    func testAgentDragDropPlannerBuildsSessionReorderPlanForLowerToUpperDrop() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: second.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: first.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .reorder(projectID: project.id, orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerBuildsSessionReorderPlanForUpperToLowerDrop() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: second.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .reorder(projectID: project.id, orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerPersistsUpperToLowerSessionReorder() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "dnd-down", name: "Repo", createdManually: true)
        let first = try store.createSession(provider: .claude, projectPath: project.path, title: "First")
        let second = try store.createSession(provider: .claude, projectPath: project.path, title: "Second")
        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])
        let workspace = store.loadWorkspace()

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: second.id,
            workspace: workspace
        )

        guard case .reorder(let projectID, let orderedIDs) = plan else {
            return XCTFail("Expected reorder plan for downward session drop")
        }
        try store.reorderSessions(in: projectID, orderedIDs: orderedIDs)

        let reloaded = store.loadWorkspace()
        let sortedIDs = AgentSessionStore.sortedSessions(reloaded.sessions.filter { $0.projectID == project.id }).map(\.id)
        XCTAssertEqual(sortedIDs, [second.id, first.id])
    }

    func testAgentDragDropPlannerTreatsSelfDropAsNoOp() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: first.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .none)
    }

    func testAgentDragDropPlannerBuildsCrossProjectMovePlan() {
        let source = AgentProject(name: "Source", path: "/tmp/source")
        let target = AgentProject(name: "Target", path: "/tmp/target")
        let mover = AgentChatSession(provider: .claude, projectID: source.id, title: "Mover")
        let targetSession = AgentChatSession(provider: .claude, projectID: target.id, title: "Target", sortIndex: 0)
        let workspace = AgentWorkspace(projects: [source, target], sessions: [mover, targetSession])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: mover.id, sourceProjectID: source.id),
            targetProjectID: target.id,
            beforeSessionID: targetSession.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .move(sessionID: mover.id, newProjectID: target.id, targetIndex: 0))
    }

    func testAgentDragDropPlannerBuildsProjectReorderPlan() {
        let first = AgentProject(name: "First", path: "/tmp/first", sortIndex: 0)
        let second = AgentProject(name: "Second", path: "/tmp/second", sortIndex: 1)

        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: DraggableProject(projectID: second.id),
            beforeProjectID: first.id,
            visibleProjects: [first, second]
        )

        XCTAssertEqual(plan, .reorder(orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerBuildsProjectReorderPlanForUpperToLowerDrop() {
        let first = AgentProject(name: "First", path: "/tmp/first", sortIndex: 0)
        let second = AgentProject(name: "Second", path: "/tmp/second", sortIndex: 1)

        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: DraggableProject(projectID: first.id),
            beforeProjectID: second.id,
            visibleProjects: [first, second]
        )

        XCTAssertEqual(plan, .reorder(orderedIDs: [second.id, first.id]))
    }

    func testMoveSessionToProjectInsertsAtTargetIndex() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "move-p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "move-p2", name: "B", createdManually: true)
        let s1 = try store.createSession(provider: .claude, projectPath: p2.path, title: "T1")
        let s2 = try store.createSession(provider: .claude, projectPath: p2.path, title: "T2")
        let mover = try store.createSession(provider: .claude, projectPath: p1.path, title: "Mover")
        try store.reorderSessions(in: p2.id, orderedIDs: [s1.id, s2.id])

        // Mover von p1 nach p2 verschieben, an Position 1 (zwischen T1 und T2).
        try store.moveSessionToProject(sessionID: mover.id, newProjectID: p2.id, targetIndex: 1)

        let workspace = store.loadWorkspace()
        let p2Sessions = AgentSessionStore.sortedSessions(
            workspace.sessions.filter { $0.projectID == p2.id }
        )
        XCTAssertEqual(p2Sessions.map(\.id), [s1.id, mover.id, s2.id])

        let updatedMover = workspace.sessions.first { $0.id == mover.id }
        XCTAssertEqual(updatedMover?.projectID, p2.id)
    }

    func testSortedProjectsPrefersExplicitSortIndex() {
        let now = Date()
        let p1 = AgentProject(id: UUID(), name: "Latest", path: "/a", createdAt: now, updatedAt: now, sortIndex: nil)
        let p2 = AgentProject(id: UUID(), name: "Pinned", path: "/b", createdAt: now.addingTimeInterval(-1000), updatedAt: now.addingTimeInterval(-1000), sortIndex: 0)
        let sorted = AgentSessionStore.sortedProjects([p1, p2])
        // Explizit gesetzter sortIndex schlägt jüngeres updatedAt.
        XCTAssertEqual(sorted.first?.id, p2.id)
    }

    // MARK: - ThemeManager.resolve

    func testThemeResolveOverrideLightAlwaysReturnsLight() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: NSAppearance(named: .darkAqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: NSAppearance(named: .aqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .light, systemAppearance: nil),
            .light
        )
    }

    func testThemeResolveOverrideDarkAlwaysReturnsDark() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .dark, systemAppearance: NSAppearance(named: .aqua)),
            .dark
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .dark, systemAppearance: NSAppearance(named: .darkAqua)),
            .dark
        )
    }

    func testThemeResolveSystemFollowsAppearance() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: NSAppearance(named: .aqua)),
            .light
        )
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: NSAppearance(named: .darkAqua)),
            .dark
        )
    }

    func testThemeResolveSystemFallsBackToDarkWhenAppearanceUnknown() {
        XCTAssertEqual(
            ThemeManager.resolve(override: .system, systemAppearance: nil),
            .dark
        )
    }

    func testAppearanceOverridePreferredColorSchemeMapping() {
        XCTAssertNil(AppearanceOverride.system.preferredColorScheme)
        XCTAssertEqual(AppearanceOverride.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearanceOverride.dark.preferredColorScheme, .dark)
    }

    func testClaudeThemeNameMapping() {
        XCTAssertEqual(ClaudeThemeWriter.claudeThemeName(for: .light), "light-ansi")
        XCTAssertEqual(ClaudeThemeWriter.claudeThemeName(for: .dark), "dark-ansi")
    }
}
