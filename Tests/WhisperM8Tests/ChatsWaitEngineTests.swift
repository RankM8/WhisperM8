import XCTest
@testable import WhisperM8

// MARK: - Wait-Prädikat-Logik (pur, ohne Filesystem-Watching)

/// Testet die reine Übergangs-Bewertung der Wait-Engine über den internen
/// `evaluate`-Pfad, gespeist mit synthetischen Runtime-Infos.
final class ChatsWaitPredicateTests: XCTestCase {
    private func entry(_ title: String = "t") -> ChatsSessionEntry {
        ChatsSessionEntry(
            session: AgentChatSession(provider: .claude, projectID: UUID(), title: title),
            projectName: "proj", projectPath: "/tmp/proj")
    }

    private func info(_ status: AgentSessionRuntimeStatus?, revision: Int? = 100) -> ChatsRuntimeInfo {
        ChatsRuntimeInfo(status: status, source: "transcriptEstimate", since: Date(),
                         revision: revision, transcriptPath: "/tmp/x.jsonl", transcriptSizeBytes: revision,
                         availability: .available)
    }

    func testAttentionFiresOnWorkingToAwaitingInput() {
        let engine = ChatsWaitEngine(entries: [entry()], predicate: .attention, sinceRevision: nil, timeout: 1)
        let event = engine.evaluateForTest(entry: entry(), previous: .working, current: info(.awaitingInput))
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.to, .awaitingInput)
    }

    func testAttentionFiresOnWorkingToIdle() {
        let engine = ChatsWaitEngine(entries: [entry()], predicate: .attention, sinceRevision: nil, timeout: 1)
        XCTAssertNotNil(engine.evaluateForTest(entry: entry(), previous: .working, current: info(.idle)))
    }

    func testAttentionDoesNotFireOnIdleToIdle() {
        let engine = ChatsWaitEngine(entries: [entry()], predicate: .attention, sinceRevision: nil, timeout: 1)
        XCTAssertNil(engine.evaluateForTest(entry: entry(), previous: .idle, current: info(.idle)))
    }

    func testAttentionDoesNotFireOnWorkingToWorking() {
        let engine = ChatsWaitEngine(entries: [entry()], predicate: .attention, sinceRevision: nil, timeout: 1)
        XCTAssertNil(engine.evaluateForTest(entry: entry(), previous: .working, current: info(.working)))
    }

    func testIdlePredicateOnlyFiresOnTurnEnd() {
        let engine = ChatsWaitEngine(entries: [entry()], predicate: .idle, sinceRevision: nil, timeout: 1)
        XCTAssertNotNil(engine.evaluateForTest(entry: entry(), previous: .working, current: info(.idle)))
        XCTAssertNil(engine.evaluateForTest(entry: entry(), previous: .idle, current: info(.awaitingInput)))
    }

    func testStatusChangeFiresOnAnyTransition() {
        let engine = ChatsWaitEngine(entries: [entry()], predicate: .statusChange, sinceRevision: nil, timeout: 1)
        XCTAssertNotNil(engine.evaluateForTest(entry: entry(), previous: .idle, current: info(.working)))
        // Kein previous (erste Beobachtung) → kein statusChange-Event.
        XCTAssertNil(engine.evaluateForTest(entry: entry(), previous: nil, current: info(.working)))
    }

    func testPredicateParsing() {
        XCTAssertEqual(ChatsWaitEngine.Predicate.parse("attention"), .attention)
        XCTAssertEqual(ChatsWaitEngine.Predicate.parse("idle"), .idle)
        XCTAssertEqual(ChatsWaitEngine.Predicate.parse("statusChange"), .statusChange)
        XCTAssertNil(ChatsWaitEngine.Predicate.parse("banane"))
    }
}
