import XCTest
@testable import WhisperM8

/// Sammel-Starts starten je Sitzung höchstens einen Chat (Paket b zum
/// Befund 13.11.2026: nie zwei Prozesse auf einer Sitzung).
@MainActor
final class AgentCollectiveStartPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ id: String?, provider: AgentProvider = .claude, created: TimeInterval = 0,
                      active: TimeInterval = 0, manual: Bool? = nil) -> AgentChatSession {
        var session = AgentChatSession(provider: provider, projectID: UUID(), externalSessionID: id, title: "t",
                                       createdAt: t0.addingTimeInterval(created),
                                       lastActivityAt: t0.addingTimeInterval(active))
        session.createdManually = manual
        return session
    }

    /// Fall aus dem echten Workspace: Fin (16:27:18) und ein 29 s später
    /// angelegter Eintrag auf derselben ID — der spätere wurde zuletzt
    /// angefasst (Start setzt lastActivityAt) und darf trotzdem nicht gewinnen.
    func testOlderChatKeepsTheSessionDespiteNewerActivity() {
        let fin = chat("1f353dce", created: 0, active: 10), late = chat("1F353DCE", created: 29, active: 100)
        let other = chat("aa82d0ba")
        let plan = AgentCollectiveStartPlanner.plan([late.id, fin.id, other.id], sessions: [fin, late, other])
        XCTAssertEqual(plan.start, [fin.id, other.id])
        XCTAssertEqual(plan.skipped, [late.id])
        XCTAssertEqual(plan.keeperOf[late.id], fin.id)
    }

    func testManuallyCreatedChatBeatsOlderImport() {
        let imported = chat("x", created: 0), manual = chat("x", created: 50, manual: true)
        let plan = AgentCollectiveStartPlanner.plan([imported.id, manual.id], sessions: [imported, manual])
        XCTAssertEqual(plan.start, [manual.id])
        XCTAssertEqual(plan.skipped, [imported.id])
    }

    func testSameRuleAsChatsDuplicates() {
        let a = chat("x", created: 5), b = chat("x", created: 1), c = chat("x", created: 9, manual: true)
        let group = AgentSessionDuplicateGroup.groups(in: AgentWorkspace(projects: [], sessions: [a, b, c])).first
        let plan = AgentCollectiveStartPlanner.plan([a.id, b.id, c.id], sessions: [a, b, c])
        XCTAssertEqual(plan.start, [group?.keeper.id].compactMap { $0 })
        XCTAssertEqual(group?.keeper.id, c.id)
    }

    func testUnboundChatsAlwaysStartAndOrderIsPreserved() {
        let first = chat("x", created: 0), second = chat("x", created: 1), unbound = chat(nil), empty = chat("")
        let plan = AgentCollectiveStartPlanner.plan([unbound.id, second.id, empty.id, first.id],
                                                    sessions: [first, second, unbound, empty])
        XCTAssertEqual(plan.start, [unbound.id, empty.id, first.id], "ungebunden und leere ID starten immer")
        XCTAssertEqual(plan.skipped, [second.id])
    }

    func testSameIDUnderDifferentProvidersIsNoConflict() {
        let claude = chat("x"), codex = chat("x", provider: .codex)
        let plan = AgentCollectiveStartPlanner.plan([claude.id, codex.id], sessions: [claude, codex])
        XCTAssertEqual(plan.start, [claude.id, codex.id])
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    // MARK: Beleg aus der eigenen Hook-Event-Datei (Vic, 13.11.2026)

    private func line(_ id: String, event: String = "UserPromptSubmit", source: String? = nil) -> String {
        var line = "{\"session_id\":\"\(id)\",\"transcript_path\":\"/p/\(id).jsonl\",\"hook_event_name\":\"\(event)\""
        if let source { line += ",\"source\":\"\(source)\"" }
        return line + "}"
    }

    func testEvidenceScanDistinguishesCreatedMentionedAndNone() {
        typealias E = AgentSessionOwnershipEvidence
        let created = [line("aaa", event: "SessionStart", source: "startup"), line("aaa")].joined(separator: "\n")
        let resumed = [line("bbb", event: "SessionStart", source: "startup"),
                       line("aaa", event: "SessionStart", source: "resume"), line("aaa")].joined(separator: "\n")
        let pathOnly = "{\"session_id\":\"ccc\",\"transcript_path\":\"/p/aaa.jsonl\"}"
        func scan(_ text: String, _ id: String, fork: Bool = false) -> E {
            E.scan(data: Data(text.utf8), sessionID: id, forkCreates: fork)
        }
        XCTAssertEqual(scan(created, "aaa"), .created)
        XCTAssertEqual(scan(created, "AAA"), .created, "ID ohne Groß/Klein")
        XCTAssertEqual(scan(resumed, "aaa"), .mentioned, "nur fortgesetzt")
        XCTAssertEqual(scan(resumed, "bbb"), .created)
        XCTAssertEqual(scan(pathOnly, "aaa"), .noEvidence, "nur im Pfad erwähnt")
        XCTAssertEqual(scan("{\"parent_session_id\":\"aaa\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}", "aaa"),
                       .noEvidence, "anderer Schlüssel mit gleichem Ende")
        XCTAssertEqual(scan(line("aaa", event: "SessionStart", source: "clear"), "aaa"), .created)
        XCTAssertEqual(scan(line("aaa", event: "SessionStart", source: "fork"), "aaa", fork: true), .created)
        XCTAssertEqual(scan(line("aaa", event: "SessionStart", source: "fork"), "aaa"), .mentioned,
                       "fork im Ursprungschat (/background-Worker) legt nichts für ihn an")
        XCTAssertEqual(scan(created + "\n", "aaa"), .created, "letzte Zeile mit Newline")
        XCTAssertEqual(scan("", "aaa"), .noEvidence)
        XCTAssertEqual(E.read(eventFile: URL(fileURLWithPath: "/nicht/da.jsonl"), sessionID: "aaa", forkCreates: false), .noEvidence)
    }

    /// Vics Fall: Der ältere Chat erwischte das Transcript des jüngeren. Der
    /// jüngere hat die Sitzung angelegt und behält sie, obwohl „der älteste“
    /// sonst gewönne.
    func testCreatorBeatsOlderChatAndMentionBeatsNoEvidence() {
        let older = chat("x", created: 0), younger = chat("x", created: 50), third = chat("x", created: 99)
        var asked: [UUID] = []
        let plan = AgentCollectiveStartPlanner.plan(
            [older.id, younger.id, third.id], sessions: [older, younger, third],
            evidence: { session in
                asked.append(session.id)
                return session.id == younger.id ? .created : session.id == older.id ? .mentioned : .noEvidence
            })
        XCTAssertEqual(plan.start, [younger.id])
        XCTAssertEqual(Set(plan.skipped), [older.id, third.id])
        XCTAssertEqual(plan.keeperOf[older.id], younger.id)
        XCTAssertEqual(Set(asked), [older.id, younger.id, third.id])

        let noCreator = AgentCollectiveStartPlanner.plan(
            [third.id, older.id], sessions: [older, third],
            evidence: { $0.id == third.id ? .mentioned : .noEvidence })
        XCTAssertEqual(noCreator.start, [third.id], "genutzt schlägt keinen Beleg")
    }

    func testEvidenceIsOnlyAskedForRealDuplicates() {
        let single = chat("x"), unbound = chat(nil), other = chat("y")
        var asked = 0
        let plan = AgentCollectiveStartPlanner.plan([single.id, unbound.id, other.id], sessions: [single, unbound, other],
                                                    evidence: { _ in asked += 1; return .noEvidence })
        XCTAssertEqual(plan.start, [single.id, unbound.id, other.id])
        XCTAssertEqual(asked, 0, "Event-Dateien nur bei echter Dopplung lesen")
    }

    func testEqualEvidenceFallsBackToKeeperRule() {
        let older = chat("x", created: 0), younger = chat("x", created: 50)
        let plan = AgentCollectiveStartPlanner.plan([younger.id, older.id], sessions: [older, younger],
                                                    evidence: { _ in .created })
        XCTAssertEqual(plan.start, [older.id])
        // Beide haben die Sitzung beim letzten Start nur fortgesetzt (Startsperre versagt):
        // Gleichstand, es gilt wieder „der älteste“.
        let resumedBoth = AgentCollectiveStartPlanner.plan([younger.id, older.id], sessions: [older, younger],
                                                           evidence: { _ in .mentioned })
        XCTAssertEqual(resumedBoth.start, [older.id])
    }

    /// Nach `/background` steht der Worker-Start (`source: fork`) in der Datei
    /// des Ursprungschats. Wird dieser fälschlich an die Worker-ID gebunden,
    /// darf er sie nicht dem Hintergrund-Chat wegnehmen.
    func testBackgroundForkInOriginDoesNotMakeOriginTheOwner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-bgfork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let hookPaths = ClaudeHookPaths(rootDirectory: dir)
        try FileManager.default.createDirectory(at: hookPaths.eventsDirectory, withIntermediateDirectories: true)
        let origin = chat("f903", created: 0)
        var worker = chat("f903", created: 60)
        worker.kind = .backgroundChat
        try Data(([line("f5db", event: "SessionStart", source: "startup"),
                   line("f903", event: "SessionStart", source: "fork"),
                   line("5c9d", event: "SessionStart", source: "startup")].joined(separator: "\n")).utf8)
            .write(to: hookPaths.eventFileURL(localSessionID: origin.id))
        XCTAssertEqual(AgentSessionOwnershipEvidence.live(for: origin, hookPaths: hookPaths), .mentioned)
        XCTAssertEqual(AgentSessionOwnershipEvidence.live(for: worker, hookPaths: hookPaths), .noEvidence)
        var forkChat = chat("f903", created: 90)
        forkChat.forkSourceSessionID = "f5db"
        try Data(line("f903", event: "SessionStart", source: "fork").utf8)
            .write(to: hookPaths.eventFileURL(localSessionID: forkChat.id))
        XCTAssertEqual(AgentSessionOwnershipEvidence.live(for: forkChat, hookPaths: hookPaths), .created,
                       "ein echter Abzweig legt seine ID per fork an")
        let codex = chat("f903", provider: .codex)
        XCTAssertEqual(AgentSessionOwnershipEvidence.live(for: codex, hookPaths: hookPaths), .noEvidence)
    }

    /// `whisperm8 chats duplicates` darf nie den Chat zum Archivieren
    /// vorschlagen, den die Wiederaufnahme startet.
    func testChatsDuplicatesUsesTheSameOrder() {
        let older = chat("x", created: 0), younger = chat("x", created: 50)
        let evidence: (AgentChatSession) -> AgentSessionOwnershipEvidence = { $0.id == younger.id ? .created : .noEvidence }
        let group = AgentSessionDuplicateGroup.groups(in: AgentWorkspace(projects: [], sessions: [older, younger]),
                                                      evidence: evidence).first
        let plan = AgentCollectiveStartPlanner.plan([older.id, younger.id], sessions: [older, younger], evidence: evidence)
        XCTAssertEqual(group?.keeper.id, younger.id)
        XCTAssertEqual(plan.start, [younger.id])
    }

    func testCrashRecoveryUsesEventFilesAndLeavesANoticeAtTheSkippedChat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-halter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = AgentSessionStore(fileURL: dir.appendingPathComponent("ws.json"),
                                            uiStateFileURL: dir.appendingPathComponent("ui.json"))
        let project = UUID()
        // Älter, aber falsch gebunden: hat die Sitzung nur fortgesetzt.
        let wrong = try persistence.upsertSession(AgentChatSession(
            provider: .claude, projectID: project, externalSessionID: "cd00c6c0", title: "soak question",
            status: .running, createdAt: t0, lastActivityAt: t0))
        let owner = try persistence.upsertSession(AgentChatSession(
            provider: .claude, projectID: project, externalSessionID: "cd00c6c0", title: "soak bash",
            status: .running, createdAt: t0.addingTimeInterval(30), lastActivityAt: t0))
        let hookPaths = ClaudeHookPaths(rootDirectory: dir)
        try FileManager.default.createDirectory(at: hookPaths.eventsDirectory, withIntermediateDirectories: true)
        try Data((line("cd00c6c0", event: "SessionStart", source: "startup") + "\n").utf8)
            .write(to: hookPaths.eventFileURL(localSessionID: owner.id))
        try Data((line("eeee", event: "SessionStart", source: "startup") + "\n"
                  + line("cd00c6c0", event: "SessionStart", source: "resume") + "\n").utf8)
            .write(to: hookPaths.eventFileURL(localSessionID: wrong.id))
        let markerURL = dir.appendingPathComponent("marker.json")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [wrong.id, owner.id])
        let notices = AgentCollectiveStartNotices()

        let resumed = AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(),
            windowStore: AgentWindowStore(persistence: persistence),
            store: persistence,
            isEnabled: true,
            hookPaths: hookPaths,
            notices: notices
        )

        XCTAssertEqual(resumed, [owner.id], "der Anleger gewinnt, nicht der ältere")
        let message = try XCTUnwrap(notices.takeMessage(for: wrong.id))
        XCTAssertTrue(message.contains("soak bash"), "nennt den Halter")
        XCTAssertNil(notices.takeMessage(for: wrong.id), "nur einmal")
        XCTAssertNil(notices.takeMessage(for: owner.id))
    }

    func testCrashRecoveryResumesOnlyOneChatPerSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-sammelstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = AgentSessionStore(fileURL: dir.appendingPathComponent("ws.json"),
                                            uiStateFileURL: dir.appendingPathComponent("ui.json"))
        let project = UUID()
        let owner = try persistence.upsertSession(AgentChatSession(
            provider: .claude, projectID: project, externalSessionID: "cd00c6c0", title: "soak bash",
            status: .running, createdAt: t0, lastActivityAt: t0))
        var wrongSession = AgentChatSession(
            provider: .claude, projectID: project, externalSessionID: "cd00c6c0", title: "soak question",
            status: .running, createdAt: t0.addingTimeInterval(3), lastActivityAt: t0.addingTimeInterval(60))
        wrongSession.shouldLaunchOnOpen = true // altes Flag
        let wrong = try persistence.upsertSession(wrongSession)
        let windowStore = AgentWindowStore(persistence: persistence)
        let markerURL = dir.appendingPathComponent("marker.json")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [wrong.id, owner.id])

        let resumed = AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(),
            windowStore: windowStore,
            store: persistence,
            isEnabled: true,
            hookPaths: ClaudeHookPaths(rootDirectory: dir),
            notices: AgentCollectiveStartNotices()
        )

        XCTAssertEqual(resumed, [owner.id])
        XCTAssertNotNil(windowStore.windowID(containingTab: wrong.id), "Tab zurück, sonst sähe niemand den Hinweis")
        XCTAssertNotNil(windowStore.windowID(containingTab: owner.id))
        let sessions = Dictionary(uniqueKeysWithValues: persistence.loadWorkspace().sessions.map { ($0.id, $0) })
        XCTAssertEqual(sessions[owner.id]?.shouldLaunchOnOpen, true)
        XCTAssertNotEqual(sessions[wrong.id]?.shouldLaunchOnOpen, true)
    }
}
