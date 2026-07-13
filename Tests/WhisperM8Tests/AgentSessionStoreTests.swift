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

    func testUpdateSessionNoOpLeavesWorkspaceUnchanged() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Unverändert"
        )
        let before = store.loadWorkspace()

        try store.updateSession(id: session.id) { _ in }

        XCTAssertEqual(store.loadWorkspace(), before)
    }

    func testUpdateSessionChangeBumpsLastActivityAt() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Vorher"
        )
        let oldActivity = Date(timeIntervalSince1970: 100)
        session.lastActivityAt = oldActivity
        _ = try store.upsertSession(session)

        try store.updateSession(id: session.id) { $0.title = "Nachher" }

        let updated = try XCTUnwrap(store.loadWorkspace().sessions.first)
        XCTAssertEqual(updated.title, "Nachher")
        XCTAssertGreaterThan(updated.lastActivityAt, oldActivity)
    }

    func testUpdateSessionKeepsExplicitLastActivityAt() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Vorher"
        )
        let explicitActivity = Date(timeIntervalSince1970: 200)

        try store.updateSession(id: session.id) { updated in
            updated.title = "Nachher"
            updated.lastActivityAt = explicitActivity
        }

        XCTAssertEqual(store.loadWorkspace().sessions.first?.lastActivityAt, explicitActivity)
    }

    func testUpsertProjectWithIdenticalDataIsNoOp() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8-Upsert-NoOp-\(UUID().uuidString)")
            .path
        let first = try store.upsertProject(path: path, name: "Projekt")
        let before = store.loadWorkspace()

        let second = try store.upsertProject(path: path, name: "Projekt")

        XCTAssertEqual(second, first)
        XCTAssertEqual(store.loadWorkspace(), before)
        XCTAssertEqual(second.updatedAt, first.updatedAt)
    }

    func testCreateSessionTouchesExistingProjectUpdatedAt() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8-Create-Touch-\(UUID().uuidString)")
            .path
        let project = try store.upsertProject(path: path)
        var workspace = store.loadWorkspace()
        let oldUpdatedAt = Date(timeIntervalSince1970: 100)
        workspace.projects[0].updatedAt = oldUpdatedAt
        try store.saveWorkspace(workspace)

        _ = try store.createSession(
            provider: .codex,
            projectPath: path,
            title: "Neue Session"
        )

        let updatedProject = try XCTUnwrap(
            store.loadWorkspace().projects.first(where: { $0.id == project.id })
        )
        XCTAssertGreaterThan(updatedProject.updatedAt, oldUpdatedAt)
    }

    func testMergeIndexedSessionsWithIdenticalValuesIsNoOp() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let indexed = IndexedAgentSession(
            provider: .codex,
            externalSessionID: "identischer-merge",
            cwd: FileManager.default.temporaryDirectory
                .appendingPathComponent("WhisperM8-Merge-NoOp-\(UUID().uuidString)")
                .path,
            title: "Indexer-Session",
            model: "gpt-5.5",
            reasoningEffort: "medium",
            createdAt: Date(timeIntervalSince1970: 100),
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )
        try store.mergeIndexedSessions([indexed])
        let before = store.loadWorkspace()

        try store.mergeIndexedSessions([indexed])

        XCTAssertEqual(store.loadWorkspace(), before)
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

    func testDeleteProjectRemovesProjectAndItsSessionsOnly() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8DeleteProject-\(UUID().uuidString)")
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = AgentSessionStore(fileURL: fileURL)
        let pathA = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjA-\(UUID().uuidString)").path
        let pathB = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjB-\(UUID().uuidString)").path

        let a1 = try store.createSession(provider: .claude, projectPath: pathA, title: "A1")
        _ = try store.createSession(provider: .claude, projectPath: pathA, title: "A2")
        let b1 = try store.createSession(provider: .codex, projectPath: pathB, title: "B1")
        let projectA = a1.projectID

        try store.deleteProject(id: projectA)

        let workspace = store.loadWorkspace()
        XCTAssertFalse(workspace.projects.contains { $0.id == projectA }, "Projekt A entfernt")
        XCTAssertTrue(workspace.projects.contains { $0.id == b1.projectID }, "Projekt B bleibt")
        XCTAssertEqual(workspace.sessions.map(\.id), [b1.id], "nur die Session von Projekt B bleibt übrig")
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

    func testAgentSessionStoreKeepsBindingWhenNoConversationExists() throws {
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

        // Negative Evidenz (kein Transcript gefunden) darf die Bindung NICHT
        // löschen — nur Auto-Launch wird entschärft; der Caller stoppt den
        // Launch mit sichtbarer Meldung (AgentResumeTranscriptMissingError).
        XCTAssertEqual(result?.outcome, .resetInvalid("missing-claude-id"))
        XCTAssertEqual(repaired.externalSessionID, "missing-claude-id")
        XCTAssertTrue(repaired.hasLaunchedInitialPrompt)
        XCTAssertFalse(repaired.shouldLaunchOnOpen ?? false)
        XCTAssertEqual(store.loadWorkspace().sessions.first?.externalSessionID, "missing-claude-id")
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
        // Altersgrenze: nur ALTE ungebundene Sessions werden geräumt —
        // frische könnten noch auf Hook-Binding/Indexer-Adoption warten.
        let unresumable = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Claude Chat",
            status: .closed,
            hasLaunchedInitialPrompt: true,
            createdAt: Date().addingTimeInterval(-7200)
        )
        let freshUnbound = AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: "Frischer Chat",
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
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: [unresumable, freshUnbound, resumable]))

        try store.mergeIndexedSessions([])

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertFalse(sessions.contains { $0.id == unresumable.id })
        XCTAssertTrue(sessions.contains { $0.id == freshUnbound.id }, "Frische ungebundene Session darf nicht vor der Adoption geräumt werden")
        XCTAssertTrue(sessions.contains { $0.id == resumable.id })
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
            hasLaunchedInitialPrompt: true,
            createdAt: Date().addingTimeInterval(-7200)
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

    // MARK: - Archivieren / Wiederherstellen

    func testArchiveSessionSetsStatusAndArchivedAt() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Zu archivieren"
        )

        try store.archiveSession(id: session.id)

        let archived = store.loadWorkspace().sessions.first
        XCTAssertEqual(archived?.status, .archived)
        XCTAssertNotNil(archived?.archivedAt)
    }

    func testRestoreSessionSetsClosedAndClearsArchivedAt() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Zu restaurieren"
        )
        try store.archiveSession(id: session.id)

        try store.restoreSession(id: session.id)

        let restored = store.loadWorkspace().sessions.first
        XCTAssertEqual(restored?.status, .closed)
        XCTAssertNil(restored?.archivedAt)
    }

    func testRestoreSessionBumpsLastActivityAt() throws {
        // Dokumentiert die bewusste `updateSession`-Nebenwirkung: die
        // wiederhergestellte Session soll sofort im „Zuletzt"-Scope auftauchen.
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Alt"
        )
        session.status = .archived
        session.archivedAt = Date(timeIntervalSince1970: 100)
        session.lastActivityAt = Date(timeIntervalSince1970: 100)
        _ = try store.upsertSession(session)

        try store.restoreSession(id: session.id)

        let restored = store.loadWorkspace().sessions.first
        XCTAssertNotNil(restored?.lastActivityAt)
        XCTAssertGreaterThan(restored!.lastActivityAt, Date(timeIntervalSince1970: 100))
    }

    func testRestoreSessionKeepsCreatedManuallyFlag() throws {
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let session = try store.createSession(
            provider: .claude,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Manuell erstellt"
        )
        XCTAssertEqual(store.loadWorkspace().sessions.first?.isManuallyCreated, true)

        try store.archiveSession(id: session.id)
        try store.restoreSession(id: session.id)

        XCTAssertEqual(store.loadWorkspace().sessions.first?.isManuallyCreated, true)
    }

    func testDecodeLegacyWorkspaceWithoutArchivedAt() throws {
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
              "status": "archived",
              "createdManually": true,
              "createdAt": "2026-05-09T12:00:00Z",
              "lastActivityAt": "2026-05-09T12:00:00Z"
            }
          ]
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let workspace = AgentSessionStore(fileURL: fileURL).loadWorkspace()

        XCTAssertEqual(workspace.sessions.first?.id, sessionID)
        XCTAssertEqual(workspace.sessions.first?.status, .archived)
        XCTAssertNil(workspace.sessions.first?.archivedAt)
    }

    func testArchivedAtRoundTripsThroughPersistence() throws {
        // Registry teilt In-Memory-Instanzen pro URL — für den echten
        // Disk-Roundtrip wird die geschriebene Datei direkt dekodiert.
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AgentSessionStore(fileURL: fileURL)
        let session = try store.createSession(
            provider: .codex,
            projectPath: FileManager.default.temporaryDirectory.path,
            title: "Persistiert"
        )
        try store.archiveSession(id: session.id)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(AgentWorkspace.self, from: Data(contentsOf: fileURL))

        XCTAssertEqual(onDisk.sessions.first?.status, .archived)
        XCTAssertNotNil(onDisk.sessions.first?.archivedAt)
    }

    func testMergeIndexedSessionsKeepsArchivedStatusAndTimestamp() throws {
        // Re-Scan-Absicherung: der Indexer darf archivierte Sessions nicht
        // reanimieren — Status und Archiv-Zeitstempel bleiben erhalten.
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let projectPath = FileManager.default.temporaryDirectory.path
        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .codex,
            projectPath: projectPath,
            title: "Archiviert"
        )
        session.externalSessionID = "ext-archived-1"
        session.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(session)
        try store.archiveSession(id: session.id)
        let archivedAtBefore = store.loadWorkspace().sessions.first?.archivedAt
        XCTAssertNotNil(archivedAtBefore)

        try store.mergeIndexedSessions([
            IndexedAgentSession(
                provider: .codex,
                externalSessionID: "ext-archived-1",
                cwd: projectPath,
                title: "Frischer Scan-Titel",
                model: "gpt-5.5",
                reasoningEffort: "medium",
                createdAt: Date(),
                lastActivityAt: Date().addingTimeInterval(60)
            )
        ])

        let merged = store.loadWorkspace().sessions.first
        XCTAssertEqual(merged?.status, .archived)
        XCTAssertEqual(merged?.archivedAt, archivedAtBefore)
        XCTAssertEqual(store.loadWorkspace().sessions.count, 1, "Merge darf keine Duplikat-Session anlegen")
    }

    func testMergeIndexedSessionsHealsStaleClaudeProfileStamp() throws {
        // Stempel-Selbstheilung: der Indexer kennt den realen Ablageort des
        // Transcripts. Weicht der gespeicherte Account-Stempel davon ab
        // (main ↔ Profil), muss der Merge ihn korrigieren — sonst liefe der
        // nächste Resume unterm falschen CLAUDE_CONFIG_DIR.
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let projectPath = FileManager.default.temporaryDirectory.path
        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .claude,
            projectPath: projectPath,
            title: "Main-Chat",
            claudeProfileName: "PowerUser"
        )
        session.externalSessionID = "ext-stale-stamp-1"
        session.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(session)

        // Scan findet das Transcript real unter main (claudeProfileName=nil).
        try store.mergeIndexedSessions([
            IndexedAgentSession(
                provider: .claude,
                externalSessionID: "ext-stale-stamp-1",
                cwd: projectPath,
                title: "Main-Chat",
                createdAt: Date(),
                lastActivityAt: Date(),
                claudeProfileName: nil
            )
        ])
        XCTAssertNil(store.loadWorkspace().sessions.first?.claudeProfileName)

        // Und die Gegenrichtung: Transcript real unter einem Profil-Root.
        try store.mergeIndexedSessions([
            IndexedAgentSession(
                provider: .claude,
                externalSessionID: "ext-stale-stamp-1",
                cwd: projectPath,
                title: "Main-Chat",
                createdAt: Date(),
                lastActivityAt: Date(),
                claudeProfileName: "PowerUser"
            )
        ])
        XCTAssertEqual(store.loadWorkspace().sessions.first?.claudeProfileName, "PowerUser")
    }

    func testMergeAdoptionWindowIsTwoSided() throws {
        // Review-Befund 2026-07-13: das ±5s-Fenster hatte real nur eine
        // Untergrenze — eine BELIEBIG später gestartete Session konnte einen
        // alten ungebundenen Tab kapern.
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let projectPath = FileManager.default.temporaryDirectory.path
        let store = AgentSessionStore(fileURL: fileURL)
        let createdAt = Date().addingTimeInterval(-600)
        var session = try store.createSession(
            provider: .claude,
            projectPath: projectPath,
            title: "Alter ungebundener Tab"
        )
        session.createdAt = createdAt
        session.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(session)

        // Indexer-Session 10 Minuten SPÄTER erstellt → darf NICHT adoptieren.
        try store.mergeIndexedSessions([
            IndexedAgentSession(
                provider: .claude,
                externalSessionID: "ext-viel-spaeter",
                cwd: projectPath,
                title: "Fremder späterer Chat",
                createdAt: Date(),
                lastActivityAt: Date()
            )
        ])
        let adopted = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertNil(adopted?.externalSessionID, "Session außerhalb des ±5s-Fensters darf nicht adoptiert werden")

        // Innerhalb des Fensters (±5s) klappt die Adoption weiterhin.
        try store.mergeIndexedSessions([
            IndexedAgentSession(
                provider: .claude,
                externalSessionID: "ext-zeitnah",
                cwd: projectPath,
                title: "Zeitnaher Chat",
                createdAt: createdAt.addingTimeInterval(2),
                lastActivityAt: Date()
            )
        ])
        let bound = store.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(bound?.externalSessionID, "ext-zeitnah")
    }

    func testMergeDeduplicatesSameExternalSessionIDAcrossRoots() throws {
        // Dieselbe externalSessionID aus zwei Roots (kopierte Transcripts):
        // der Merge darf nicht flip-floppen — bei vorhandenem Stempel gewinnt
        // der stempel-konforme Kandidat.
        let fileURL = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let projectPath = FileManager.default.temporaryDirectory.path
        let store = AgentSessionStore(fileURL: fileURL)
        var session = try store.createSession(
            provider: .claude,
            projectPath: projectPath,
            title: "Chat",
            claudeProfileName: "PowerUser"
        )
        session.externalSessionID = "ext-dupe-1"
        session.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(session)

        let base = Date()
        try store.mergeIndexedSessions([
            IndexedAgentSession(
                provider: .claude,
                externalSessionID: "ext-dupe-1",
                cwd: projectPath,
                title: "Chat",
                createdAt: base,
                // main-Kopie ist sogar aktueller — der Stempel-Match gewinnt trotzdem.
                lastActivityAt: base.addingTimeInterval(60),
                claudeProfileName: nil
            ),
            IndexedAgentSession(
                provider: .claude,
                externalSessionID: "ext-dupe-1",
                cwd: projectPath,
                title: "Chat",
                createdAt: base,
                lastActivityAt: base,
                claudeProfileName: "PowerUser"
            ),
        ])
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.id == session.id }?.claudeProfileName,
            "PowerUser",
            "Bei Duplikaten über Roots hinweg muss der stempel-konforme Kandidat gewinnen (kein Flip-Flop)"
        )
    }
}
