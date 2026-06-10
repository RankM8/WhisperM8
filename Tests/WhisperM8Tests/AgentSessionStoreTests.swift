import Foundation
import XCTest
@testable import WhisperM8

final class AgentSessionStoreTests: XCTestCase {
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

    func testRemoveImportedBackgroundSessionsDropsAutoImportedAgents() {
        // Sessions, die via createdManually=false als .backgroundChat
        // angelegt wurden (frueherer Roster-Import, Phase 6), sollen beim
        // naechsten Workspace-Load wegfliegen. Vom User selbst gespawnte
        // BG-Agents (createdManually=true) bleiben erhalten.
        let projectID = UUID()
        let userOwned = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "Mein eigener BG",
            createdAt: Date(),
            lastActivityAt: Date(),
            createdManually: true,
            kind: .backgroundChat,
            backgroundShortID: "self1234"
        )
        let imported = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "Importierter BG",
            createdAt: Date(),
            lastActivityAt: Date(),
            createdManually: false,
            kind: .backgroundChat,
            backgroundShortID: "imp12345"
        )
        let importedWithoutFlag = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "Legacy import (no flag)",
            createdAt: Date(),
            lastActivityAt: Date(),
            createdManually: nil,
            kind: .backgroundChat,
            backgroundShortID: "leg12345"
        )
        let normalChat = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "Normal chat",
            createdAt: Date(),
            lastActivityAt: Date(),
            createdManually: false
        )

        var workspace = AgentWorkspace(
            projects: [],
            sessions: [userOwned, imported, importedWithoutFlag, normalChat]
        )
        AgentSessionStore.removeImportedBackgroundSessions(from: &workspace)
        let remaining = Set(workspace.sessions.map(\.id))
        XCTAssertTrue(remaining.contains(userOwned.id))
        XCTAssertTrue(remaining.contains(normalChat.id), "non-BG-Sessions duerfen nicht angefasst werden")
        XCTAssertFalse(remaining.contains(imported.id))
        XCTAssertFalse(remaining.contains(importedWithoutFlag.id))
    }

    func testRemoveOrphanBackgroundSessionsDropsClosedBgWithoutShortID() {
        let projectID = UUID()
        let kept = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "BG with ID",
            status: .closed,
            createdAt: Date(),
            lastActivityAt: Date(),
            kind: .backgroundChat,
            backgroundShortID: "abc12345"
        )
        let archivedOrphan = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "BG archived orphan",
            status: .archived,
            createdAt: Date(),
            lastActivityAt: Date(),
            kind: .backgroundChat,
            backgroundShortID: nil
        )
        let closedOrphan = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "BG closed orphan",
            status: .closed,
            createdAt: Date(),
            lastActivityAt: Date(),
            kind: .backgroundChat,
            backgroundShortID: ""
        )
        let pendingOrphanKept = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "BG pending (spawn maybe still running)",
            status: .pending,
            createdAt: Date(),
            lastActivityAt: Date(),
            kind: .backgroundChat,
            backgroundShortID: nil
        )
        let normalChatKept = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: projectID,
            title: "Normal chat (no kind)",
            status: .closed,
            createdAt: Date(),
            lastActivityAt: Date()
        )

        var workspace = AgentWorkspace(
            projects: [],
            sessions: [kept, archivedOrphan, closedOrphan, pendingOrphanKept, normalChatKept]
        )
        AgentSessionStore.removeOrphanBackgroundSessions(from: &workspace)
        let remaining = Set(workspace.sessions.map(\.id))
        XCTAssertTrue(remaining.contains(kept.id))
        XCTAssertTrue(remaining.contains(pendingOrphanKept.id))
        XCTAssertTrue(remaining.contains(normalChatKept.id))
        XCTAssertFalse(remaining.contains(archivedOrphan.id))
        XCTAssertFalse(remaining.contains(closedOrphan.id))
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
}
