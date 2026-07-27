import XCTest
@testable import WhisperM8

// MARK: - Cursor-Vertrag (wm8.changes/1)

final class ChatsJournalCursorTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private let session = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("journal.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ count: Int, journal: ChatsStatusJournal? = nil) -> ChatsStatusJournal {
        let target = journal ?? ChatsStatusJournal(fileURL: url)
        for index in 0..<count {
            target.append(sessionID: session, from: "s\(index)", to: "s\(index + 1)",
                          signal: "sig\(index)", source: "hook")
        }
        return target
    }

    // MARK: Sequenz

    func testSequenceIsMonotonicAndStartsAtOne() {
        _ = write(3)
        let all = ChatsStatusJournal.readAll(fileURL: url)
        XCTAssertEqual(all.map(\.seq), [1, 2, 3])
        XCTAssertFalse(all[0].journalId.isEmpty)
        XCTAssertEqual(Set(all.map(\.journalId)).count, 1, "eine Generation für alle")
    }

    func testSequenceContinuesAfterReload() {
        _ = write(2)
        let reloaded = ChatsStatusJournal(fileURL: url)
        reloaded.append(sessionID: session, from: "a", to: "b", signal: "x", source: "hook")
        XCTAssertEqual(ChatsStatusJournal.readAll(fileURL: url).map(\.seq), [1, 2, 3],
                       "ein Neustart darf die Nummerierung nicht zurücksetzen")
    }

    // MARK: Cursor-Form

    func testCursorRoundTrip() {
        let raw = ChatsStatusJournal.cursor(journalId: "abc123", seq: 42)
        XCTAssertEqual(raw, "abc123:42")
        let parsed = ChatsStatusJournal.parseCursor(raw)
        XCTAssertEqual(parsed?.journalId, "abc123")
        XCTAssertEqual(parsed?.seq, 42)
    }

    func testMalformedCursorIsRejected() {
        XCTAssertNil(ChatsStatusJournal.parseCursor("keinDoppelpunkt"))
        XCTAssertNil(ChatsStatusJournal.parseCursor("abc:nichtnumerisch"))
    }

    func testCurrentCursorIsNilOnEmptyJournal() {
        XCTAssertNil(ChatsStatusJournal.currentCursor(fileURL: url))
    }

    // MARK: Änderungen

    func testChangesReturnOnlyWhatIsNewerThanTheCursor() {
        _ = write(5)
        let all = ChatsStatusJournal.readAll(fileURL: url)
        let cursor = ChatsStatusJournal.cursor(journalId: all[1].journalId, seq: all[1].seq)

        let result = ChatsStatusJournal.changes(since: cursor, fileURL: url)
        XCTAssertEqual(result.entries.map(\.seq), [3, 4, 5])
        XCTAssertFalse(result.gap)
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.cursor, ChatsStatusJournal.cursor(journalId: all[4].journalId, seq: 5))
    }

    func testNoEventsAreLostBetweenTwoConsecutiveCalls() {
        // Kernzusage: Was zwischen zwei Abfragen passiert, darf nicht
        // verschwinden.
        let journal = write(2)
        let first = ChatsStatusJournal.changes(since: ChatsStatusJournal.currentCursor(fileURL: url),
                                               fileURL: url)
        XCTAssertTrue(first.entries.isEmpty)

        _ = write(3, journal: journal)
        let second = ChatsStatusJournal.changes(since: first.cursor, fileURL: url)
        XCTAssertEqual(second.entries.map(\.seq), [3, 4, 5])
    }

    func testLimitPagesAndReportsMore() {
        _ = write(10)
        let all = ChatsStatusJournal.readAll(fileURL: url)
        let start = ChatsStatusJournal.cursor(journalId: all[0].journalId, seq: 0)

        let page = ChatsStatusJournal.changes(since: start, limit: 4, fileURL: url)
        XCTAssertEqual(page.entries.map(\.seq), [1, 2, 3, 4])
        XCTAssertTrue(page.hasMore)

        let next = ChatsStatusJournal.changes(since: page.cursor, limit: 4, fileURL: url)
        XCTAssertEqual(next.entries.map(\.seq), [5, 6, 7, 8])
    }

    func testWithoutCursorNothingIsReplayed() {
        // Ohne Cursor nur den Stand melden — sonst bekäme ein frischer
        // Konsument den gesamten Bestand in den Kontext.
        _ = write(5)
        let result = ChatsStatusJournal.changes(since: nil, fileURL: url)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.gap)
        XCTAssertNotNil(result.cursor)
    }

    // MARK: Lücken

    func testForeignGenerationYieldsGapNotSilentRestart() {
        // Der gefährlichste Fall: Eine stille Lücke sähe aus wie „nichts
        // passiert". Sie MUSS als gap gemeldet werden.
        _ = write(3)
        let result = ChatsStatusJournal.changes(since: "fremdeGeneration:1", fileURL: url)
        XCTAssertTrue(result.gap)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testMalformedCursorIsTreatedAsNoCursorNotAsGap() {
        _ = write(3)
        let result = ChatsStatusJournal.changes(since: "kaputt", fileURL: url)
        XCTAssertFalse(result.gap)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testRotationStartsANewGenerationAndInvalidatesOldCursors() {
        // Kleines maxBytes erzwingt Rotation nach wenigen Zeilen.
        let journal = ChatsStatusJournal(fileURL: url, maxBytes: 400)
        for index in 0..<12 {
            journal.append(sessionID: session, from: "a\(index)", to: "b\(index)",
                           signal: "s", source: "hook")
        }
        let all = ChatsStatusJournal.readAll(fileURL: url)
        XCTAssertFalse(all.isEmpty, "nach der Rotation wird weitergeschrieben")

        let staleCursor = ChatsStatusJournal.cursor(journalId: "vorherigeGeneration", seq: 1)
        XCTAssertTrue(ChatsStatusJournal.changes(since: staleCursor, fileURL: url).gap)
    }

    func testEntriesWithoutGenerationAreIgnoredForCursors() throws {
        // Zeilen aus einer Vorversion tragen keine Ordnung — sie dürfen weder
        // einen Cursor liefern noch als Änderung erscheinen.
        let legacy = #"{"at":"2026-07-26T10:00:00Z","sessionID":"\#(session.uuidString)","signal":"x","source":"hook","to":"idle"}"#
        try (legacy + "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(ChatsStatusJournal.currentCursor(fileURL: url))
        let result = ChatsStatusJournal.changes(since: nil, fileURL: url)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNil(result.cursor)
    }

    func testLegacyLinesDoNotBreakNewWrites() throws {
        let legacy = #"{"at":"2026-07-26T10:00:00Z","sessionID":"\#(session.uuidString)","signal":"x","source":"hook","to":"idle"}"#
        try (legacy + "\n").write(to: url, atomically: true, encoding: .utf8)
        _ = write(2)
        let fresh = ChatsStatusJournal.readAll(fileURL: url).filter { !$0.journalId.isEmpty }
        XCTAssertEqual(fresh.map(\.seq), [1, 2])
        XCTAssertNotNil(ChatsStatusJournal.currentCursor(fileURL: url))
    }
}

// MARK: - Änderungs-JSON

final class ChatsChangesJSONTests: XCTestCase {
    func testChangeCarriesRefSeqAndEvidence() {
        let id = UUID()
        let entry = ChatsStatusJournalEntry(
            at: Date(timeIntervalSince1970: 1_000_000), seq: 7, journalId: "gen1",
            sessionID: id, from: "working", to: "idle", signal: "turnStopped", source: "hook")
        let json = ChatsChangesCommand.changeJSON(entry)

        XCTAssertEqual(json["seq"] as? Int, 7)
        XCTAssertEqual(json["from"] as? String, "working")
        XCTAssertEqual(json["to"] as? String, "idle")
        XCTAssertEqual(json["signal"] as? String, "turnStopped")
        XCTAssertEqual(json["evidence"] as? String, "observed")
        XCTAssertEqual(json["sessionID"] as? String, id.uuidString)
        XCTAssertEqual(json["ref"] as? String, ChatsOutput.shortID(id))
    }

    func testTranscriptSourceIsMarkedInferred() {
        let entry = ChatsStatusJournalEntry(
            at: Date(), seq: 1, journalId: "g", sessionID: UUID(),
            from: nil, to: "working", signal: "transcriptActivity", source: "transcript")
        let json = ChatsChangesCommand.changeJSON(entry)
        XCTAssertEqual(json["evidence"] as? String, "inferred")
        XCTAssertNil(json["from"], "fehlende Werte werden weggelassen, nicht als null gefüllt")
    }
}
