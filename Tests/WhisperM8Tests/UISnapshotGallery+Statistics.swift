import AppKit
import SwiftUI
@testable import WhisperM8

/// Fixtures der Statistik-Seite. Beispielwerte wie im Entwurf
/// (`docs/design/statistik.html`): Woche vom 2. bis 5. November 2026, Opus 5.5
/// mit rund 25.800 Antworten.
extension UISnapshotGallery {
    /// Donnerstag, 5. November 2026, 15:00 Uhr (lokal).
    static var statisticsNow: Date {
        StatisticsTime.date(fromDayKey: "2026-11-05")!.addingTimeInterval(15 * 3600)
    }

    static func statisticsDemoDatabase(backfillRunning: Bool = false) -> StatsDatabase {
        var db = StatsDatabase()
        let days = ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"]
        let active: [Double] = [402, 371, 428, 334]
        let agent: [Double] = [690, 655, 742, 610]
        // Wochenwerte je Modell, gleichmäßig auf die vier Tage verteilt.
        let models: [(String, String, TokenUsage)] = [
            ("claude-opus-5-5", "main", TokenUsage(messages: 25_822, input: 120_000, output: 21_400_000, cacheWrite5m: 228_200_000, cacheRead: 7_640_000_000)),
            ("claude-sonnet-5-5", "RankM8", TokenUsage(messages: 141, output: 240_000, cacheWrite5m: 700_000, cacheRead: 28_100_000)),
            ("gpt-6.1-sol", "main", TokenUsage(messages: 1_201, input: 5_470_000, output: 380_000, cacheRead: 161_500_000)),
            ("gpt-5.6-sol", "codex", TokenUsage(messages: 82, input: 400_000, output: 50_000, cacheRead: 2_500_000)),
        ]
        func quarter(_ usage: TokenUsage) -> TokenUsage {
            TokenUsage(messages: usage.messages / 4, input: usage.input / 4, output: usage.output / 4,
                       cacheWrite5m: usage.cacheWrite5m / 4, cacheWrite1h: usage.cacheWrite1h / 4, cacheRead: usage.cacheRead / 4)
        }
        let projects: [(String, Double, Int)] = [
            ("whisperm8", 0.46, 8), ("listm8", 0.24, 4), ("outreach", 0.13, 2),
            ("wolanin-aesthetics", 0.09, 1), ("docs", 0.05, 1), ("scripts", 0.02, 0), ("misc", 0.01, 1),
        ]
        for (index, key) in days.enumerated() {
            db.updateDay(key) { day in
                day.activeSeconds = active[index] * 60
                day.foregroundSeconds = active[index] * 60 * 1.18
                day.agentWorkingSeconds = agent[index] * 60
                day.concurrencySeconds = agent[index] * 60 * 2.4
                day.peakConcurrent = index == 2 ? 7 : 5
                for hour in 0..<24 {
                    let working = hour >= 9 && hour <= 19 && hour != 13
                    let isToday = index == 3
                    if working && (!isToday || hour <= 15) {
                        day.addHourly(active: Double(28 + (hour * 7) % 30) * 60, hour: hour)
                        day.addHourly(agent: Double(32 + (hour * 11) % 28) * 60, hour: hour)
                    }
                }
                day.chatsStarted = ["claude": 11, "gpt": 2, "codex": 1, "background": 2]
                day.subagentsStarted = 90
                day.dictations = 38
                day.dictationAudioSeconds = 38 * 36
                day.dictationWords = 38 * 74
                day.dictationModes = ["Agent Chat": 20, "Rewrite": 8, "Email": 6, "Slack": 4]
                for (model, account, usage) in models {
                    day.addTokens(quarter(usage), model: model, account: account, project: nil)
                }
                for (name, share, chats) in projects {
                    day.projectTokens[name] = ["claude-opus-5-5": TokenUsage(
                        messages: Int(6_000 * share),
                        output: Int(5_300_000 * share),
                        cacheRead: Int(1_900_000_000 * share)
                    )]
                    day.projectChats[name] = chats
                }
                if index < 3 {
                    day.commits = ["whisperm8": 9, "listm8": 4, "outreach": 1]
                    day.pullRequests = ["whisperm8": 1]
                }
            }
        }
        // Vorwoche für den Vergleich.
        for key in ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"] {
            db.updateDay(key) { $0.activeSeconds = 380 * 60 }
        }
        // Limits: höchste Wochen-Auslastung der letzten acht Wochen.
        func limit(_ provider: String, plan: String, five: Double?, fiveReset: TimeInterval?, week: Double,
                   weekReset: TimeInterval, peaks: [Double]) -> LimitHistory {
            var history = LimitHistory(provider: provider, plan: plan)
            for (offset, peak) in peaks.enumerated() {
                let date = statisticsNow.addingTimeInterval(-Double(7 - offset) * 7 * 86_400)
                history.weeklyPeaks[StatisticsTime.weekKey(for: date)] = peak
            }
            history.current = LimitSnapshot(
                fiveHourPercent: five,
                fiveHourResetsAt: fiveReset.map { statisticsNow.addingTimeInterval($0) },
                weekPercent: week,
                weekResetsAt: statisticsNow.addingTimeInterval(weekReset),
                capturedAt: statisticsNow
            )
            return history
        }
        db.limits = [
            "main": limit("claude", plan: "Claude Max", five: 34, fiveReset: 7_800, week: 71, weekReset: 3.75 * 86_400,
                          peaks: [62, 88, 100, 94, 70, 100, 81, 71]),
            "RankM8": limit("claude", plan: "Claude Max", five: 58, fiveReset: 2_460, week: 92, weekReset: 0.95 * 86_400,
                            peaks: [40, 77, 100, 100, 98, 100, 100, 92]),
            "PowerUser": limit("claude", plan: "Claude Max", five: 4, fiveReset: 17_520, week: 37, weekReset: 3.3 * 86_400,
                               peaks: [12, 30, 55, 41, 28, 60, 47, 37]),
            "chatgpt:main": limit("chatgpt", plan: "Pro", five: nil, fiveReset: nil, week: 11, weekReset: 5.7 * 86_400,
                                  peaks: [8, 14, 22, 19, 9, 15, 13, 11]),
        ]
        db.lastScan = StatsScanInfo(finishedAt: statisticsNow.addingTimeInterval(-180), filesRead: 12, duration: 0.4)
        if backfillRunning {
            db.backfill = StatsBackfillState(totalFiles: 9_120, processedFiles: 3_460, startedAt: statisticsNow.addingTimeInterval(-600))
        } else {
            db.backfill = StatsBackfillState(totalFiles: 9_120, processedFiles: 9_120,
                                             startedAt: statisticsNow.addingTimeInterval(-86_400),
                                             finishedAt: statisticsNow.addingTimeInterval(-80_000))
        }
        return db
    }

    static func statisticsDependencies(_ db: StatsDatabase) -> StatisticsSettingsDependencies {
        StatisticsSettingsDependencies(
            snapshot: { db },
            requestScan: {},
            rescanAll: {},
            setBackfillPaused: { _ in },
            notifyEnabledChanged: { _ in },
            reset: {},
            directorySize: { 1_400_000 },
            loadSubscriptions: { StatisticsSettings.defaultSubscriptions },
            saveSubscriptions: { _ in },
            usdEurRate: { 0.92 },
            now: { statisticsNow },
            copyImage: { _ in },
            copyText: { _ in }
        )
    }

    static func statisticsData(_ db: StatsDatabase, period: StatisticsPeriod) -> StatisticsPageData {
        StatisticsPageData.build(
            database: db, period: period, accountFilter: nil,
            subscriptions: StatisticsSettings.defaultSubscriptions,
            usdEurRate: 0.92, now: statisticsNow
        )
    }

    @MainActor
    static func statisticsFixtures() -> [Fixture] {
        let width: CGFloat = 760
        func page(_ name: String, height: CGFloat, db: StatsDatabase, period: StatisticsPeriod = .week,
                  enabled: Bool = true) -> Fixture {
            Fixture(
                name: name,
                size: CGSize(width: width, height: height),
                storage: [
                    StatisticsPreferenceKeys.enabled: enabled,
                    StatisticsPreferenceKeys.period: period.rawValue,
                ]
            ) {
                AnyView(StatisticsSettingsPage(
                    dependencies: statisticsDependencies(db),
                    initialData: statisticsData(db, period: period),
                    initialFolderBytes: 1_400_000
                ))
            }
        }
        let demo = statisticsDemoDatabase()
        return [
            page("statistik-woche", height: 2_800, db: demo),
            page("statistik-heute", height: 1_150, db: demo, period: .day),
            page("statistik-einlesen", height: 1_000, db: statisticsDemoDatabase(backfillRunning: true)),
            page("statistik-leer", height: 640, db: StatsDatabase()),
            page("statistik-aus", height: 900, db: demo, enabled: false),
            Fixture(name: "statistik-teilen", size: CGSize(width: 620, height: 380)) {
                AnyView(StatisticsShareSheet(
                    data: statisticsData(demo, period: .week),
                    dependencies: statisticsDependencies(demo),
                    locale: .current,
                    close: {}
                ))
            },
        ]
    }
}
