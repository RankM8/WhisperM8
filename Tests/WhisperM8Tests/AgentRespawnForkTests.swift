import XCTest
@testable import WhisperM8

/// E1/E2 (11.11.2026): Claudes Daemon führt Hintergrund-Agents als Abzweig
/// unter neuer ID weiter; daraus wurden neue Sidebar-Einträge. Außerdem
/// entstanden Doppel, wenn der Scan schneller war als die Bindung.
final class AgentRespawnForkTests: XCTestCase {
    private let original = "64306879-6eea-44b6-b29b-c71de25b4c84"
    private let fork = "84ca7666-c23f-4547-9dba-d8e020792b32"

    private var savedProvider: (() -> [String: String])!

    override func setUp() {
        super.setUp()
        savedProvider = AgentSessionStore.respawnForkOriginsProvider
    }

    override func tearDown() {
        AgentSessionStore.respawnForkOriginsProvider = savedProvider
        super.tearDown()
    }

    // MARK: Roster

    func testForkOriginReadsRespawnDispatch() {
        let dispatch: [String: Any] = [
            "source": "respawn",
            "launch": ["mode": "resume", "fork": true,
                       "sessionId": "/Users/x/.claude/projects/-repo/\(original).jsonl"],
        ]
        XCTAssertEqual(SupervisorRosterReader.forkOrigin(fromDispatch: dispatch), original)
        XCTAssertNil(SupervisorRosterReader.forkOrigin(fromDispatch: [
            "launch": ["mode": "resume", "fork": false, "sessionId": original]]), "kein Abzweig")
        XCTAssertNil(SupervisorRosterReader.forkOrigin(fromDispatch: nil))
        // Gewollter Abzweig (`claude --bg --resume A --fork-session`): eigener
        // Chat, kein Neustart — A darf nicht umgebunden werden.
        XCTAssertNil(SupervisorRosterReader.forkOrigin(fromDispatch: [
            "source": "cli",
            "launch": ["mode": "resume", "fork": true, "sessionId": "\(original).jsonl"]]))
        XCTAssertNil(SupervisorRosterReader.forkOrigin(fromDispatch: [
            "launch": ["mode": "resume", "fork": true, "sessionId": "\(original).jsonl"]]), "ohne source kein Respawn")
    }

    /// Der Rückweg nach gescheitertem Attach fragt `attachTarget` — das muss
    /// einen Daemon-Abzweig finden, sonst startete er `--resume` auf dem alten
    /// Stand und es liefen zwei Prozesse.
    func testAttachTargetFindsTheRespawnForkInTheRoster() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fork-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("daemon"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let roster: [String: Any] = ["workers": ["84ca7666": [
            "pid": Int(getpid()), "sessionId": fork, "startedAt": 1_794_430_135_755,
            "dispatch": ["source": "respawn", "launch": ["mode": "resume", "fork": true,
                                                         "sessionId": "/x/\(original).jsonl"]],
        ]]]
        try JSONSerialization.data(withJSONObject: roster).write(to: dir.appendingPathComponent("daemon/roster.json"))

        XCTAssertEqual(SupervisorRosterReader.attachTarget(forSessionID: original, configDir: dir, registryJobID: { _ in nil }),
                       .init(shortID: "84ca7666", sessionID: fork))
    }

    func testMatchPrefersOwnWorkerThenNewestLiveFork() {
        let older = SupervisorRosterReader.Worker(
            shortID: "aaaa1111", sessionID: "aaaa1111-0000", pid: 1, cwd: nil,
            forkedFromSessionID: original, startedAt: Date(timeIntervalSince1970: 100))
        let newer = SupervisorRosterReader.Worker(
            shortID: "84ca7666", sessionID: fork, pid: 2, cwd: nil,
            forkedFromSessionID: original, startedAt: Date(timeIntervalSince1970: 200))
        let dead = SupervisorRosterReader.Worker(
            shortID: "dead0000", sessionID: "dead0000-0000", pid: 3, cwd: nil,
            forkedFromSessionID: original, startedAt: Date(timeIntervalSince1970: 300))
        let alive: (Int32) -> Bool = { $0 != 3 }

        XCTAssertEqual(
            SupervisorRosterReader.match(forSessionID: original, workers: [older, newer, dead], isProcessAlive: alive),
            .init(shortID: "84ca7666", sessionID: fork), "jüngster lebender Abzweig")

        let own = SupervisorRosterReader.Worker(shortID: "64306879", sessionID: original, pid: 4, cwd: nil)
        XCTAssertEqual(
            SupervisorRosterReader.match(forSessionID: original, workers: [newer, own], isProcessAlive: alive),
            .init(shortID: "64306879", sessionID: original), "der eigene Worker geht vor")
    }

