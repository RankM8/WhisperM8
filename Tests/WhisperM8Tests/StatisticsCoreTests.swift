import XCTest
@testable import WhisperM8

final class StatisticsCoreTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - Zeit

    func testDayKeyAndWeekKey() {
        let thursday = date(2026, 11, 5, 19, 40)
        XCTAssertEqual(StatisticsTime.dayKey(for: thursday, calendar: calendar), "2026-11-05")
        XCTAssertEqual(StatisticsTime.weekKey(for: thursday, calendar: calendar), "2026-11-02")
        XCTAssertEqual(StatisticsTime.weekKey(for: date(2026, 11, 8, 23), calendar: calendar), "2026-11-02")
        XCTAssertEqual(StatisticsTime.weekKey(for: date(2026, 11, 9, 0, 1), calendar: calendar), "2026-11-09")
    }

    func testSlicesSplitAtHourAndDayBoundaries() {
        let slices = StatisticsTime.slices(from: date(2026, 11, 5, 23, 30), to: date(2026, 11, 6, 1, 15), calendar: calendar)
        XCTAssertEqual(slices.map(\.dayKey), ["2026-11-05", "2026-11-06", "2026-11-06"])
        XCTAssertEqual(slices.map(\.hour), [23, 0, 1])
        XCTAssertEqual(slices.map(\.seconds), [1800, 3600, 900])
        XCTAssertTrue(StatisticsTime.slices(from: date(2026, 11, 5), to: date(2026, 11, 5), calendar: calendar).isEmpty)
    }

    // MARK: - Preise

    func testPricingFamiliesAndFastMode() throws {
        let opus = try XCTUnwrap(ModelPricing.price(for: "claude-opus-5-5"))
        XCTAssertEqual(opus.input, 4)
        XCTAssertEqual(opus.cacheWrite5m, 5)
        XCTAssertEqual(opus.cacheWrite1h, 8)
        XCTAssertEqual(opus.cacheRead, 0.2)
        XCTAssertEqual(opus.output, 20)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5-5-fast")?.output, 40)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-1-20250805")?.output, 75)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-5-20251101")?.output, 25)
        XCTAssertEqual(ModelPricing.price(for: "gpt-6.1-sol")?.cacheRead, 0.10)
        XCTAssertEqual(ModelPricing.price(for: "openai/gpt-6.1-terra")?.output, 5)
        XCTAssertNil(ModelPricing.price(for: "<synthetic>"))
    }

    /// Modelle aus den echten Protokollen (Stand 5.11.2026) gegen die offiziellen
    /// Listen: keine Präfix-Treffer bei verwandten Modellen mehr.
    func testPricingMatchesOfficialListsForLoggedModels() throws {
        // Opus 4.5–4.8 und Opus 5 kosten 5/25 $, nur Opus 4.0/4.1 15/75 $.
        for id in ["claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-5"] {
            let price = try XCTUnwrap(ModelPricing.price(for: id), id)
            XCTAssertEqual(price.input, 5, id)
            XCTAssertEqual(price.cacheRead, 0.50, id)
            XCTAssertEqual(price.output, 25, id)
        }
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-20250514")?.output, 75)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-8-fast")?.output, 50)
        // Fable 5 liest den Cache zu 1 $, Fable 5.1 zu 0,25 $.
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5")?.cacheRead, 1)
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5-1")?.cacheRead, 0.25)
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5-1[1m]")?.output, 50)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5")?.cacheRead, 0.20)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5-5")?.cacheRead, 0.10)
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-5-5")?.output, 0.50)
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-4-5-20251001")?.output, 5)
        // GPT
        let astra = try XCTUnwrap(ModelPricing.price(for: "gpt-6-astra"))
        XCTAssertEqual(astra.input, 10)
        XCTAssertEqual(astra.cacheRead, 1)
        XCTAssertEqual(astra.output, 50)
        XCTAssertEqual(ModelPricing.price(for: "gpt-6-astra-fast")?.output, 100)
        XCTAssertEqual(ModelPricing.price(for: "gpt-5.6-sol-fast")?.output, 40)
        XCTAssertEqual(ModelPricing.price(for: "gpt-5.4-mini")?.output, 4.50)
        XCTAssertEqual(ModelPricing.price(for: "gpt-5-2025-08-07")?.output, 10)
        XCTAssertEqual(ModelPricing.price(for: "gpt-5.5-fast")?.output, 75)
    }

    func testUnknownModelsStayWithoutPrice() {
        // Kein offizieller Preis → kein Gegenwert, auch nicht über ein Präfix.
        for id in ["claude-opus-4-9", "claude-haiku-5", "gpt-5.7", "gpt-5.4-pro-fast", "claude-sonnet-5-fast",
                   "opus", "z-ai/glm-5.3-flash", "<synthetic>", ""] {
            XCTAssertNil(ModelPricing.price(for: id), id)
        }
    }

    func testReportCountsTokensWithoutPrice() {
        var db = StatsDatabase()
        db.updateDay("2026-11-05") { day in
            day.tokens["claude-opus-5-5"] = ["main": TokenUsage(messages: 1, input: 100, output: 50)]
            day.tokens["unbekannt-1"] = ["main": TokenUsage(messages: 2, input: 300, output: 20)]
        }
        let report = StatisticsReport.build(database: db, period: .all, now: date(2026, 11, 5, 20), calendar: calendar)
        XCTAssertEqual(report.unpricedTokens, 320)
        XCTAssertEqual(report.totalTokens, 470)
    }

    func testCostOfOneMillionOutputTokens() {
        let usage = TokenUsage(messages: 1, output: 1_000_000)
        XCTAssertEqual(ModelPricing.costUSD(model: "claude-sonnet-5-5", usage: usage) ?? 0, 10, accuracy: 0.0001)
    }

    func testDisplayNames() {
        XCTAssertEqual(ModelPricing.displayName(for: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-3-5-haiku-20241022"), "Haiku 3.5")
        XCTAssertEqual(ModelPricing.displayName(for: "gpt-6.1-sol"), "GPT 6.1 Sol")
        XCTAssertEqual(ModelPricing.displayName(for: "claude-opus-5-5-fast"), "Opus 5.5 (Fast)")
        XCTAssertTrue(ModelPricing.isOpenAIModel("gpt-5.6-sol"))
        XCTAssertFalse(ModelPricing.isOpenAIModel("claude-opus-5-5"))
    }

    // MARK: - EZB-Kurs

    func testParseECBRate() throws {
        let xml = "<Cube><Cube time='2026-11-05'><Cube currency='USD' rate='1.0870'/><Cube currency='JPY' rate='160.1'/></Cube></Cube>"
        let rate = try XCTUnwrap(StatisticsExchangeRate.parseUsdEurRate(fromECBXML: xml))
        XCTAssertEqual(rate, 1 / 1.087, accuracy: 0.00001)
        XCTAssertNil(StatisticsExchangeRate.parseUsdEurRate(fromECBXML: "<Cube/>"))
    }

    // MARK: - Limits

    func testLimitHistoryKeepsWeeklyPeakAndIgnoresOlderSnapshots() {
        var history = LimitHistory(provider: "claude")
        history.record(LimitSnapshot(weekPercent: 40, capturedAt: date(2026, 11, 3, 10)), calendar: calendar)
        history.record(LimitSnapshot(weekPercent: 71, capturedAt: date(2026, 11, 5, 10)), calendar: calendar)
        history.record(LimitSnapshot(weekPercent: 10, capturedAt: date(2026, 11, 4, 10)), calendar: calendar)
        XCTAssertEqual(history.current?.weekPercent, 71)
        XCTAssertEqual(history.weeklyPeaks["2026-11-02"], 71)
    }

    // MARK: - Bericht

    private func sampleDatabase() -> StatsDatabase {
        var db = StatsDatabase()
        db.updateDay("2026-11-02") { day in
            day.activeSeconds = 3600
            day.agentWorkingSeconds = 7200
            day.concurrencySeconds = 14400
            day.peakConcurrent = 4
            day.chatsStarted = ["claude": 3, "codex": 1]
            day.projectChats = ["whisperm8": 4]
            day.addTokens(TokenUsage(messages: 2, output: 1_000_000), model: "claude-opus-5-5", account: "main", project: "whisperm8")
            day.addTokens(TokenUsage(messages: 1, output: 1_000_000), model: "claude-opus-5-5", account: "RankM8", project: "listm8")
            day.dictations = 2
            day.dictationModes = ["Agent Chat": 2]
        }
        db.updateDay("2026-11-05") { day in
            day.activeSeconds = 1800
            day.addHourly(active: 1800, hour: 10)
            day.chatsStarted = ["gpt": 2]
            day.addTokens(TokenUsage(messages: 1, input: 1_000_000), model: "gpt-6.1-sol", account: "main", project: "whisperm8")
            day.commits = ["whisperm8": 3]
        }
        db.updateDay("2026-10-30") { day in
            day.activeSeconds = 999
        }
        db.limits["main"] = LimitHistory(provider: "claude", current: nil, weeklyPeaks: ["2026-11-02": 100, "2026-10-26": 80])
        db.limits["chatgpt:main"] = LimitHistory(provider: "chatgpt")
        return db
    }

    func testWeekReportAggregatesTimeTokensAndMoney() throws {
        let report = StatisticsReport.build(
            database: sampleDatabase(),
            period: .week,
            now: date(2026, 11, 5, 19),
            calendar: calendar,
            subscriptions: [StatisticsSubscription(name: "Max", count: 1, monthlyEUR: 365.0 / 12)],
            usdEurRate: 0.5,
            locale: Locale(identifier: "de_DE")
        )
        XCTAssertEqual(report.activeSeconds, 5400)
        XCTAssertEqual(report.agentSeconds, 7200)
        XCTAssertEqual(report.averageConcurrent, 2)
        XCTAssertEqual(report.peakConcurrent, 4)
        XCTAssertEqual(report.previousActiveSeconds, 999)
        XCTAssertEqual(report.elapsedDays, 4)
        XCTAssertEqual(report.activeDays, 2)
        XCTAssertEqual(report.buckets.count, 7)
        XCTAssertEqual(report.buckets.filter(\.isFuture).count, 3)

        // Opus: 2 Mio. Ausgabe × 20 $ = 40 $; GPT 6.1 Sol: 1 Mio. Eingabe × 2 $ = 2 $
        XCTAssertEqual(report.models.map(\.model), ["claude-opus-5-5", "gpt-6.1-sol"])
        XCTAssertEqual(report.totalUSD, 42, accuracy: 0.001)
        XCTAssertEqual(report.totalEUR, 21, accuracy: 0.001)
        XCTAssertEqual(report.accounts, ["main", "RankM8"])
        // Abo: 1 €/Tag × 4 Tage = 4 € → Hebel 21 / 4
        XCTAssertEqual(report.subscriptionCostEUR, 4, accuracy: 0.001)
        XCTAssertEqual(report.leverage ?? 0, 5.25, accuracy: 0.001)

        XCTAssertEqual(report.projects.first?.name, "whisperm8")
        XCTAssertEqual(report.projects.first?.chats, 4)
        XCTAssertEqual(report.chatsStarted, 6)
        XCTAssertEqual(report.chatsByKind[.gpt], 2)
        XCTAssertEqual(report.commits, 3)
        XCTAssertEqual(report.dictationModes.first?.name, "Agent Chat")
    }

    func testAccountFilterLimitsModels() {
        let report = StatisticsReport.build(
            database: sampleDatabase(),
            period: .week,
            accountFilter: "RankM8",
            now: date(2026, 11, 5, 19),
            calendar: calendar
        )
        XCTAssertEqual(report.models.count, 1)
        XCTAssertEqual(report.models.first?.usage.messages, 1)
        XCTAssertEqual(report.accounts, ["main", "RankM8"])
    }

    func testDayReportUsesHourlyBuckets() {
        let report = StatisticsReport.build(database: sampleDatabase(), period: .day, now: date(2026, 11, 5, 19), calendar: calendar)
        XCTAssertEqual(report.buckets.count, 24)
        XCTAssertEqual(report.buckets[10].activeSeconds, 1800)
        XCTAssertTrue(report.buckets[20].isFuture)
        XCTAssertEqual(report.previousActiveSeconds, nil)
    }

    func testAllReportGroupsByMonthFromFirstDay() {
        let report = StatisticsReport.build(database: sampleDatabase(), period: .all, now: date(2026, 11, 5, 19), calendar: calendar, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(report.buckets.count, 2)
        XCTAssertEqual(report.buckets[0].activeSeconds, 999)
        XCTAssertEqual(report.buckets[1].activeSeconds, 5400)
    }

    func testLimitRowsHaveEightWeeksAndCountFullWeeks() {
        let report = StatisticsReport.build(database: sampleDatabase(), period: .week, now: date(2026, 11, 5, 19), calendar: calendar)
        XCTAssertEqual(report.limits.map(\.account), ["main", "chatgpt:main"])
        XCTAssertEqual(report.limits[0].weeklyPeaks.count, 8)
        XCTAssertEqual(report.limits[0].weeklyPeaks.last ?? nil, 100)
        XCTAssertEqual(report.limits[0].weeksAtLimit, 1)
    }

    // MARK: - Store

    func testStorePersistsAndReloads() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StatisticsStore(directory: dir, saveDelay: 30, notificationCenter: NotificationCenter())
        store.updateDay(date(2026, 11, 5, 10), calendar: calendar) { $0.dictations += 2 }
        store.flush()
        let reloaded = StatisticsStore(directory: dir, notificationCenter: NotificationCenter())
        XCTAssertEqual(reloaded.snapshotSync().days["2026-11-05"]?.dictations, 2)
    }

    func testStoreQuarantinesCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{kaputt".utf8).write(to: dir.appendingPathComponent("stats.json"))
        let store = StatisticsStore(directory: dir, notificationCenter: NotificationCenter())
        XCTAssertEqual(store.snapshotSync(), StatsDatabase())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.contains("corrupt") })
    }

    func testDecodingToleratesMissingFields() throws {
        let json = #"{"days":{"2026-11-05":{"activeSeconds":12}}}"#
        let db = try JSONDecoder.statistics.decode(StatsDatabase.self, from: Data(json.utf8))
        XCTAssertEqual(db.days["2026-11-05"]?.activeSeconds, 12)
        XCTAssertEqual(db.days["2026-11-05"]?.tokens, [:])
        XCTAssertFalse(db.chatsBackfilled)
    }
}
