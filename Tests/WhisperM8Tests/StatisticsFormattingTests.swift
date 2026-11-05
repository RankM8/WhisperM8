import XCTest
@testable import WhisperM8

/// Reine Hilfslogik der Statistik-Seite: Formatierung (de/en), Farbzuordnung,
/// Seitendaten und Teilen-Export.
final class StatisticsFormattingTests: XCTestCase {
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")
    private let nbsp = "\u{00A0}"

    // MARK: - Dauer

    func testDurationGermanAndEnglish() {
        XCTAssertEqual(StatisticsFormat.duration(6 * 3600 + 5 * 60, locale: de), "6h 05min")
        XCTAssertEqual(StatisticsFormat.duration(6 * 3600 + 5 * 60, locale: en), "6h 05m")
        XCTAssertEqual(StatisticsFormat.duration(42 * 60, locale: de), "42min")
        XCTAssertEqual(StatisticsFormat.duration(42 * 60, locale: en), "42m")
        XCTAssertEqual(StatisticsFormat.duration(0, locale: de), "0min")
        XCTAssertEqual(StatisticsFormat.duration(-30, locale: de), "0min")
    }

    func testDurationAbove100HoursShowsWholeHours() {
        XCTAssertEqual(StatisticsFormat.duration(1_234 * 3600, locale: de), "1.234 h")
        XCTAssertEqual(StatisticsFormat.duration(1_234 * 3600, locale: en), "1,234 h")
    }

    func testHoursShort() {
        XCTAssertEqual(StatisticsFormat.hoursShort(4.2 * 3600, locale: de), "4,2 h")
        XCTAssertEqual(StatisticsFormat.hoursShort(4.2 * 3600, locale: en), "4.2 h")
        XCTAssertEqual(StatisticsFormat.hoursShort(25.6 * 3600, locale: de), "26 h")
    }

    // MARK: - Euro

    func testEuroAbove100WithoutCents() {
        XCTAssertEqual(StatisticsFormat.euro(3264.4, locale: de), "3.264\(nbsp)€")
        XCTAssertEqual(StatisticsFormat.euro(3264.4, locale: en), "€3,264")
    }

    func testEuroBelow100WithCents() {
        XCTAssertEqual(StatisticsFormat.euro(7.2, locale: de), "7,20\(nbsp)€")
        XCTAssertEqual(StatisticsFormat.euro(7.2, locale: en), "€7.20")
    }

    // MARK: - Token

    func testTokensCompactGerman() {
        XCTAssertEqual(StatisticsFormat.tokens(7_640_000_000, locale: de), "7,64 Mrd.")
        XCTAssertEqual(StatisticsFormat.tokens(21_400_000, locale: de), "21,4 Mio.")
        XCTAssertEqual(StatisticsFormat.tokens(228_200, locale: de), "228 Tsd.")
        XCTAssertEqual(StatisticsFormat.tokens(512, locale: de), "512")
        XCTAssertEqual(StatisticsFormat.tokens(0, locale: de), "–")
    }

    func testTokensCompactEnglish() {
        XCTAssertEqual(StatisticsFormat.tokens(7_640_000_000, locale: en), "7.64B")
        XCTAssertEqual(StatisticsFormat.tokens(21_400_000, locale: en), "21.4M")
        XCTAssertEqual(StatisticsFormat.tokens(228_200, locale: en), "228K")
    }

    // MARK: - Prozent, Faktor, Größe

    func testPercentAndMultiplier() {
        XCTAssertEqual(StatisticsFormat.percent(0.78, locale: de), "78\(nbsp)%")
        XCTAssertEqual(StatisticsFormat.percent(0.78, locale: en), "78%")
        XCTAssertEqual(StatisticsFormat.percent(0.0234, digits: 1, locale: en), "2.3%")
        XCTAssertEqual(StatisticsFormat.percentValue(34, locale: en), "34%")
        XCTAssertEqual(StatisticsFormat.multiplier(17.24, locale: de), "17,2×")
        XCTAssertEqual(StatisticsFormat.multiplier(17.24, locale: en), "17.2×")
    }

