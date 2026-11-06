import XCTest
@testable import WhisperM8

final class StatisticsLogScannerTests: XCTestCase {
    private var root: URL!
    private var store: StatisticsStore!
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("statistics-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = StatisticsStore(directory: root.appendingPathComponent("stats"), saveDelay: 0, notifyInterval: 3600)
    }

    override func tearDownWithError() throws {
        store.flush()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Hilfen

    private var mainProjects: URL { root.appendingPathComponent("claude-main/projects") }
    private var rankProjects: URL { root.appendingPathComponent("claude-rank/projects") }
    private var codexSessions: URL { root.appendingPathComponent("codex/sessions") }

    private func makeDependencies() -> StatisticsLogScanner.Dependencies {
        var deps = StatisticsLogScanner.Dependencies()
        deps.sources = { [mainProjects, rankProjects, codexSessions] in
            [
                StatisticsLogSource(kind: .claude(profile: "main"), root: mainProjects),
                StatisticsLogSource(kind: .claude(profile: "RankM8"), root: rankProjects),
                StatisticsLogSource(kind: .codex, root: codexSessions),
            ]
        }
        deps.store = store
        deps.calendar = { [calendar] in calendar }
        deps.isEnabled = { true }
        deps.shouldYield = { false }
        deps.decompressor = { nil }
        deps.backfillFileDelay = 0
        deps.backfillFlushInterval = 0
        return deps
    }

    private func makeScanner() -> StatisticsLogScanner {
        StatisticsLogScanner(dependencies: makeDependencies())
    }

    private func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = lines.joined(separator: "\n")
        if trailingNewline { text += "\n" }
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func assistant(
        id: String = "msg_1",
        request: String = "req_1",
        model: String = "claude-opus-5-5",
        timestamp: String = "2026-11-05T10:00:00.000Z",
        cwd: String = "/Users/x/repos/whisperm8",
        input: Int = 10,
        output: Int = 100,
        cacheCreation: Int = 1000,
        split: (Int, Int)? = (200, 800),
        cacheRead: Int = 5000,
        speed: String = "standard",
        block: String = "text"
    ) -> String {
        let splitJSON = split.map { #","cache_creation":{"ephemeral_5m_input_tokens":\#($0.0),"ephemeral_1h_input_tokens":\#($0.1)}"# } ?? ""
        return #"{"parentUuid":"p","isSidechain":false,"message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"\#(block)","text":"hallo"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output)\#(splitJSON),"speed":"\#(speed)"}},"requestId":"\#(request)","type":"assistant","uuid":"u","timestamp":"\#(timestamp)","cwd":"\#(cwd)"}"#
    }

    private let userLine = #"{"type":"user","message":{"role":"user","content":"sag mal \"usage\" und assistant"},"timestamp":"2026-11-05T09:59:00.000Z","cwd":"/x"}"#

    private func codexMeta(cwd: String = "/Users/x/repos/listm8") -> String {
        #"{"timestamp":"2026-11-04T08:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"\#(cwd)","base_instructions":{"text":"lang"}}}"#
    }

    private func codexTurn(model: String = "gpt-6.1-sol") -> String {
        #"{"timestamp":"2026-11-04T08:00:01.000Z","type":"turn_context","payload":{"cwd":"/Users/x/repos/listm8","model":"\#(model)"}}"#
    }

    private func codexTokens(input: Int, cached: Int, output: Int, at time: String = "2026-11-04T08:00:05.000Z", limits: String = "null") -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":0},"last_token_usage":null},"rate_limits":\#(limits)}}"#
    }

    private func db() -> StatsDatabase {
        store.snapshotSync()
    }

    // MARK: - Parser

    func testParserReadsClaudeAssistantLine() throws {
        let record = try XCTUnwrap(StatisticsLogParser.parseClaudeLine(Data(assistant().utf8)))
        XCTAssertEqual(record.model, "claude-opus-5-5")
        XCTAssertEqual(record.project, "whisperm8")
        XCTAssertEqual(record.usage, TokenUsage(messages: 1, input: 10, output: 100, cacheWrite5m: 200, cacheWrite1h: 800, cacheRead: 5000))
        XCTAssertEqual(record.timestamp, Date(timeIntervalSince1970: 1_793_872_800))
        XCTAssertNotNil(record.dedupKey)
    }

    func testParserFastSuffixSyntheticAndUnsplitCache() throws {
        let fast = try XCTUnwrap(StatisticsLogParser.parseClaudeLine(Data(assistant(speed: "fast").utf8)))
        XCTAssertEqual(fast.model, "claude-opus-5-5" + ModelPricing.fastSuffix)
        XCTAssertNil(StatisticsLogParser.parseClaudeLine(Data(assistant(model: "<synthetic>").utf8)))
        XCTAssertNil(StatisticsLogParser.parseClaudeLine(Data(userLine.utf8)))
        let unsplit = try XCTUnwrap(StatisticsLogParser.parseClaudeLine(Data(assistant(split: nil).utf8)))
        XCTAssertEqual(unsplit.usage.cacheWrite5m, 1000)
        XCTAssertEqual(unsplit.usage.cacheWrite1h, 0)
    }

    func testTimestampParsing() {
        XCTAssertEqual(StatisticsLogParser.parseTimestamp("1970-01-01T00:00:00Z"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(StatisticsLogParser.parseTimestamp("2026-11-05T12:00:00.500+02:00"), Date(timeIntervalSince1970: 1_793_872_800.5))
        XCTAssertNil(StatisticsLogParser.parseTimestamp("kaputt"))
    }

    func testCodexDeltaSubtractsCachedAndIgnoresRepeats() {
        let first = StatisticsLogParser.codexDelta(from: CodexTokenTotals(), to: CodexTokenTotals(input: 1000, cached: 600, output: 50))
        XCTAssertEqual(first, TokenUsage(messages: 1, input: 400, output: 50, cacheRead: 600))
        let same = CodexTokenTotals(input: 1000, cached: 600, output: 50)
        XCTAssertNil(StatisticsLogParser.codexDelta(from: same, to: same))
    }

    func testDedupSetPersistsSorted() throws {
        let set = StatisticsDedupSet()
        XCTAssertTrue(set.insert(42))
        XCTAssertTrue(set.insert(7))
        XCTAssertFalse(set.insert(42))
        let url = root.appendingPathComponent("dedup.bin")
        try set.save(to: url)
        let loaded = StatisticsDedupSet.load(from: url)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains(7))
        XCTAssertFalse(loaded.insert(42))
        XCTAssertTrue(loaded.insert(1))
    }

    // MARK: - Claude

    func testClaudeDedupWithinAndAcrossFilesAndAccounts() throws {
        // Zwei Content-Blöcke derselben Antwort, eine zweite Antwort, eine
        // Nutzerzeile mit „usage“ im Text.
        try write([
            assistant(block: "thinking"),
            assistant(block: "text"),
            userLine,
            assistant(id: "msg_2", request: "req_2", output: 7),
        ], to: mainProjects.appendingPathComponent("-proj/s1.jsonl"))
        // Kontowechsel: dieselbe Antwort in einem anderen Profil.
        try write([assistant()], to: rankProjects.appendingPathComponent("-proj/s1.jsonl"))

        makeScanner().performScan()

        let day = try XCTUnwrap(db().days["2026-11-05"])
        let opus = try XCTUnwrap(day.tokens["claude-opus-5-5"])
        let total = opus.values.reduce(TokenUsage(), +)
        XCTAssertEqual(total.messages, 2)
        XCTAssertEqual(total.output, 107)
        XCTAssertEqual(day.projectTokens["whisperm8"]?["claude-opus-5-5"]?.messages, 2)
    }

    func testGPTModelsCountUnderProxyAccount() throws {
        try write([assistant(model: "gpt-6.1-sol")], to: rankProjects.appendingPathComponent("-proj/s.jsonl"))
        makeScanner().performScan()
        let day = try XCTUnwrap(db().days["2026-11-05"])
        XCTAssertEqual(day.tokens["gpt-6.1-sol"]?[StatisticsLogParser.gptProxyAccount]?.messages, 1)
        XCTAssertNil(day.tokens["gpt-6.1-sol"]?["RankM8"])
    }

    func testHalfLastLineIsReadOnNextRun() throws {
        let url = mainProjects.appendingPathComponent("-proj/s.jsonl")
        let second = assistant(id: "msg_2", request: "req_2")
        let cut = second.index(second.startIndex, offsetBy: 40)
        try write([assistant(), String(second[..<cut])], to: url, trailingNewline: false)

        let scanner = makeScanner()
        scanner.performScan()
        XCTAssertEqual(db().days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 1)

        try append(String(second[cut...]) + "\n", to: url)
        scanner.performScan()
        XCTAssertEqual(db().days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 2)

        // Ohne Änderung bleibt alles, wie es ist.
        scanner.performScan()
        XCTAssertEqual(db().days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 2)
        XCTAssertEqual(db().lastScan?.filesRead, 0)
    }

    func testShrunkFileIsReadFromStartWithoutDoubleCounting() throws {
        let url = mainProjects.appendingPathComponent("-proj/s.jsonl")
        try write([assistant(), assistant(id: "msg_2", request: "req_2")], to: url)
        let scanner = makeScanner()
        scanner.performScan()

        // Kürzer neu geschrieben, mit einer neuen Antwort.
        try write([assistant(id: "msg_3", request: "req_3")], to: url)
        scanner.performScan()

        XCTAssertEqual(db().days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 3)
    }

    func testSubagentsAreCountedOncePerRunAndAcrossAccounts() throws {
        let relative = "-proj/s1/subagents/agent-a1.jsonl"
        try write([userLine, assistant(id: "msg_s", request: "req_s")], to: mainProjects.appendingPathComponent(relative))
        try write([userLine, assistant(id: "msg_s", request: "req_s")], to: rankProjects.appendingPathComponent(relative))
        try write([userLine], to: mainProjects.appendingPathComponent("-proj/s1/subagents/workflows/wf_1/agent-b2.jsonl"))
        // Andere Unterordner werden nicht gelesen.
        try write([assistant(id: "msg_x", request: "req_x")], to: mainProjects.appendingPathComponent("-proj/s1/tool-results/x.jsonl"))

        let scanner = makeScanner()
        scanner.performScan()
        try append(assistant(id: "msg_t", request: "req_t") + "\n", to: mainProjects.appendingPathComponent(relative))
        scanner.performScan()

        let day = try XCTUnwrap(db().days["2026-11-05"])
        XCTAssertEqual(day.subagentsStarted, 2)
        XCTAssertEqual(day.tokens["claude-opus-5-5"]?.values.reduce(0) { $0 + $1.messages }, 2)
    }

    // MARK: - Codex

    func testCodexDifferencesRepeatsNullInfoAndLimits() throws {
        let limitsOld = #"{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1794392004},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1794900000},"plan_type":"pro"}"#
        let limitsNew = #"{"primary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1794392004},"secondary":null,"plan_type":"pro"}"#
        let url = codexSessions.appendingPathComponent("2026/11/04/rollout-2026-11-04T08-00-00-abc.jsonl")
        try write([
            codexMeta(),
            codexTurn(),
            codexTokens(input: 1000, cached: 600, output: 50, limits: limitsOld),
            codexTokens(input: 1000, cached: 600, output: 50),
            #"{"timestamp":"2026-11-04T08:00:06.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#,
            codexTokens(input: 3000, cached: 2000, output: 80, at: "2026-11-04T09:00:00.000Z", limits: limitsNew),
        ], to: url)

        let scanner = makeScanner()
        scanner.performScan()

        var day = try XCTUnwrap(db().days["2026-11-04"])
        XCTAssertEqual(
            day.tokens["gpt-6.1-sol"]?["codex"],
            TokenUsage(messages: 2, input: 1000, output: 80, cacheRead: 2000)
        )
        XCTAssertEqual(day.projectTokens["listm8"]?["gpt-6.1-sol"]?.messages, 2)

        let limits = try XCTUnwrap(db().limits["codex"])
        XCTAssertEqual(limits.provider, "chatgpt")
        XCTAssertEqual(limits.plan, "Pro")
        XCTAssertEqual(limits.current?.weekPercent, 11)
        XCTAssertNil(limits.current?.fiveHourPercent)
        XCTAssertEqual(limits.weeklyPeaks["2026-11-02"], 20)

        // Weiterschreiben: nur der Zuwachs zählt, Modellwechsel greift.
        try append(codexTurn(model: "gpt-6.1-terra") + "\n" + codexTokens(input: 3500, cached: 2100, output: 90, at: "2026-11-04T09:30:00.000Z") + "\n", to: url)
        scanner.performScan()
        day = try XCTUnwrap(db().days["2026-11-04"])
        XCTAssertEqual(day.tokens["gpt-6.1-terra"]?["codex"], TokenUsage(messages: 1, input: 400, output: 10, cacheRead: 100))
        XCTAssertEqual(day.tokens["gpt-6.1-sol"]?["codex"]?.messages, 2)
    }

    // MARK: - Ablauf

    func testBackfillProgressAndRescanAll() throws {
        for index in 0..<5 {
            try write(
                [assistant(id: "m\(index)", request: "r\(index)")],
                to: mainProjects.appendingPathComponent("-proj/s\(index).jsonl")
            )
        }
        let scanner = makeScanner()
        scanner.performScan()

        var snapshot = db()
        XCTAssertEqual(snapshot.backfill.totalFiles, 5)
        XCTAssertEqual(snapshot.backfill.processedFiles, 5)
        XCTAssertNotNil(snapshot.backfill.finishedAt)
        XCTAssertEqual(snapshot.days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 5)

        // Fremde Tageswerte bleiben beim Neu-Einlesen unangetastet.
        store.updateDay(Date(timeIntervalSince1970: 1_793_872_800), calendar: calendar) { $0.dictations = 3 }

        scanner.markRescanRequested()
        scanner.performScan()

        snapshot = db()
        XCTAssertEqual(snapshot.days["2026-11-05"]?.tokens["claude-opus-5-5"]?["main"]?.messages, 5)
        XCTAssertEqual(snapshot.days["2026-11-05"]?.dictations, 3)
        XCTAssertNotNil(snapshot.backfill.finishedAt)
    }

    func testDisabledStatisticsReadsNothing() throws {
        try write([assistant()], to: mainProjects.appendingPathComponent("-proj/s.jsonl"))
        var deps = StatisticsLogScanner.Dependencies()
        deps.sources = { [mainProjects] in [StatisticsLogSource(kind: .claude(profile: "main"), root: mainProjects)] }
        deps.store = store
        deps.isEnabled = { false }
        StatisticsLogScanner(dependencies: deps).performScan()
        XCTAssertTrue(db().days.isEmpty)
    }
}
