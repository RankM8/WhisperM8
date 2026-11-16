import XCTest
@testable import WhisperM8

/// WM8-123, Punkt 2: Wartet eine Meldung wegen Text im Eingabefeld oder einer
/// offenen Ansicht, steht das am Chat, und die Warteschlange sieht von selbst
/// wieder nach (alle 30 s und sobald das Terminal wieder unten steht). Vorher
/// stieß nur das nächste Turn-Ende an, das bei einem ruhenden Chat nie kam.
@MainActor
final class QueueHoldTests: XCTestCase {
    // MARK: Neuer Versuch: beide Richtungen

    /// Nichts geht ungewollt raus: Der Versuch entscheidet über dieselbe
    /// Sperre wie jede Zustellung; wartet sie, bleibt es beim Hinweis.
    func testRetryHoldsWhileTheGateHolds() {
        typealias D = AgentPromptQueueDelivery
        XCTAssertEqual(D.retryAction(openCount: 1, decision: .draftPending), .hold(.textInField))
        XCTAssertEqual(D.retryAction(openCount: 2, decision: .viewOpen), .hold(.viewOpen))
    }

    /// Nichts bleibt ohne Grund liegen: Gibt die Sperre frei, wird zugestellt;
    /// ohne offene Meldung, ohne Prozess oder bei arbeitendem Chat endet das
    /// Nachsehen (dann übernehmen Turn-Ende und Start).
    func testRetryDeliversOrStops() {
        typealias D = AgentPromptQueueDelivery
        XCTAssertEqual(D.retryAction(openCount: 1, decision: .deliver), .deliver)
        XCTAssertEqual(D.retryAction(openCount: 0, decision: .draftPending), .stop)
        XCTAssertEqual(D.retryAction(openCount: 1, decision: nil), .stop)
        XCTAssertEqual(D.retryAction(openCount: 1, decision: .busy("working")), .stop)
        XCTAssertEqual(D.retryAction(openCount: 1, decision: .notReady), .stop)
    }

    /// Ganz unten angekommen: sofort nachsehen, aber höchstens einmal je Sekunde.
    func testReturnToBottomIsThrottled() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(AgentPromptQueueDelivery.returnRetryAllowed(last: nil, now: t0))
        XCTAssertFalse(AgentPromptQueueDelivery.returnRetryAllowed(last: t0, now: t0.addingTimeInterval(0.4)))
        XCTAssertTrue(AgentPromptQueueDelivery.returnRetryAllowed(last: t0, now: t0.addingTimeInterval(1)))
    }

    /// Ohne wartende Meldung tut das Scroll-Ereignis nichts (kein Lesen, kein Timer).
    func testReturnToBottomWithoutNoticeDoesNothing() {
        let notices = QueueHoldNotices()
        let delivery = AgentPromptQueueDelivery(store: AgentPromptQueueStore(fileURL: tempFile()), notices: notices)
        delivery.noteReturnedToBottom(UUID())
        XCTAssertTrue(notices.notices.isEmpty)
    }

    /// Die Ansicht meldet jede Scroll-Bewegung an den Controller weiter.
    func testInterceptorReportsScrollPositions() {
        let terminal = QuietableTerminalView(frame: .zero)
        var seen: [Double] = []
        let interceptor = AgentTerminalLinkInterceptor(base: terminal) { _, _ in }
        interceptor.onScrolled = { seen.append($0) }
        interceptor.scrolled(source: terminal, position: 0.4)
        interceptor.scrolled(source: terminal, position: 1)
        XCTAssertEqual(seen, [0.4, 1])
    }

    // MARK: Hinweis am Chat

    func testNoticeSetAndClear() {
        let notices = QueueHoldNotices()
        let id = UUID()
        notices.set(.init(count: 2, reason: .textInField), for: id)
        XCTAssertEqual(notices.notices[id], .init(count: 2, reason: .textInField))
        notices.set(.init(count: 0, reason: .textInField), for: id)
        XCTAssertNil(notices.notices[id], "keine Meldung offen: kein Hinweis")
        notices.set(.init(count: 1, reason: .viewOpen), for: id)
        notices.clear(id)
        XCTAssertNil(notices.notices[id])
    }

    func testNoticeTextNamesCountAndReason() {
        let one = QueueHoldNotices.text(for: .init(count: 1, reason: .textInField))
        let three = QueueHoldNotices.text(for: .init(count: 3, reason: .textInField))
        let view = QueueHoldNotices.text(for: .init(count: 1, reason: .viewOpen))
        XCTAssertTrue(one.hasPrefix("1 "), one)
        XCTAssertTrue(three.hasPrefix("3 "), three)
        XCTAssertNotEqual(one, view)
        XCTAssertNotEqual(QueueHoldNotices.hint(for: .textInField), QueueHoldNotices.hint(for: .viewOpen))
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("queue-hold-\(UUID().uuidString).json")
    }
}