    func testBytes() {
        XCTAssertEqual(StatisticsFormat.bytes(1_400_000, locale: de), "1,4 MB")
        XCTAssertEqual(StatisticsFormat.bytes(1_400_000, locale: en), "1.4 MB")
        XCTAssertEqual(StatisticsFormat.bytes(0, locale: en), "0 KB")
        XCTAssertEqual(StatisticsFormat.bytes(300, locale: en), "1 KB")
    }

    func testTypingTimeAtFortyWordsPerMinute() {
        XCTAssertEqual(StatisticsFormat.typingSeconds(words: 400), 600)
        XCTAssertEqual(StatisticsFormat.typingSeconds(words: -5), 0)
    }

    // MARK: - Farben

    private func database(_ entries: [(day: String, model: String, account: String, usage: TokenUsage)]) -> StatsDatabase {
        var db = StatsDatabase()
        for entry in entries {
            db.updateDay(entry.day) { $0.addTokens(entry.usage, model: entry.model, account: entry.account, project: nil) }
        }
        return db
    }

    func testPaletteOrderFollowsAllTimeValueNotPeriodRank() {
        // Opus ist über die ganze Historie vorn, heute hat Sonnet mehr.
        let db = database([
            ("2026-10-01", "claude-opus-5-5", "main", TokenUsage(messages: 10, output: 5_000_000)),
            ("2026-11-05", "claude-sonnet-5-5", "main", TokenUsage(messages: 5, output: 1_000_000)),
            ("2026-11-05", "claude-opus-5-5", "main", TokenUsage(messages: 1, output: 1_000)),
        ])
        let order = StatisticsPalette.modelOrder(database: db)
        XCTAssertEqual(order, ["claude-opus-5-5", "claude-sonnet-5-5"])
        XCTAssertEqual(StatisticsPalette.slot(for: "claude-opus-5-5", order: order), 0)
        XCTAssertEqual(StatisticsPalette.slot(for: "claude-sonnet-5-5", order: order), 1)
    }

    func testPaletteIsStableAndGreyBeyondFourModels() {
        let models = ["claude-opus-5-5", "claude-sonnet-5-5", "gpt-6.1-sol", "gpt-5.6-sol", "claude-haiku-5"]
        let db = database(models.enumerated().map { index, model in
            ("2026-11-0\(index + 1)", model, "main", TokenUsage(messages: 1, output: (5 - index) * 1_000_000))
        })
        let first = StatisticsPalette.modelOrder(database: db)
        XCTAssertEqual(first, StatisticsPalette.modelOrder(database: db))
        XCTAssertEqual(first.count, 5)
        XCTAssertNil(StatisticsPalette.slot(for: first[4], order: first))
        XCTAssertNil(StatisticsPalette.slot(for: "unknown-model", order: first))
    }

    func testPaletteIgnoresAccountFilter() {
        // Die Reihenfolge rechnet über alle Konten — ein Konto-Filter auf der Seite ändert nichts.
        let db = database([
            ("2026-11-01", "claude-opus-5-5", "main", TokenUsage(messages: 1, output: 4_000_000)),
            ("2026-11-01", "claude-sonnet-5-5", "RankM8", TokenUsage(messages: 1, output: 1_000_000)),
        ])
        let data = StatisticsPageData.build(
            database: db, period: .all, accountFilter: "RankM8", subscriptions: [],
            usdEurRate: 0.92, now: Self.date("2026-11-05")
        )
        XCTAssertEqual(data.modelOrder.first, "claude-opus-5-5")
        XCTAssertEqual(data.report.models.map(\.model), ["claude-sonnet-5-5"])
    }

    // MARK: - Seitendaten

    func testModelSourcesSeparateCodexAndProxy() {
        let db = database([
            ("2026-11-03", "gpt-5.6-sol", "codex", TokenUsage(messages: 1, input: 1_000)),
            ("2026-11-03", "gpt-6.1-sol", "main", TokenUsage(messages: 1, input: 1_000)),
            ("2026-11-03", "claude-opus-5-5", "main", TokenUsage(messages: 1, input: 1_000)),
        ])
        let data = StatisticsPageData.build(
            database: db, period: .week, accountFilter: nil, subscriptions: [],
            usdEurRate: 0.92, now: Self.date("2026-11-05")
        )
        XCTAssertEqual(data.modelSources["gpt-5.6-sol"], .codex)
        XCTAssertEqual(data.modelSources["gpt-6.1-sol"], .proxy)
        XCTAssertEqual(data.modelSources["claude-opus-5-5"], .claudeCode)
        XCTAssertEqual(data.tokenTotals.input, 3_000)
        XCTAssertTrue(data.hasData)
    }

