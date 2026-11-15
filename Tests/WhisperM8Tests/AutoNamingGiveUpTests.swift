import Foundation
import XCTest
@testable import WhisperM8

/// WM8-53: Beendete Chats ohne Verlauf oder ohne echten Prompt wurden alle
/// fünf Minuten neu versucht, ohne Ende und nach jedem Start von vorn
/// (15.11.2026: 15 Chats, 727 Fehlerzeilen in sechs Stunden). Jetzt merkt sich
/// der Chat den Verzicht; neu versucht wird erst, wenn der Verlauf wächst
/// oder der Chat einen Turn beendet.
@MainActor
final class AutoNamingGiveUpTests: XCTestCase {
    private var storeURL: URL!
    private var store: AgentSessionStore!

    override func setUp() async throws {
        storeURL = makeTempStoreURL()
        store = AgentSessionStore(fileURL: storeURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func makeSession(status: AgentChatStatus) throws -> AgentChatSession {
        var session = try store.createSession(provider: .claude, projectPath: NSTemporaryDirectory(), title: "Claude Chat")
        session.externalSessionID = UUID().uuidString
        session.status = status
        session.lastActivityAt = Date(timeIntervalSince1970: 1_000_000)
        return try store.upsertSession(session)
    }

    private func current(_ id: UUID) -> AgentChatSession {
        store.loadWorkspace().sessions.first { $0.id == id }!
    }

    /// Wie `autoNameUntitledSessions` nach einem Scan: immer mit dem aktuellen
    /// Stand aus dem Store; wartet, bis ein eingereihter Versuch fertig ist.
    private func scan(_ namer: AgentSessionAutoNamer, _ id: UUID) async {
        namer.generateTitleIfNeeded(session: current(id), cwd: "/unused")
        while !namer.inFlight.isEmpty { await Task.yield() }
    }

    private func makeNamer(clock: @escaping () -> Date, title: @escaping () throws -> String) -> AgentSessionAutoNamer {
        AgentSessionAutoNamer(store: store, now: clock, isEnabled: { true }, titleLoader: { _, _ in try title() })
    }

    func testEndedChatWithoutTranscriptIsTriedOnceInSixHours() async throws {
        let session = try makeSession(status: .closed)
        var clock = Date(timeIntervalSince1970: 2_000_000)
        var calls = 0
        let namer = makeNamer(clock: { clock }) {
            calls += 1
            throw AgentTitleGeneratorError.missingTranscript
        }

        for _ in 0..<72 {            // sechs Stunden, ein Scan alle fünf Minuten
            await scan(namer, session.id)
            clock = clock.addingTimeInterval(300)
        }

        XCTAssertEqual(calls, 1, "vorher: ein Versuch je Scan nach Ablauf des Backoffs")
        let stored = current(session.id)
        XCTAssertEqual(stored.autoNameGaveUpAt, session.lastActivityAt)
        XCTAssertEqual(stored.lastActivityAt, session.lastActivityAt, "der Verzicht darf den Chat nicht nach oben sortieren")
    }

    func testChatWithOnlyCommandsGivesUpToo() async throws {
        let session = try makeSession(status: .closed)
        let namer = makeNamer(clock: { Date(timeIntervalSince1970: 2_000_000) }) {
            throw AgentTitleGeneratorError.emptyExcerpt
        }
        await scan(namer, session.id)
        XCTAssertNotNil(current(session.id).autoNameGaveUpAt)
    }

    func testGrowingTranscriptBringsTheChatBack() async throws {
        let session = try makeSession(status: .closed)
        var clock = Date(timeIntervalSince1970: 2_000_000)
        var calls = 0
        let namer = makeNamer(clock: { clock }) {
            calls += 1
            throw AgentTitleGeneratorError.emptyExcerpt
        }
        await scan(namer, session.id)
        clock = clock.addingTimeInterval(3_600)

        // Der Indexer sieht eine neuere Änderung am Verlauf.
        try store.mutateWorkspaceIfChanged { workspace in
            let index = workspace.sessions.firstIndex { $0.id == session.id }!
            workspace.sessions[index].lastActivityAt = session.lastActivityAt.addingTimeInterval(60)
            return true
        }
        await scan(namer, session.id)
        XCTAssertEqual(calls, 2)
    }

    func testRunningChatNeverGivesUp() async throws {
        let session = try makeSession(status: .running)
        let namer = makeNamer(clock: { Date(timeIntervalSince1970: 2_000_000) }) {
            throw AgentTitleGeneratorError.missingTranscript
        }
        await scan(namer, session.id)
        XCTAssertNil(current(session.id).autoNameGaveUpAt)
    }

    func testTurnEndTriesAgainAndSuccessClearsTheMark() async throws {
        let session = try makeSession(status: .closed)
        var ready = false
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let namer = makeNamer(clock: { clock }) {
            guard ready else { throw AgentTitleGeneratorError.missingTranscript }
            return "Titel aus dem Verlauf"
        }
        await scan(namer, session.id)
        XCTAssertNotNil(current(session.id).autoNameGaveUpAt)

        ready = true
        clock = clock.addingTimeInterval(60)   // nach dem kurzen Backoff wie bisher
        let done = expectation(description: "Turn-Ende")
        namer.handleTurnFinished(session: current(session.id), cwd: "/unused") { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        let stored = current(session.id)
        XCTAssertEqual(stored.title, "Titel aus dem Verlauf")
        XCTAssertNil(stored.autoNameGaveUpAt)
    }

    func testMarkSurvivesARestart() throws {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Claude Chat")
        session.autoNameGaveUpAt = Date(timeIntervalSince1970: 1_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentChatSession.self, from: encoder.encode(session))
        XCTAssertEqual(decoded.autoNameGaveUpAt, session.autoNameGaveUpAt)
    }
}
