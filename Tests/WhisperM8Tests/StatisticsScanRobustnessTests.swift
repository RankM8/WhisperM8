import XCTest
@testable import WhisperM8

/// Protokoll-Leser: komprimierte Codex-Protokolle, Lesestand je Thread-UUID,
/// „Löschen…“ während eines Laufs und Drossel ohne Warteschleife.
final class StatisticsScanRobustnessTests: XCTestCase {
    private var root: URL!
    private var store: StatisticsStore!
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }()

    private let threadID = "019fb2af-17f7-73d1-9913-e553175e6b3b"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("statistics-robust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = StatisticsStore(directory: statsDirectory, saveDelay: 0, notifyInterval: 3600)
    }

    override func tearDownWithError() throws {
        store.flush()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Hilfen

    private var statsDirectory: URL { root.appendingPathComponent("stats") }
    private var mainProjects: URL { root.appendingPathComponent("claude-main/projects") }
    private var codexSessions: URL { root.appendingPathComponent("codex/sessions") }
    private var codexArchive: URL { root.appendingPathComponent("codex/archived_sessions") }

    /// Liest die „komprimierte“ Datei einfach als Klartext, in zwei Stücken,
    /// damit auch Zeilen über Stückgrenzen hinweg geprüft sind.
    private struct FakeDecompressor: StatisticsDecompressing {
        var fail = false
        func decompress(path: String, shouldStop: () -> Bool, _ chunk: (UnsafeRawBufferPointer) -> Void) -> Bool {
            guard !fail, let data = FileManager.default.contents(atPath: path) else { return false }
            let mid = data.count / 2
            data[..<mid].withUnsafeBytes { chunk($0) }
            data[mid...].withUnsafeBytes { chunk($0) }
            return true
        }
    }

    private func makeScanner(
        decompressor: StatisticsDecompressing? = FakeDecompressor(),
        shouldYield: @escaping () -> Bool = { false },
        sources: (() -> [StatisticsLogSource])? = nil
    ) -> StatisticsLogScanner {
        var deps = StatisticsLogScanner.Dependencies()
        deps.sources = sources ?? { [mainProjects, codexSessions, codexArchive] in
            [
                StatisticsLogSource(kind: .claude(profile: "main"), root: mainProjects),
                StatisticsLogSource(kind: .codex, root: codexSessions),
                StatisticsLogSource(kind: .codex, root: codexArchive),
            ]
        }
        deps.store = store
        deps.calendar = { [calendar] in calendar }
        deps.isEnabled = { true }
        deps.shouldYield = shouldYield
        deps.decompressor = { decompressor }
        deps.backfillFileDelay = 0
        deps.backfillFlushInterval = 0
        return StatisticsLogScanner(dependencies: deps)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func assistant(id: String, timestamp: String = "2026-11-05T10:00:00.000Z") -> String {
        #"{"message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}},"requestId":"r-\#(id)","type":"assistant","timestamp":"\#(timestamp)","cwd":"/Users/x/repos/whisperm8"}"#
    }

    private let codexMeta = #"{"timestamp":"2026-11-04T08:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/Users/x/repos/listm8"}}"#
    private let codexTurn = #"{"timestamp":"2026-11-04T08:00:01.000Z","type":"turn_context","payload":{"cwd":"/Users/x/repos/listm8","model":"gpt-6.1-sol"}}"#

    private func codexTokens(input: Int, output: Int, at time: String = "2026-11-04T08:00:05.000Z") -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":0},"last_token_usage":null},"rate_limits":null}}"#
    }

    private var rolloutName: String { "rollout-2026-11-04T08-00-00-\(threadID).jsonl" }

    private func codexUsage() -> TokenUsage? {
        store.snapshotSync().days["2026-11-04"]?.tokens["gpt-6.1-sol"]?["codex"]
    }

    // MARK: - zst

    func testThreadIDFromFileName() {
        XCTAssertEqual(StatisticsLogFile.codexThreadID(fromFileName: rolloutName), threadID)
        XCTAssertEqual(StatisticsLogFile.codexThreadID(fromFileName: rolloutName + ".zst"), threadID)
        XCTAssertNil(StatisticsLogFile.codexThreadID(fromFileName: "rollout-2026-11-04T08-00-00-abc.jsonl"))
        XCTAssertNil(StatisticsLogFile.codexThreadID(fromFileName: "rollout-x.json"))
    }

    func testCompressedRolloutIsReadThroughDecompressor() throws {
        let url = codexArchive.appendingPathComponent(rolloutName + ".zst")
        try write([codexMeta, codexTurn, codexTokens(input: 1000, output: 50), codexTokens(input: 3000, output: 80)], to: url)

        XCTAssertEqual(makeScanner().performScan(), .finished)
        XCTAssertEqual(codexUsage(), TokenUsage(messages: 2, input: 3000, output: 80))
        XCTAssertEqual(store.snapshotSync().days["2026-11-04"]?.projectTokens["listm8"]?["gpt-6.1-sol"]?.messages, 2)

        // Unverändert: nicht noch einmal entpacken.
        makeScanner(decompressor: FakeDecompressor(fail: true)).performScan()
        XCTAssertEqual(codexUsage()?.messages, 2)
        XCTAssertEqual(store.snapshotSync().lastScan?.filesRead, 0)
    }

    func testMissingDecompressorSkipsAndReportsThenCatchesUp() throws {
        try write([codexMeta, codexTurn, codexTokens(input: 1000, output: 50)], to: codexSessions.appendingPathComponent("2026/11/04/" + rolloutName + ".zst"))

        XCTAssertEqual(makeScanner(decompressor: nil).performScan(), .finished)
        XCTAssertNil(codexUsage())
        XCTAssertEqual(store.snapshotSync().lastScan?.skippedCompressedFiles, 1)

        // Fehlschlag beim Entpacken zählt nichts und merkt sich nichts.
        makeScanner(decompressor: FakeDecompressor(fail: true)).performScan()
        XCTAssertNil(codexUsage())

        makeScanner().performScan()
        XCTAssertEqual(codexUsage()?.messages, 1)
        XCTAssertNil(store.snapshotSync().lastScan?.skippedCompressedFiles)
    }

    // MARK: - Lesestand je Thread-UUID

    func testPartiallyReadRolloutThatGetsCompressedCountsOnlyTheRest() throws {
        let plain = codexSessions.appendingPathComponent("2026/11/04/" + rolloutName)
        let lines = [codexMeta, codexTurn, codexTokens(input: 1000, output: 50), codexTokens(input: 3000, output: 80)]
        try write(Array(lines.prefix(3)), to: plain)
        let scanner = makeScanner()
        scanner.performScan()
        XCTAssertEqual(codexUsage(), TokenUsage(messages: 1, input: 1000, output: 50))

        // Codex schreibt weiter und komprimiert danach: .jsonl weg, .zst da.
        try FileManager.default.removeItem(at: plain)
        try write(lines + [codexTokens(input: 3500, output: 90, at: "2026-11-04T09:00:00.000Z")], to: plain.appendingPathExtension("zst"))
        scanner.performScan()
        XCTAssertEqual(codexUsage(), TokenUsage(messages: 3, input: 3500, output: 90))

        // Und wieder entpackt (anderer Pfad, neuer Inode): nichts doppelt.
        try FileManager.default.removeItem(at: plain.appendingPathExtension("zst"))
        try write(lines + [codexTokens(input: 3500, output: 90, at: "2026-11-04T09:00:00.000Z")], to: plain)
        scanner.performScan()
        XCTAssertEqual(codexUsage(), TokenUsage(messages: 3, input: 3500, output: 90))

        // Weiterschreiben der entpackten Datei zählt nur den Zuwachs.
        try append(codexTokens(input: 4000, output: 100, at: "2026-11-04T10:00:00.000Z") + "\n", to: plain)
        scanner.performScan()
        XCTAssertEqual(codexUsage(), TokenUsage(messages: 4, input: 4000, output: 100))
    }

    func testMovedRolloutDoesNotCountTwice() throws {
        let plain = codexSessions.appendingPathComponent("2026/11/04/" + rolloutName)
        try write([codexMeta, codexTurn, codexTokens(input: 1000, output: 50)], to: plain)
        let scanner = makeScanner()
        scanner.performScan()

        // Ins Archiv verschoben (gleicher Inode) …
        let archived = codexArchive.appendingPathComponent(rolloutName)
        try FileManager.default.createDirectory(at: codexArchive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: plain, to: archived)
        scanner.performScan()
        XCTAssertEqual(codexUsage()?.messages, 1)

        // … und als Kopie zurück (neuer Inode): weiterhin einmal.
        try FileManager.default.copyItem(at: archived, to: plain)
        try FileManager.default.removeItem(at: archived)
        scanner.performScan()
        XCTAssertEqual(codexUsage(), TokenUsage(messages: 1, input: 1000, output: 50))
    }

    func testPlainAndCompressedTwinCountsOnce() throws {
        let plain = codexSessions.appendingPathComponent("2026/11/04/" + rolloutName)
        let lines = [codexMeta, codexTurn, codexTokens(input: 1000, output: 50)]
        try write(lines, to: plain)
        try write(lines, to: plain.appendingPathExtension("zst"))
        makeScanner().performScan()
        XCTAssertEqual(codexUsage()?.messages, 1)
    }

    func testOldPathKeyedCodexCursorIsMigrated() throws {
        let plain = codexSessions.appendingPathComponent("2026/11/04/" + rolloutName)
        try write([codexMeta, codexTurn, codexTokens(input: 1000, output: 50)], to: plain)
        makeScanner().performScan()

        // Alten Stand nachbauen: Schlüssel = Pfad.
        let files = StatisticsScanStateFiles(directory: statsDirectory)
        var old = files.loadCursors().saved
        let cursor = try XCTUnwrap(old.removeValue(forKey: "codex:" + threadID))
        old[plain.path] = cursor
        try? FileManager.default.removeItem(at: files.journalURL)
        try JSONEncoder().encode(StatisticsScanCursors(files: old)).write(to: files.cursorsURL)

        try append(codexTokens(input: 1500, output: 60, at: "2026-11-04T09:00:00.000Z") + "\n", to: plain)
        makeScanner().performScan()
        XCTAssertEqual(codexUsage(), TokenUsage(messages: 2, input: 1500, output: 60))
    }

    // MARK: - Löschen während eines Laufs

    func testResetDuringRunSavesNothing() throws {
        try write([assistant(id: "m1")], to: mainProjects.appendingPathComponent("-p/s1.jsonl"))
        let sources: () -> [StatisticsLogSource] = { [store, mainProjects] in
            // „Löschen…“ kommt, nachdem der Lauf seine Generation gemerkt hat.
            store!.reset()
            return [StatisticsLogSource(kind: .claude(profile: "main"), root: mainProjects)]
        }
        XCTAssertEqual(makeScanner(sources: sources).performScan(), .aborted)

        let files = StatisticsScanStateFiles(directory: statsDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.cursorsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.journalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.dedupURL.path))
        XCTAssertTrue(store.snapshotSync().days.isEmpty)

        // Der nächste Lauf liest alles neu ein.
        makeScanner().performScan()
        XCTAssertEqual(store.snapshotSync().days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 1)
    }

    func testGitCollectorSavesNoCursorAfterReset() {
        let collector = StatisticsGitCollector()
        collector.store = store
        collector.projectPaths = { ["/tmp/nirgends"] }
        collector.isConstrained = { false }
        collector.makeScanner = { [store] in
            store!.reset()
            var scanner = StatisticsGitScanner()
            scanner.hasGitDirectory = { _ in false }
            return scanner
        }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: StatisticsPreferenceKeys.enabled)
        defaults.set(true, forKey: StatisticsPreferenceKeys.enabled)
        defer { defaults.set(previous, forKey: StatisticsPreferenceKeys.enabled) }

        collector.collectNow()
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: collector.cursorURL.path))
    }

    // MARK: - Drossel

    func testYieldDefersHistoryButIncrementalRunsContinue() throws {
        let old = mainProjects.appendingPathComponent("-p/old.jsonl")
        let recent = mainProjects.appendingPathComponent("-p/recent.jsonl")
        try write([assistant(id: "old")], to: old)
        try write([assistant(id: "recent")], to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)

        // Erster Lauf: eine Datei, dann verlangt die Drossel Platz.
        var calls = 0
        let first = makeScanner(shouldYield: { calls += 1; return calls > 1 })
        XCTAssertEqual(first.performScan(), .deferred)
        var db = store.snapshotSync()
        XCTAssertNil(db.backfill.finishedAt)
        XCTAssertEqual(db.days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 1)

        // Dauerhaft gedrosselt: neue Zeilen der bekannten Datei kommen trotzdem.
        try append(assistant(id: "recent-2") + "\n", to: recent)
        let throttled = makeScanner(shouldYield: { true })
        XCTAssertEqual(throttled.performScan(), .deferred)
        db = store.snapshotSync()
        XCTAssertEqual(db.days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 2)

        // Pause des Nutzers wirkt genauso nur auf die Historie.
        // Die Pause liegt im Store; ein neuer Leser übernimmt sie von dort.
        throttled.setBackfillPaused(true)
        try append(assistant(id: "recent-3") + "\n", to: recent)
        let paused = makeScanner()
        XCTAssertEqual(paused.performScan(), .deferred)
        XCTAssertEqual(store.snapshotSync().days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 3)

        paused.setBackfillPaused(false)
        XCTAssertEqual(paused.performScan(), .finished)
        db = store.snapshotSync()
        XCTAssertEqual(db.days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 4)
        XCTAssertNotNil(db.backfill.finishedAt)
    }

    func testUserPauseDefersHistory() throws {
        try write([assistant(id: "a")], to: mainProjects.appendingPathComponent("-p/a.jsonl"))
        let scanner = makeScanner()
        scanner.setBackfillPaused(true)
        XCTAssertEqual(scanner.performScan(), .deferred)
        XCTAssertNil(store.snapshotSync().days["2026-11-05"])
        scanner.setBackfillPaused(false)
        XCTAssertEqual(scanner.performScan(), .finished)
        XCTAssertEqual(store.snapshotSync().days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 1)
    }

    func testCalendarIsFetchedPerRun() throws {
        try write([assistant(id: "late", timestamp: "2026-11-05T23:30:00.000Z")], to: mainProjects.appendingPathComponent("-p/a.jsonl"))
        var zone = "Europe/Berlin"
        var deps = StatisticsLogScanner.Dependencies()
        deps.sources = { [mainProjects] in [StatisticsLogSource(kind: .claude(profile: "main"), root: mainProjects)] }
        deps.store = store
        deps.calendar = {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: zone)!
            return cal
        }
        deps.isEnabled = { true }
        deps.shouldYield = { false }
        deps.backfillFileDelay = 0
        let scanner = StatisticsLogScanner(dependencies: deps)
        zone = "America/New_York"
        scanner.performScan()
        // 23:30 UTC ist in New York noch der 5., in Berlin schon der 6.
        XCTAssertNotNil(store.snapshotSync().days["2026-11-05"])
        XCTAssertNil(store.snapshotSync().days["2026-11-06"])
    }
}
