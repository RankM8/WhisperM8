import XCTest
@testable import WhisperM8

/// Ablage der Statistik: Tages- und Monatsdateien, Übernahme der alten
/// Gesamtdatei, Generation, anhängende Dedup und Cursor-Journal.
final class StatisticsStorageTests: XCTestCase {
    private var dir: URL!
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-storage-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeStore(_ clock: Clock) -> StatisticsStore {
        StatisticsStore(directory: dir, saveDelay: 3600, notifyInterval: 3600, notificationCenter: NotificationCenter(), now: { clock.now })
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
    }

    // MARK: - Tages- und Monatsdateien

    func testCurrentMonthByDayPastMonthsByMonthOnlyDirtyWritten() throws {
        let clock = Clock(date(2026, 11, 5))
        let store = makeStore(clock)
        store.updateDay(date(2026, 10, 3), calendar: calendar) { $0.dictations = 1 }
        store.updateDay(date(2026, 11, 5), calendar: calendar) { $0.dictations = 2 }
        store.update { $0.chatsBackfilled = true }
        store.flush()

        XCTAssertTrue(exists("months/2026-10.json"))
        XCTAssertTrue(exists("days/2026-11-05.json"))
        XCTAssertTrue(exists(StatisticsStore.metaFileName))
        XCTAssertFalse(exists("stats.json"))

        // Nur der geänderte Tag wird neu geschrieben.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("months/2026-10.json"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(StatisticsStore.metaFileName))
        store.updateDay(date(2026, 11, 5), calendar: calendar) { $0.dictations += 1 }
        store.flush()
        XCTAssertFalse(exists("months/2026-10.json"))
        XCTAssertFalse(exists(StatisticsStore.metaFileName))
        XCTAssertTrue(exists("days/2026-11-05.json"))
    }

    func testReloadMergesSegmentsAndMonthChangeConsolidates() throws {
        let clock = Clock(date(2026, 11, 5))
        let store = makeStore(clock)
        store.updateDay(date(2026, 10, 3), calendar: calendar) { $0.dictations = 1 }
        store.updateDay(date(2026, 11, 4), calendar: calendar) { $0.dictations = 4 }
        store.updateDay(date(2026, 11, 5), calendar: calendar) { $0.dictations = 5 }
        store.update { $0.chatsBackfilled = true }
        store.flush()

        let reloaded = makeStore(clock).snapshotSync()
        XCTAssertEqual(reloaded.days.mapValues(\.dictations), ["2026-10-03": 1, "2026-11-04": 4, "2026-11-05": 5])
        XCTAssertTrue(reloaded.chatsBackfilled)

        // Monatswechsel: die Novembertage wandern beim nächsten Sichern in eine Monatsdatei.
        clock.now = date(2026, 12, 1)
        store.updateDay(date(2026, 12, 1), calendar: calendar) { $0.dictations = 7 }
        store.flush()
        XCTAssertTrue(exists("months/2026-11.json"))
        XCTAssertFalse(exists("days/2026-11-04.json"))
        XCTAssertFalse(exists("days/2026-11-05.json"))
        XCTAssertTrue(exists("days/2026-12-01.json"))
        XCTAssertEqual(makeStore(clock).snapshotSync().days.count, 4)
    }

    func testLegacyStatsFileIsMigrated() throws {
        var legacy = StatsDatabase()
        legacy.days["2026-09-30"] = { var d = StatsDay(); d.dictations = 9; return d }()
        legacy.days["2026-11-05"] = { var d = StatsDay(); d.activeSeconds = 60; return d }()
        legacy.chatsBackfilled = true
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.statistics.encode(legacy).write(to: dir.appendingPathComponent("stats.json"))

        let clock = Clock(date(2026, 11, 5))
        XCTAssertEqual(makeStore(clock).snapshotSync(), legacy)
        XCTAssertFalse(exists("stats.json"))
        XCTAssertTrue(exists("months/2026-09.json"))
        XCTAssertTrue(exists("days/2026-11-05.json"))
        XCTAssertEqual(makeStore(clock).snapshotSync(), legacy)
    }