    // MARK: Start

    func testAttachToForkReportsTheNewIDForRebinding() throws {
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        var builder = AgentCommandBuilder(commandResolver: { "/usr/local/bin/\($0)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        let forkID = fork
        builder.backgroundWorkerResolver = { _, _ in .init(shortID: "84ca7666", sessionID: forkID) }
        let session = AgentChatSession(
            provider: .claude, projectID: project.id, externalSessionID: original,
            title: "Jarvis", hasLaunchedInitialPrompt: true)

        let command = try builder.command(for: session, project: project)

        XCTAssertEqual(command.arguments, ["attach", "84ca7666"])
        XCTAssertEqual(command.reboundExternalSessionID, fork)

        builder.backgroundWorkerResolver = { id, _ in .init(shortID: "64306879", sessionID: id) }
        XCTAssertNil(try builder.command(for: session, project: project).reboundExternalSessionID,
                     "eigener Worker: nichts umzubinden")
    }

    // MARK: Index-Merge

    private func makeStore(sessions: (AgentProject) -> [AgentChatSession]) throws -> (AgentSessionStore, AgentProject, URL) {
        let fileURL = makeTempStoreURL()
        let projectPath = fileURL.deletingLastPathComponent().path
        let project = AgentProject(name: "Repo", path: projectPath)
        let store = AgentSessionStore(fileURL: fileURL)
        try store.saveWorkspace(AgentWorkspace(projects: [project], sessions: sessions(project)))
        return (store, project, fileURL)
    }

    private func indexed(_ id: String, cwd: String, createdAt: Date = Date(timeIntervalSince1970: 1_000)) -> IndexedAgentSession {
        IndexedAgentSession(provider: .claude, externalSessionID: id, cwd: cwd, title: "Kopie",
                            model: nil, reasoningEffort: nil, createdAt: createdAt,
                            lastActivityAt: createdAt.addingTimeInterval(60))
    }

    func testForkCopyOfIdleChatRebindsInsteadOfNewEntry() throws {
        let (origin, copy) = (original, fork)
        AgentSessionStore.respawnForkOriginsProvider = { [copy: origin] }
        var chatID = UUID()
        let (store, project, url) = try makeStore { project in
            let chat = AgentChatSession(provider: .claude, projectID: project.id, externalSessionID: origin,
                                        title: "Jarvis", status: .closed, hasLaunchedInitialPrompt: true,
                                        createdManually: true)
            chatID = chat.id
            return [chat]
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Beide Verläufe liegen auf der Platte: Original und Kopie.
        try store.mergeIndexedSessions([indexed(origin, cwd: project.path), indexed(copy, cwd: project.path)])

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.count, 1, "keine neuen Sidebar-Einträge")
        XCTAssertEqual(sessions.first?.id, chatID)
        XCTAssertEqual(sessions.first?.externalSessionID, copy, "Chat folgt dem Agent")
        XCTAssertEqual(sessions.first?.supersededExternalSessionIDs, [origin])

        // Auch ohne lebenden Abzweig: der alte Verlauf bleibt abgelöst.
        AgentSessionStore.respawnForkOriginsProvider = { [:] }
        try store.mergeIndexedSessions([indexed(origin, cwd: project.path), indexed(copy, cwd: project.path)])
        XCTAssertEqual(store.loadWorkspace().sessions.count, 1)
    }

    func testForkCopyOfChatRunningInTabIsNotAddedAndNotRebound() throws {
        let (origin, copy) = (original, fork)
        AgentSessionStore.respawnForkOriginsProvider = { [copy: origin] }
        let saved = AgentSessionStore.attachedSessionIDsProvider
        defer { AgentSessionStore.attachedSessionIDsProvider = saved }
        AgentSessionStore.attachedSessionIDsProvider = { [] }
        var chat = AgentChatSession(provider: .claude, projectID: UUID(), externalSessionID: origin,
                                    title: "Jarvis", status: .running, hasLaunchedInitialPrompt: true)
        let (store, project, url) = try makeStore { project in
            chat.projectID = project.id
            return [chat]
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try store.applyIndexedScan([indexed(origin, cwd: project.path), indexed(copy, cwd: project.path)],
                                   activeSessionIDs: [chat.id])

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.count, 1, "die Kopie wird kein eigener Chat")
        XCTAssertEqual(sessions.first?.externalSessionID, origin, "laufender Chat bleibt auf seiner ID")
    }

    /// Ein Tab, der nur an den Agent angedockt ist, führt keine eigene
    /// Unterhaltung: Nach einem Respawn wandert der Chat mit, sonst verlöre er
    /// @self und das Board.
    func testForkCopyOfAttachedTabRebinds() throws {
        let (origin, copy) = (original, fork)
        AgentSessionStore.respawnForkOriginsProvider = { [copy: origin] }
        var chat = AgentChatSession(provider: .claude, projectID: UUID(), externalSessionID: origin,
                                    title: "Jarvis", status: .running, hasLaunchedInitialPrompt: true)
        let (store, project, url) = try makeStore { project in
            chat.projectID = project.id
            return [chat]
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = AgentSessionStore.attachedSessionIDsProvider
        defer { AgentSessionStore.attachedSessionIDsProvider = saved }
        let chatID = chat.id
        AgentSessionStore.attachedSessionIDsProvider = { [chatID] }

        try store.applyIndexedScan([indexed(origin, cwd: project.path), indexed(copy, cwd: project.path)],
                                   activeSessionIDs: [chat.id])

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.externalSessionID, copy)
    }

    func testNewTranscriptWaitsForUnboundLaunchedChatInSameProject() throws {
        AgentSessionStore.respawnForkOriginsProvider = { [:] }
        let now = Date()
        var fin = AgentChatSession(provider: .claude, projectID: UUID(), externalSessionID: nil,
                                   title: "Fin", status: .running, hasLaunchedInitialPrompt: true,
                                   createdAt: now.addingTimeInterval(-60), createdManually: true)
        let (store, project, url) = try makeStore { project in
            fin.projectID = project.id
            return [fin]
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transcript = indexed("1f353dce-783f-407c-a2d4-402c5e884d59", cwd: project.path,
                                 createdAt: now.addingTimeInterval(-31))  // 29 s nach dem Tab

        try store.applyIndexedScan([transcript], activeSessionIDs: [fin.id])
        XCTAssertEqual(store.loadWorkspace().sessions.count, 1, "kein automatisches Doppel, solange Fin bindet")

        // Hook hat gebunden → normaler Update, weiterhin ein Chat.
        try store.updateSession(id: fin.id) { $0.externalSessionID = transcript.externalSessionID }
        try store.applyIndexedScan([transcript], activeSessionIDs: [fin.id])
        XCTAssertEqual(store.loadWorkspace().sessions.count, 1)
    }

    func testManualChatLeadsWhenDuplicatesShareAnExternalID() throws {
        AgentSessionStore.respawnForkOriginsProvider = { [:] }
        let id = "1f353dce-783f-407c-a2d4-402c5e884d59"
        var auto = AgentChatSession(provider: .claude, projectID: UUID(), externalSessionID: id,
                                    title: "Auto", status: .closed, hasLaunchedInitialPrompt: true,
                                    createdAt: Date(timeIntervalSince1970: 10),
                                    lastActivityAt: Date(timeIntervalSince1970: 10))
        var manual = AgentChatSession(provider: .claude, projectID: UUID(), externalSessionID: id,
                                      title: "Fin", status: .closed, hasLaunchedInitialPrompt: true,
                                      createdAt: Date(timeIntervalSince1970: 20),
                                      lastActivityAt: Date(timeIntervalSince1970: 20), createdManually: true)
        let (store, project, url) = try makeStore { project in
            auto.projectID = project.id
            manual.projectID = project.id
            return [auto, manual]  // Auto steht zuerst im Workspace
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try store.mergeIndexedSessions([indexed(id, cwd: project.path, createdAt: Date(timeIntervalSince1970: 5_000))])

        let sessions = store.loadWorkspace().sessions
        XCTAssertEqual(sessions.count, 2, "nichts wird automatisch gelöscht oder archiviert")
        XCTAssertEqual(sessions.first { $0.id == manual.id }?.lastActivityAt, Date(timeIntervalSince1970: 5_060))
        XCTAssertEqual(sessions.first { $0.id == auto.id }?.lastActivityAt, Date(timeIntervalSince1970: 10))

        let groups = AgentSessionDuplicateGroup.groups(in: store.loadWorkspace())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.keeper.id, manual.id)
        XCTAssertEqual(groups.first?.duplicates.map(\.id), [auto.id])
    }
}
