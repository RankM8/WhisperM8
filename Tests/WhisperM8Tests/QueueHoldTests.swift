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
        XCTAssertNotEqual(QueueHoldNotices.hint(for: .init(count: 1, reason: .textInField)),
                          QueueHoldNotices.hint(for: .init(count: 1, reason: .viewOpen)))
    }

    /// Codex: Das Feld wird nie abgelesen, deshalb ein eigener zweiter Satz,
    /// der Enter und Ctrl+C nennt statt „Terminal nach unten scrollen“.
    func testCodexHintDiffersFromClaude() {
        let claude = QueueHoldNotices.hint(for: .init(count: 1, reason: .textInField))
        let codex = QueueHoldNotices.hint(for: .init(count: 1, reason: .textInField, fieldReadable: false))
        XCTAssertNotEqual(claude, codex)
        XCTAssertTrue(codex.contains("Ctrl+C"), codex)
        XCTAssertTrue(AgentPromptQueueDelivery.fieldReadable(.claudeCodeChat))
        XCTAssertFalse(AgentPromptQueueDelivery.fieldReadable(.codexChat))
        XCTAssertFalse(AgentPromptQueueDelivery.fieldReadable(.plainShell))
    }

    /// `chats dequeue`: Nichts mehr offen heißt sofort keine Pille; bleibt
    /// etwas offen, stimmt die Zahl. Ohne Hinweis entsteht keiner.
    func testNoticeAfterQueueChange() {
        let held = QueueHoldNotices.Notice(count: 3, reason: .textInField, fieldReadable: false)
        XCTAssertNil(QueueHoldNotices.notice(held, afterOpenCount: 0))
        XCTAssertEqual(QueueHoldNotices.notice(held, afterOpenCount: 1),
                       .init(count: 1, reason: .textInField, fieldReadable: false))
        XCTAssertNil(QueueHoldNotices.notice(nil, afterOpenCount: 2), "Hinweis entsteht nur beim Zustellversuch")
    }

    /// Über den Store: dequeue aller wartenden Meldungen räumt die Pille
    /// im selben Durchlauf, ohne den 30-s-Versuch abzuwarten.
    @MainActor
    func testDequeueClearsStripImmediately() throws {
        let store = AgentPromptQueueStore(fileURL: tempFile())
        let notices = QueueHoldNotices()
        let delivery = AgentPromptQueueDelivery(store: store, settleDelay: 0, notices: notices)
        let id = UUID()
        try store.enqueue(sessionID: id, prompt: "Bitte WM8-Doku prüfen", by: "Test")
        try store.enqueue(sessionID: id, prompt: "Und dann den Snapshot", by: "Test")
        notices.set(.init(count: 2, reason: .textInField), for: id)

        let first = store.openPrompts(for: id)[0]
        store.cancel(sessionID: id, ids: [first.id])
        delivery.noteQueueChanged(id)
        XCTAssertEqual(notices.notices[id]?.count, 1)

        store.cancel(sessionID: id)
        delivery.noteQueueChanged(id)
        XCTAssertNil(notices.notices[id])
    }

    /// Kurzfassung für enge Stellen: der Grund bleibt, kürzer als der volle Text.
    func testShortTextKeepsCountAndReason() {
        for notice in [QueueHoldNotices.Notice(count: 1, reason: .textInField),
                       .init(count: 3, reason: .textInField), .init(count: 1, reason: .viewOpen),
                       .init(count: 3, reason: .viewOpen)] {
            let short = QueueHoldNotices.shortText(for: notice)
            XCTAssertTrue(short.hasPrefix("\(notice.count) "), short)
            XCTAssertLessThan(short.count, QueueHoldNotices.text(for: notice).count, short)
        }
        XCTAssertNotEqual(QueueHoldNotices.shortText(for: .init(count: 1, reason: .textInField)),
                          QueueHoldNotices.shortText(for: .init(count: 1, reason: .viewOpen)))
        XCTAssertFalse(QueueHoldNotices.clickHint.isEmpty)
    }

    /// Ohne Notizkarte oben rechts; mit Karte rechts daneben, solange die
    /// Kurzfassung Platz hat, sonst unter der Karte. Nie links über der Karte.
    func testPlacementAvoidsTheNoteCard() {
        let plain = QueueHoldPlacement.Insets(top: QueueHoldPlacement.topInset, leading: QueueHoldPlacement.leadingInset)
        XCTAssertEqual(QueueHoldPlacement.insets(terminalWidth: 600, card: nil), plain)

        let card = JarvisNoteCardFootprint(trailingEdge: 10 + 240, bottomEdge: 96)
        let inset = JarvisNoteCardFootprint.terminalInset
        let beside = QueueHoldPlacement.insets(terminalWidth: 472, card: card)
        XCTAssertEqual(beside.top, QueueHoldPlacement.topInset)
        XCTAssertEqual(beside.leading, 250 - inset + QueueHoldPlacement.cardGap)
        XCTAssertGreaterThanOrEqual(472 - QueueHoldPlacement.trailingInset - beside.leading,
                                    QueueHoldPlacement.minimumWidthBesideCard)

        // Schmale Kachel: an der Unterkante der Karte, rechts in ihr.
        let onCard = QueueHoldPlacement.insets(terminalWidth: 262, card: card)
        let cardRight: CGFloat = 250 - inset
        let cardBottom: CGFloat = 96 - inset
        XCTAssertEqual(onCard.leading, QueueHoldPlacement.leadingInset)
        XCTAssertEqual(onCard.top, cardBottom - QueueHoldPlacement.pillHeight - QueueHoldPlacement.insideCardInset)
        XCTAssertEqual(onCard.trailing, 262 - cardRight + QueueHoldPlacement.insideCardInset)
        XCTAssertLessThanOrEqual(onCard.top + QueueHoldPlacement.pillHeight, cardBottom, "bleibt in der Karte")
        XCTAssertGreaterThanOrEqual(262 - onCard.trailing, 0)
        XCTAssertLessThanOrEqual(262 - onCard.trailing, cardRight, "rechte Kante in der Karte")

        // Karte reicht nicht ins Terminal (zugeklappt auf null): wie ohne Karte.
        XCTAssertEqual(QueueHoldPlacement.insets(terminalWidth: 262, card: .init(trailingEdge: 10, bottomEdge: 0)), plain)
    }

    @MainActor
    func testNoteCardFootprintsOnlyChangeOnRealChanges() {
        let cards = JarvisNoteCardFootprints()
        let id = UUID()
        cards.set(.init(trailingEdge: 250, bottomEdge: 96), for: id)
        XCTAssertEqual(cards.footprints[id], .init(trailingEdge: 250, bottomEdge: 96))
        cards.set(nil, for: id)
        XCTAssertNil(cards.footprints[id])
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("queue-hold-\(UUID().uuidString).json")
    }
}