    func testCorruptSegmentIsQuarantinedOthersSurvive() throws {
        let clock = Clock(date(2026, 11, 5))
        let store = makeStore(clock)
        store.updateDay(date(2026, 10, 3), calendar: calendar) { $0.dictations = 1 }
        store.updateDay(date(2026, 11, 5), calendar: calendar) { $0.dictations = 2 }
        store.flush()
        try Data("{kaputt".utf8).write(to: dir.appendingPathComponent("months/2026-10.json"))

        let reloaded = makeStore(clock).snapshotSync()
        XCTAssertEqual(reloaded.days.mapValues(\.dictations), ["2026-11-05": 2])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("months").path)
        XCTAssertTrue(names.contains { $0.contains("corrupt") })
    }

    // MARK: - Generation

    func testGenerationGuardsUpdatesAndSaves() {
        let store = makeStore(Clock(date(2026, 11, 5)))
        let generation = store.generation
        store.reset()
        XCTAssertNotEqual(store.generation, generation)

        store.update(ifGeneration: generation) { $0.chatsBackfilled = true }
        var ran = false
        XCTAssertFalse(store.performIfCurrent(generation) { ran = true })
        XCTAssertFalse(ran)
        XCTAssertFalse(store.snapshotSync().chatsBackfilled)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        XCTAssertTrue(store.performIfCurrent(store.generation) { ran = true })
        XCTAssertTrue(ran)
    }

    // MARK: - Dedup

    func testDedupAppendsOnlyNewHashesAndCompactsLater() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dedup.bin")
        let set = StatisticsDedupSet()
        for value in stride(from: UInt64(1000), to: 1100, by: 1) { set.insert(value) }
        try set.save(to: url)
        XCTAssertEqual(set.lastWrittenBytes, 800)

        set.insert(5)
        set.insert(2000)
        try set.save(to: url)
        XCTAssertEqual(set.lastWrittenBytes, 16)
        XCTAssertEqual(try Data(contentsOf: url).count, 816)

        // Unverändert: kein Schreiben.
        try set.save(to: url)
        XCTAssertEqual(set.lastWrittenBytes, 0)

        // Absturz mitten im Anhängen: halber Wert am Ende.
        try StatisticsAppendFile.append(Data([1, 2, 3]), to: url)
        let loaded = StatisticsDedupSet.load(from: url)
        XCTAssertEqual(loaded.count, 102)
        XCTAssertTrue(loaded.contains(5))
        XCTAssertTrue(loaded.contains(2000))
        XCTAssertFalse(loaded.insert(1050))
        XCTAssertTrue(loaded.hasChanges)
        // Der kaputte Rest erzwingt ein sortiertes Neuschreiben.
        try loaded.save(to: url)
        XCTAssertEqual(loaded.lastWrittenBytes, 816)
        XCTAssertEqual(StatisticsDedupSet.load(from: url).count, 102)
    }

    // MARK: - Cursor-Journal

    func testCursorJournalAppendsChangesAndSkipsStaleLines() throws {
        let files = StatisticsScanStateFiles(directory: dir)
        var cursors: [String: StatisticsFileCursor] = [:]
        for index in 0..<200 {
            cursors["/p/file-\(index).jsonl"] = StatisticsFileCursor(size: Int64(index), mtime: 1, inode: UInt64(index), offset: Int64(index))
        }
        let persistence = files.loadCursors()
        try persistence.save(cursors)
        let baseBytes = persistence.lastWrittenBytes
        XCTAssertGreaterThan(baseBytes, 10_000)

        // Ein geänderter, ein entfernter Eintrag: nur zwei kurze Zeilen.
        cursors["/p/file-1.jsonl"]?.offset = 999
        cursors.removeValue(forKey: "/p/file-2.jsonl")
        try persistence.save(cursors)
        XCTAssertLessThan(persistence.lastWrittenBytes, 400)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.journalURL.path))

        // Ohne Änderung: nichts.
        try persistence.save(cursors)
        XCTAssertEqual(persistence.lastWrittenBytes, 0)

        XCTAssertEqual(files.loadCursors().saved, cursors)

        // Absturz nach dem Verdichten, bevor das alte Journal weg war: die
        // alte Zeile steckt schon in der Basis und darf nichts zurückdrehen.
        let staleJournal = try Data(contentsOf: files.journalURL)
        cursors["/p/file-1.jsonl"]?.offset = 1234
        let base = StatisticsScanCursors(files: cursors, seq: 5)
        try JSONEncoder().encode(base).write(to: files.cursorsURL)
        try staleJournal.write(to: files.journalURL)
        // Halbe letzte Zeile wird verworfen.
        try StatisticsAppendFile.append(Data(#"{"s":9,"k":"/p/x","c":{"si"#.utf8), to: files.journalURL)
        let reloaded = files.loadCursors()
        XCTAssertEqual(reloaded.saved, cursors)
        // … und erzwingt beim nächsten Sichern eine frische Basis.
        try reloaded.save(cursors)
        XCTAssertGreaterThan(reloaded.lastWrittenBytes, 10_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.journalURL.path))
    }
}
