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
            registry: AgentTerminalRegistry(termination: .inert),
            windowStore: windowStore,
            store: persistence,
            isEnabled: true
        )

        XCTAssertEqual(resumed, [owner.id])
        XCTAssertNil(windowStore.windowID(containingTab: wrong.id), "übersprungener Chat bekommt keinen Tab")
        XCTAssertNotNil(windowStore.windowID(containingTab: owner.id))
        let sessions = Dictionary(uniqueKeysWithValues: persistence.loadWorkspace().sessions.map { ($0.id, $0) })
        XCTAssertEqual(sessions[owner.id]?.shouldLaunchOnOpen, true)
        XCTAssertNotEqual(sessions[wrong.id]?.shouldLaunchOnOpen, true)
    }

    // MARK: Rückfall der Übernahme (Vic, 13.11.2026)

    /// Ein übernommener (laufender) Chat führt seine Sitzung weiter, auch wenn
    /// der vorgemerkte nach der Regel gewönne. Für Codex der einzige Schutz.
    func testRunningChatKeepsItsSessionAgainstAFallbackChat() {
        let adopted = chat("x", provider: .codex, created: 50), fallback = chat("X", provider: .codex, created: 0, manual: true)
        let other = chat("y", provider: .codex)
        let plan = AgentCollectiveStartPlanner.plan([fallback.id, other.id], sessions: [adopted, fallback, other],
                                                    alreadyStarted: [adopted.id])
        XCTAssertEqual(plan.start, [other.id])
        XCTAssertEqual(plan.skipped, [fallback.id])
        XCTAssertEqual(plan.keeperOf[fallback.id], adopted.id)
    }

    /// Zweiter Schub (nach dem Ende verwaister Prozesse): schon vorgemerkte
    /// Chats zählen wie laufende; ein schon vorgemerkter startet nicht doppelt.
    func testSecondBatchRespectsChatsScheduledInTheFirst() {
        let first = chat("x", created: 0), second = chat("x", created: 9), unbound = chat(nil)
        let plan = AgentCollectiveStartPlanner.plan([second.id, first.id, unbound.id], sessions: [first, second, unbound],
                                                    alreadyStarted: [first.id])
        XCTAssertEqual(plan.start, [unbound.id])
        XCTAssertEqual(plan.skipped, [second.id, first.id], "Reihenfolge der Eingabe")
        XCTAssertEqual(plan.keeperOf[second.id], first.id)
    }

    /// Ohne Laufende gilt die normale Regel, auch über Provider getrennt.
    func testWithoutRunningChatsTheUsualRuleApplies() {
        let older = chat("x", created: 0), newer = chat("x", created: 5), codex = chat("x", provider: .codex)
        let plan = AgentCollectiveStartPlanner.plan([newer.id, older.id, codex.id], sessions: [older, newer, codex],
                                                    alreadyStarted: [])
        XCTAssertEqual(plan, AgentCollectiveStartPlanner.plan([newer.id, older.id, codex.id], sessions: [older, newer, codex]))
        XCTAssertEqual(plan.start, [older.id, codex.id])
    }
}
