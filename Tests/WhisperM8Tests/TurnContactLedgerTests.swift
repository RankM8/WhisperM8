import XCTest
@testable import WhisperM8

/// WM8-119: Das Turn-Ende im Journal nennt, wer den Turn anstieß und wen der
/// Chat im Turn anschrieb. Die Board-Mod weckt den Supervisor dann nicht mit
/// „fertig – prüfen“, wenn der Chat nur ihm antwortete oder ihm schon schrieb.
final class TurnContactLedgerTests: XCTestCase {
    private let jarvis = UUID(uuidString: "A37D241B-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "B0096DCA-0000-4000-8000-000000000002")!
    private let turnStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(delivery: TurnContactLedger.Delivery?, messages: [TurnContactLedger.Message] = [],
                         turnStartedAt: Date?, lasting seconds: TimeInterval = 30) -> (repliedTo: UUID?, messaged: [UUID]) {
        TurnContactLedger.context(delivery: delivery, messages: messages, turnStartedAt: turnStartedAt,
                                  endedAt: (turnStartedAt ?? turnStart).addingTimeInterval(seconds))
    }

    /// Zustellung kurz vor dem gesehenen Turn-Start, kurzer Turn: eine Antwort.
    func testDeliveryJustBeforeTurnStartStartedIt() {
        let delivery = TurnContactLedger.Delivery(sender: jarvis, at: turnStart.addingTimeInterval(-4))
        XCTAssertEqual(context(delivery: delivery, turnStartedAt: turnStart).repliedTo, jarvis)
        // Bis 15 s vorher (Enter wartet auf Bilder, Status kommt mit Verzug), bis 1 s danach.
        XCTAssertEqual(context(delivery: .init(sender: jarvis, at: turnStart.addingTimeInterval(-15)),
                               turnStartedAt: turnStart).repliedTo, jarvis)
        XCTAssertEqual(context(delivery: .init(sender: jarvis, at: turnStart.addingTimeInterval(1)),
                               turnStartedAt: turnStart).repliedTo, jarvis)
    }

    /// Eine ältere Zustellung (der Chat hat seitdem von selbst weitergemacht),
    /// kein bekannter Turn-Start oder ein langer Turn (Arbeit an einem Auftrag,
    /// soll am Ende weiter wecken): keine Antwort.
    func testOldDeliveryUnknownStartOrLongTurnIsNoReply() {
        let delivery = TurnContactLedger.Delivery(sender: jarvis, at: turnStart.addingTimeInterval(-4))
        XCTAssertEqual(context(delivery: delivery, turnStartedAt: turnStart,
                               lasting: TurnContactLedger.replyMaxSeconds).repliedTo, jarvis)
        XCTAssertNil(context(delivery: delivery, turnStartedAt: turnStart,
                             lasting: TurnContactLedger.replyMaxSeconds + 1).repliedTo)
        XCTAssertNil(context(delivery: .init(sender: jarvis, at: turnStart.addingTimeInterval(-60)),
                             turnStartedAt: turnStart).repliedTo)
        XCTAssertNil(context(delivery: .init(sender: jarvis, at: turnStart.addingTimeInterval(5)),
                             turnStartedAt: turnStart).repliedTo)
        XCTAssertNil(context(delivery: .init(sender: jarvis, at: turnStart), turnStartedAt: nil).repliedTo)
    }

    /// Nur Nachrichten seit dem Turn-Start zählen, jedes Ziel einmal.
    func testMessagedListsTargetsSinceTurnStartOnce() {
        let messages: [TurnContactLedger.Message] = [
            .init(target: other, at: turnStart.addingTimeInterval(-30)),
            .init(target: jarvis, at: turnStart.addingTimeInterval(40)),
            .init(target: jarvis, at: turnStart.addingTimeInterval(50)),
        ]
        XCTAssertEqual(context(delivery: nil, messages: messages, turnStartedAt: turnStart, lasting: 60).messaged, [jarvis])
        XCTAssertEqual(context(delivery: nil, messages: messages, turnStartedAt: nil).messaged, [])
    }

    /// Prüferin zu WM8-119: Als Antwort gilt nur ein Turn bis 2 Minuten. Ein
    /// „Commit und push“ oder ein kleiner Fix von drei Minuten weckt weiter.
    func testReplyIsAtMostTwoMinutes() {
        XCTAssertEqual(TurnContactLedger.replyMaxSeconds, 120)
        let delivery = TurnContactLedger.Delivery(sender: jarvis, at: turnStart.addingTimeInterval(-2))
        XCTAssertEqual(context(delivery: delivery, turnStartedAt: turnStart, lasting: 90).repliedTo, jarvis)
        XCTAssertNil(context(delivery: delivery, turnStartedAt: turnStart, lasting: 180).repliedTo)
    }

    /// Prüferin zu WM8-119: Nur eine Meldung in den letzten 2 Minuten vor dem
    /// Turn-Ende zählt. Eine frühe Zwischenmeldung mit danach langer Arbeit
    /// ohne Schlussmeldung soll den Supervisor weiter wecken.
    func testOnlyMessagesShortlyBeforeTurnEndCount() {
        let thirtyMinutes: TimeInterval = 30 * 60
        let early = [TurnContactLedger.Message(target: jarvis, at: turnStart.addingTimeInterval(5 * 60))]
        XCTAssertEqual(context(delivery: nil, messages: early, turnStartedAt: turnStart, lasting: thirtyMinutes).messaged, [])
        let final = [TurnContactLedger.Message(target: jarvis, at: turnStart.addingTimeInterval(thirtyMinutes - 60))]
        XCTAssertEqual(context(delivery: nil, messages: final, turnStartedAt: turnStart, lasting: thirtyMinutes).messaged, [jarvis])
        let edge = [TurnContactLedger.Message(target: jarvis, at: turnStart.addingTimeInterval(thirtyMinutes - 120))]
        XCTAssertEqual(context(delivery: nil, messages: edge, turnStartedAt: turnStart, lasting: thirtyMinutes).messaged, [jarvis])
        let tooEarly = [TurnContactLedger.Message(target: jarvis, at: turnStart.addingTimeInterval(thirtyMinutes - 121))]
        XCTAssertEqual(context(delivery: nil, messages: tooEarly, turnStartedAt: turnStart, lasting: thirtyMinutes).messaged, [])
    }

    /// Ohne geprüften Absender und an sich selbst wird nichts vermerkt; je
    /// Absender höchstens 20 Einträge.
    @MainActor
    func testLedgerIgnoresUnknownSenderAndSelfAndCapsMessages() {
        let ledger = TurnContactLedger()
        let chat = UUID()
        ledger.noteDelivered(to: chat, from: nil)
        ledger.noteDelivered(to: chat, from: chat)
        XCTAssertNil(ledger.lastDelivery[chat])
        ledger.noteMessaged(from: nil, to: jarvis)
        ledger.noteMessaged(from: chat, to: chat)
        XCTAssertNil(ledger.messages[chat])
        for _ in 0..<25 { ledger.noteMessaged(from: chat, to: jarvis) }
        XCTAssertEqual(ledger.messages[chat]?.count, TurnContactLedger.maxMessagesPerSender)
        ledger.noteDelivered(to: chat, from: jarvis, at: turnStart)
        XCTAssertEqual(ledger.turnContext(for: chat, turnStartedAt: turnStart.addingTimeInterval(2),
                                          endedAt: turnStart.addingTimeInterval(40)).repliedTo, jarvis)
    }

    /// `chats watch` liefert beide Felder nur, wenn sie gesetzt sind; alte
    /// Journal-Zeilen bleiben lesbar.
    func testWatchJSONCarriesRepliedToAndMessaged() throws {
        var entry = ChatsStatusJournalEntry(
            at: Date(), seq: 4, journalId: "g", sessionID: other,
            from: "working", to: "idle", signal: "registryStatus", source: "registry")
        XCTAssertNil(ChatsChangesCommand.changeJSON(entry)["repliedTo"])
        XCTAssertNil(ChatsChangesCommand.changeJSON(entry)["messaged"])
        entry.repliedTo = jarvis
        entry.messaged = [jarvis]
        let json = ChatsChangesCommand.changeJSON(entry)
        XCTAssertEqual(json["repliedTo"] as? String, jarvis.uuidString)
        XCTAssertEqual(json["messaged"] as? [String], [jarvis.uuidString])

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ChatsStatusJournalEntry.self, from: data)
        XCTAssertEqual(decoded.repliedTo, jarvis)
        XCTAssertEqual(decoded.messaged, [jarvis])
        let old = Data(#"{"at":0,"seq":1,"journalId":"g","signal":"x","source":"hook","to":"idle"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatsStatusJournalEntry.self, from: old).repliedTo)
    }

    /// Das Journal lässt eine leere Liste weg statt `[]` zu schreiben.
    func testJournalDropsEmptyMessagedList() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-contact-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: other, from: "working", to: "idle", signal: "x", source: "registry",
                       repliedTo: jarvis, messaged: [])
        let line = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(line.contains(jarvis.uuidString))
        XCTAssertFalse(line.contains("messaged"))
    }
}
