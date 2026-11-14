import XCTest
@testable import WhisperM8

// MARK: - WM8-87: Rest der alten Generation nach der Rotation

/// Befund 14.11.2026: Nach der Rotation stand als erste Zeile des neuen
/// Journals ein Eintrag der alten Generation (seq 2997, danach seq 1).
/// `changes()` hielt ihn für den ältesten Eintrag, jeder Cursor galt als
/// Lücke, `chats watch` endete sofort mit `gap`, und die Board-Mod startete
/// es im 2-s-Takt neu. Alle Tests schreiben in ein Temp-Verzeichnis.
final class ChatsJournalRotationTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private let session = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("journal.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Datei wie am 14.11. vorgefunden: oben ein Eintrag der alten
    /// Generation, darunter die neue ab seq 1.
    private func writeResidueFile(newCount: Int = 3) throws {
        func line(_ id: String, _ seq: Int) -> String {
            #"{"at":"2026-11-13T21:58:0\#(seq % 10)Z","from":"working","journalId":"\#(id)","seq":\#(seq),"#
                + #""sessionID":"\#(session.uuidString)","signal":"registryStatus","source":"registry","to":"idle"}"#
        }
        let lines = [line("1f2cf5c2", 2997)] + (1...newCount).map { line("9c695e9d", $0) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Ursache: Stempel vor der Rotation

    func testTheEntryThatTriggersRotationBelongsToTheNewGeneration() {
        let journal = ChatsStatusJournal(fileURL: url, maxBytes: 600)
        var rotations = 0
        var lastBackupSize = 0
        for index in 0..<40 {
            journal.append(sessionID: session, from: "a\(index)", to: "b\(index)", signal: "s", source: "hook")
            let backup = url.appendingPathExtension("1")
            let size = ((try? FileManager.default.attributesOfItem(atPath: backup.path))?[.size] as? Int) ?? 0
            if size != lastBackupSize { rotations += 1; lastBackupSize = size }
        }
        XCTAssertGreaterThan(rotations, 1, "der Test muss mehrere Rotationen durchlaufen")

        let current = ChatsStatusJournal.readAll(fileURL: url)
        XCTAssertEqual(Set(current.map(\.journalId)).count, 1,
                       "die neue Datei darf nur eine Generation enthalten: \(current.map(\.journalId))")
        XCTAssertEqual(current.map(\.seq), Array(1...current.count),
                       "die neue Generation beginnt bei 1 und zählt lückenlos")

        let backup = ChatsStatusJournal.readAll(fileURL: url.appendingPathExtension("1"))
        XCTAssertEqual(Set(backup.map(\.journalId)).count, 1, "auch die Sicherung bleibt sortenrein")
        XCTAssertNotEqual(backup.first?.journalId, current.first?.journalId)
    }

    func testFreshCursorAfterRotationIsNoGap() {
        let journal = ChatsStatusJournal(fileURL: url, maxBytes: 600)
        for index in 0..<20 {
            journal.append(sessionID: session, from: "a\(index)", to: "b\(index)", signal: "s", source: "hook")
        }
        let cursor = ChatsStatusJournal.currentCursor(fileURL: url)
        XCTAssertNotNil(cursor)
        journal.append(sessionID: session, from: "x", to: "y", signal: "s", source: "hook")
        let result = ChatsStatusJournal.changes(since: cursor, fileURL: url)
        XCTAssertFalse(result.gap)
        XCTAssertEqual(result.entries.map(\.to), ["y"])
    }

    // MARK: Lesen: Rest am Dateianfang (vorhandene Journale)

    func testResidueOfTheOldGenerationDoesNotTurnACurrentCursorIntoAGap() throws {
        try writeResidueFile()
        let cursor = ChatsStatusJournal.currentCursor(fileURL: url)
        XCTAssertEqual(cursor, "9c695e9d:3")

        let none = ChatsStatusJournal.changes(since: cursor, fileURL: url)
        XCTAssertFalse(none.gap, "ein frischer Cursor der aktuellen Generation ist keine Lücke")
        XCTAssertTrue(none.entries.isEmpty)

        let some = ChatsStatusJournal.changes(since: "9c695e9d:1", fileURL: url)
        XCTAssertFalse(some.gap)
        XCTAssertEqual(some.entries.map(\.seq), [2, 3], "der alte Eintrag (seq 2997) gehört nicht dazu")
    }

    func testCursorOfTheOldGenerationIsStillAGap() throws {
        try writeResidueFile()
        XCTAssertTrue(ChatsStatusJournal.changes(since: "1f2cf5c2:2996", fileURL: url).gap,
                      "ein Cursor der alten Generation bleibt ungültig")
    }

    // MARK: chats watch

    private struct WatchRun {
        var exit: Int32
        var lines: [[String: Any]]
        var reads: Int
    }

    /// `watch` mit gespielter Uhr: jeder Schlaf rückt die Uhr vor.
    private func runWatch(cursor: String?, seconds: Double, between: (() -> Void)? = nil) -> WatchRun {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var lines: [[String: Any]] = []
        var sleeps = 0
        let exit = ChatsChangesCommand.runWatch(
            cursor: cursor, intervalSeconds: 2, maxSeconds: seconds, fileURL: url,
            out: { text in
                if let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lines.append(object)
                }
            },
            sleep: { interval in
                sleeps += 1
                if sleeps == 2 { between?() }
                now = now.addingTimeInterval(interval)
            },
            clock: { now })
        return WatchRun(exit: exit, lines: lines, reads: sleeps)
    }

    func testWatchKeepsRunningOnAJournalWithResidue() throws {
        try writeResidueFile()
        let run = runWatch(cursor: nil, seconds: 10)
        XCTAssertEqual(run.lines.first?["event"] as? String, "started")
        XCTAssertFalse(run.lines.contains { $0["event"] as? String == "gap" },
                       "vorher: Lücke und Ende nach dem ersten Blick")
        XCTAssertEqual(run.lines.last?["event"] as? String, "timeout")
        XCTAssertEqual(run.exit, ChatsCLIExit.ok)
    }

    func testWatchDeliversNewEntriesAfterAppends() throws {
        try writeResidueFile()
        let run = runWatch(cursor: nil, seconds: 10) {
            let journal = ChatsStatusJournal(fileURL: self.url)
            journal.append(sessionID: self.session, from: "idle", to: "working", signal: "s", source: "hook")
        }
        let changes = run.lines.filter { $0["event"] == nil }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["to"] as? String, "working")
        XCTAssertEqual(changes.first?["seq"] as? Int, 4)
    }

    func testWatchEndsWithGapForACursorOfAnotherGeneration() throws {
        try writeResidueFile()
        let run = runWatch(cursor: "1f2cf5c2:2996", seconds: 10)
        XCTAssertEqual(run.lines.last?["event"] as? String, "gap")
        XCTAssertEqual(run.exit, ChatsCLIExit.conflict)
    }

    func testJournalStampChangesWithAppendsAndIsNilWithoutFile() throws {
        XCTAssertNil(ChatsChangesCommand.JournalStamp(fileURL: url))
        try writeResidueFile(newCount: 1)
        let before = ChatsChangesCommand.JournalStamp(fileURL: url)
        XCTAssertNotNil(before)
        ChatsStatusJournal(fileURL: url).append(sessionID: session, from: "a", to: "b", signal: "s", source: "hook")
        XCTAssertNotEqual(ChatsChangesCommand.JournalStamp(fileURL: url), before)
    }

    // MARK: Cursor aus dem Dateiende

    func testCursorFromTheTailMatchesAFullReadOnALargeJournal() {
        let journal = ChatsStatusJournal(fileURL: url)
        for index in 0..<300 {
            journal.append(sessionID: session, from: "a\(index)", to: "b\(index)", signal: "s", source: "hook")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 16_384, "der Test braucht eine Datei größer als das gelesene Ende")
        let tail = ChatsStatusJournal.readTail(fileURL: url)
        XCTAssertFalse(tail.isEmpty)
        XCTAssertLessThan(tail.count, 300, "nur das Ende, nicht die ganze Datei")
        XCTAssertEqual(tail.last?.seq, 300)
        let full = ChatsStatusJournal.readAll(fileURL: url)
        XCTAssertEqual(ChatsStatusJournal.currentCursor(fileURL: url),
                       ChatsStatusJournal.currentCursor(entries: full))
    }

    func testCursorIsNilWithoutFileAndForALegacyLastLine() throws {
        XCTAssertNil(ChatsStatusJournal.currentCursor(fileURL: url))
        let legacy = #"{"at":"2026-07-26T10:00:00Z","sessionID":"\#(session.uuidString)","signal":"x","source":"hook","to":"idle"}"#
        try (legacy + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(ChatsStatusJournal.currentCursor(fileURL: url))
    }

    // MARK: Testläufe schreiben nie ins echte Journal

    func testSharedJournalOutsideTheAppWritesIntoATemporaryFolder() {
        let real = ChatsStatusJournal.defaultFileURL()
        XCTAssertEqual(ChatsStatusJournal.sharedFileURL(isAppProcess: true), real)
        let test = ChatsStatusJournal.sharedFileURL(isAppProcess: false)
        XCTAssertNotEqual(test, real)
        XCTAssertTrue(test.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(ChatsStatusJournal.sharedFileURL(), test, "swift test ist kein App-Prozess")
    }

    // MARK: Review: fremde Schreiber in derselben Generation

    /// Ein älterer Testlauf, der wie vor WM8-87 ins Journal schreibt: liest die
    /// Generation aus der letzten Zeile und zählt eigene Nummern, ohne Markierung.
    private func appendForeign(generation: String, seqs: [Int]) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for seq in seqs {
            let line = #"{"at":"2026-11-14T04:00:00Z","journalId":"\#(generation)","seq":\#(seq),"sessionID":"\#(UUID().uuidString)","signal":"x","source":"hook","to":"idle"}"#
            try handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func testAppStartsAFreshGenerationWhenTheLastLineIsNotItsOwn() throws {
        try writeResidueFile()
        let app = ChatsStatusJournal(fileURL: url, writer: ChatsStatusJournal.appWriter)
        app.append(sessionID: session, from: "idle", to: "working", signal: "s", source: "hook")
        let last = try XCTUnwrap(ChatsStatusJournal.readAll(fileURL: url).last)
        XCTAssertNotEqual(last.journalId, "9c695e9d", "fremde letzte Zeile: neue Generation")
        XCTAssertEqual(last.seq, 1)
        XCTAssertEqual(last.writer, ChatsStatusJournal.appWriter)
        XCTAssertEqual(ChatsStatusJournal.currentCursor(fileURL: url), "\(last.journalId):1")
    }

    func testAppContinuesItsOwnGenerationAfterARestart() {
        let first = ChatsStatusJournal(fileURL: url, writer: ChatsStatusJournal.appWriter)
        first.append(sessionID: session, from: "a", to: "b", signal: "s", source: "hook")
        first.append(sessionID: session, from: "b", to: "c", signal: "s", source: "hook")
        let restarted = ChatsStatusJournal(fileURL: url, writer: ChatsStatusJournal.appWriter)
        restarted.append(sessionID: session, from: "c", to: "d", signal: "s", source: "hook")
        let all = ChatsStatusJournal.readAll(fileURL: url)
        XCTAssertEqual(all.map(\.seq), [1, 2, 3], "ein normaler Neustart kostet keine Lücke")
        XCTAssertEqual(Set(all.map(\.journalId)).count, 1)
    }

    func testForeignLinesInTheAppGenerationNeitherReplayNorHideAppEvents() throws {
        let app = ChatsStatusJournal(fileURL: url, writer: ChatsStatusJournal.appWriter)
        for index in 0..<3 {
            app.append(sessionID: session, from: "a\(index)", to: "b\(index)", signal: "s", source: "hook")
        }
        let generation = try XCTUnwrap(ChatsStatusJournal.readAll(fileURL: url).last?.journalId)
        // Ein alter Testlauf schreibt dazwischen, mit eigenen Nummern.
        try appendForeign(generation: generation, seqs: [1, 2, 9, 10])
        app.append(sessionID: session, from: "x", to: "y", signal: "s", source: "hook")

        XCTAssertEqual(ChatsStatusJournal.currentCursor(fileURL: url), "\(generation):4")
        let result = ChatsStatusJournal.changes(since: "\(generation):2", fileURL: url)
        XCTAssertFalse(result.gap)
        XCTAssertEqual(result.entries.map(\.seq), [3, 4], "nur Zeilen der App, keine Wiederholung")
        XCTAssertTrue(result.entries.allSatisfy { $0.writer == ChatsStatusJournal.appWriter })
    }

    func testCursorFindsTheAppLineAboveALongForeignTail() throws {
        let app = ChatsStatusJournal(fileURL: url, writer: ChatsStatusJournal.appWriter)
        app.append(sessionID: session, from: "a", to: "b", signal: "s", source: "hook")
        let generation = try XCTUnwrap(ChatsStatusJournal.readAll(fileURL: url).last?.journalId)
        try appendForeign(generation: generation, seqs: Array(100..<300))
        XCTAssertEqual(ChatsStatusJournal.currentCursor(fileURL: url), "\(generation):1",
                       "das Dateiende enthält nur fremde Zeilen: dann alles lesen")
    }
}
