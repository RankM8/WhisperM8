import XCTest
@testable import WhisperM8

/// WM8-119, Prüferin: Während ein Enter bis zu 3 s auf seinen Text im Feld
/// wartet, gilt das Feld für `send` und die Warteschlange nicht als frei.
/// Sonst verschmölzen zwei Meldungen zu einer.
@MainActor
final class PendingEnterGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPendingWithinTheWaitWindowOnly() {
        XCTAssertFalse(DelayedEnterLanding.enterPending(since: nil, now: now))
        XCTAssertTrue(DelayedEnterLanding.enterPending(since: now, now: now))
        XCTAssertTrue(DelayedEnterLanding.enterPending(since: now.addingTimeInterval(-4.9), now: now))
        // Ein liegengebliebener Eintrag (Tab geschlossen, Versuch lief nie) sperrt nicht ewig.
        XCTAssertFalse(DelayedEnterLanding.enterPending(
            since: now.addingTimeInterval(-(DelayedEnterLanding.maxWaitSeconds + 2)), now: now))
    }

    func testControllerLookupReadsTheMap() {
        let id = UUID()
        defer { AgentTerminalController.pendingEnterSince[id] = nil }
        XCTAssertFalse(AgentTerminalController.enterPending(for: id, now: now))
        AgentTerminalController.pendingEnterSince[id] = now
        XCTAssertTrue(AgentTerminalController.enterPending(for: id, now: now.addingTimeInterval(1)))
    }

    /// `notReady` lässt die CLI den Auftrag vormerken, statt ihn zu verwerfen.
    func testSendRefusalLetsTheCLIQueue() {
        XCTAssertEqual(ChatsControlErrorCode.notReady.alternative, "enqueue")
        XCTAssertTrue(ChatsSendCommand.shouldEnqueue(code: .notReady, withheld: false, explicitQueue: false,
                                                     autoQueue: true, ifStatusGiven: false))
        XCTAssertTrue(DelayedEnterLanding.enterPendingMessage.contains("enqueue"))
    }

    /// Die Warteschlange reserviert nicht, solange das Enter wartet: Der
    /// Auftrag bleibt unberührt vorgemerkt. (Ohne die Sperre reservierte sie
    /// sofort und verbuchte ihn hier als gescheitert, weil der Test-Chat im
    /// Workspace der App fehlt.)
    func testQueueDoesNotReserveWhileEnterIsPending() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-enter-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentPromptQueueStore(fileURL: url)
        let delivery = AgentPromptQueueDelivery(store: store, settleDelay: 0)
        let chat = UUID()
        let queued = try store.enqueue(sessionID: chat, prompt: "Zweite Meldung", by: "whisperm8/Test")
        AgentTerminalController.pendingEnterSince[chat] = Date()
        defer { AgentTerminalController.pendingEnterSince[chat] = nil }

        delivery.deliverNow(for: chat)

        let after = try XCTUnwrap(store.all().first { $0.id == queued.id })
        XCTAssertEqual(after.state, .pending)
        XCTAssertNil(after.lastError)
    }
}