    // MARK: - Teilen

    private func shareData() -> StatisticsPageData {
        var db = database([
            ("2026-11-03", "claude-opus-5-5", "main", TokenUsage(messages: 100, output: 2_000_000, cacheRead: 50_000_000)),
        ])
        db.updateDay("2026-11-03") { day in
            day.activeSeconds = 5 * 3600
            day.agentWorkingSeconds = 9 * 3600
            day.chatsStarted = ["claude": 12]
            day.dictations = 30
            day.projectChats = ["kunde-geheim": 8, "whisperm8": 4]
            day.projectTokens = ["kunde-geheim": ["claude-opus-5-5": TokenUsage(messages: 50, output: 1_500_000)]]
        }
        return StatisticsPageData.build(
            database: db, period: .week, accountFilter: nil,
            subscriptions: [StatisticsSubscription(name: "Claude Max", count: 1, monthlyEUR: 180)],
            usdEurRate: 0.92, now: Self.date("2026-11-05")
        )
    }

    func testMarkdownHidesProjectNamesByDefault() {
        let data = shareData()
        let markdown = StatisticsShareExport.markdown(
            data: data, options: StatisticsShareOptions(), periodPhrase: "this week", locale: en
        )
        XCTAssertFalse(StatisticsShareOptions().projectNames)
        XCTAssertFalse(markdown.contains("kunde-geheim"))
        XCTAssertFalse(markdown.contains("whisperm8,"))
        XCTAssertTrue(markdown.contains("**WhisperM8 · this week**"))
        XCTAssertTrue(markdown.contains("| Active time | 5 h |"))
        XCTAssertTrue(markdown.contains("Opus"))
    }

    func testMarkdownShowsProjectsOnlyWhenEnabled() {
        var options = StatisticsShareOptions()
        options.projectNames = true
        let markdown = StatisticsShareExport.markdown(data: shareData(), options: options, periodPhrase: "this week", locale: en)
        XCTAssertTrue(markdown.contains("kunde-geheim"))
    }

    func testMarkdownRespectsEuroAndTimeSwitches() {
        var options = StatisticsShareOptions()
        options.euros = false
        options.times = false
        let markdown = StatisticsShareExport.markdown(data: shareData(), options: options, periodPhrase: "this week", locale: en)
        XCTAssertFalse(markdown.contains("€"))
        XCTAssertFalse(markdown.contains("Active time"))
        XCTAssertTrue(markdown.contains("New chats"))
    }

    // MARK: - Achse und Balken

    func testChartScaleUsesRoundSteps() {
        let hours = StatisticsChartScale.ticks(maxValue: 7.1, steps: [1, 2, 3, 4, 5, 10])
        XCTAssertEqual(hours.step, 2)
        XCTAssertEqual(hours.top, 8)
        let empty = StatisticsChartScale.ticks(maxValue: 0, steps: [15, 30, 60])
        XCTAssertEqual(empty.top, 15)
    }

    func testShareBarWidthsKeepMinimumAndFit() {
        let widths = StatisticsShareBar.widths(for: [0.97, 0.01, 0.02], total: 300, spacing: 2)
        XCTAssertEqual(widths.count, 3)
        XCTAssertGreaterThanOrEqual(widths[1], 6)
        XCTAssertEqual(widths.reduce(0, +), 296, accuracy: 0.5)
    }

    func testAccountDisplayNames() {
        XCTAssertEqual(StatisticsAccountName.display("codex"), "Codex (CLI)")
        XCTAssertEqual(StatisticsAccountName.display("chatgpt:main"), "ChatGPT")
        XCTAssertEqual(StatisticsAccountName.display("chatgpt:ai2"), "ChatGPT (ai2)")
        XCTAssertEqual(StatisticsAccountName.display("RankM8"), "RankM8")
    }

    private static func date(_ key: String) -> Date {
        StatisticsTime.date(fromDayKey: key)!.addingTimeInterval(15 * 3600)
    }
}
