import Foundation

/// Woher die Token eines Modells stammen — für die Unterzeile der Modelltabelle.
enum StatisticsModelSource: Sendable, Equatable {
    case claudeCode
    /// GPT über den Proxy in Claude Code (ChatGPT-Abo).
    case proxy
    /// GPT in der Codex-CLI.
    case codex
    /// Beides im selben Zeitraum.
    case codexAndProxy
}

/// Alles, was die Statistik-Seite zeigt, fertig gerechnet. Entsteht im
/// Hintergrund (`Task.detached`) aus einem Schnappschuss des Stores; die
/// Oberfläche liest nur noch Felder.
struct StatisticsPageData: Sendable, Equatable {
    var report: StatisticsReport
    /// Palettenreihenfolge der Modelle über die gesamte Historie.
    var modelOrder: [String]
    var modelSources: [String: StatisticsModelSource]
    /// Summe aller Modellzeilen (Summenzeile der Tabelle).
    var tokenTotals: TokenUsage
    /// Gibt es überhaupt gezählte Tage?
    var hasData: Bool
    var backfill: StatsBackfillState
    var lastScan: StatsScanInfo?
    var now: Date

    static func build(
        database: StatsDatabase,
        period: StatisticsPeriod,
        accountFilter: String?,
        subscriptions: [StatisticsSubscription],
        usdEurRate: Double,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> StatisticsPageData {
        let report = StatisticsReport.build(
            database: database,
            period: period,
            accountFilter: accountFilter,
            now: now,
            calendar: calendar,
            subscriptions: subscriptions,
            usdEurRate: usdEurRate,
            locale: locale
        )
        var totals = TokenUsage()
        for row in report.models { totals.add(row.usage) }
        return StatisticsPageData(
            report: report,
            modelOrder: StatisticsPalette.modelOrder(database: database),
            modelSources: modelSources(database: database, report: report, accountFilter: accountFilter, now: now, calendar: calendar),
            tokenTotals: totals,
            hasData: !database.days.isEmpty,
            backfill: database.backfill,
            lastScan: database.lastScan,
            now: now
        )
    }

    /// Quelle je Modell im Zeitraum: OpenAI-Modelle nur im Konto `codex` kommen
    /// aus der Codex-CLI, sonst über den Proxy in Claude Code.
    static func modelSources(
        database: StatsDatabase,
        report: StatisticsReport,
        accountFilter: String?,
        now: Date,
        calendar: Calendar
    ) -> [String: StatisticsModelSource] {
        let keys = StatisticsReport.keys(from: report.rangeStart, through: min(report.rangeEnd, now), calendar: calendar)
        var accountsByModel: [String: Set<String>] = [:]
        for key in keys {
            guard let day = database.days[key] else { continue }
            for (model, accounts) in day.tokens {
                for (account, usage) in accounts where !usage.isEmpty {
                    if let accountFilter, account != accountFilter { continue }
                    accountsByModel[model, default: []].insert(account)
                }
            }
        }
        var result: [String: StatisticsModelSource] = [:]
        for row in report.models {
            guard row.isOpenAI else {
                result[row.model] = .claudeCode
                continue
            }
            let accounts = accountsByModel[row.model] ?? []
            if accounts == ["codex"] {
                result[row.model] = .codex
            } else if accounts.contains("codex") {
                result[row.model] = .codexAndProxy
            } else {
                result[row.model] = .proxy
            }
        }
        return result
    }

    /// Anteil des teuersten Modells am Gegenwert (0…1), `nil` ohne Gegenwert.
    var topModelShare: (name: String, fraction: Double)? {
        guard report.totalEUR > 0, let top = report.models.first, let eur = top.eur else { return nil }
        return (top.displayName, eur / report.totalEUR)
    }
}

// MARK: - Zeitraum als Text

enum StatisticsPeriodText {
    /// Kurzer Zeitraum-Text für Hebel und Teilen-Karte: „this week“, „in November“, „since May 2026“.
    static func phrase(for report: StatisticsReport, locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch report.period {
        case .day:
            return String(localized: "today")
        case .week:
            return String(localized: "this week")
        case .month:
            let month = report.rangeStart.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide))
            return String(localized: "in \(month)")
        case .all:
            let start = report.rangeStart.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide).year())
            return String(localized: "since \(start)")
        }
    }
}

// MARK: - Teilen

/// Was beim Teilen sichtbar sein darf. Projektnamen sind standardmäßig aus,
/// damit nichts über Kunden nach außen geht.
struct StatisticsShareOptions: Equatable, Sendable {
    var times = true
    var tokens = true
    var euros = true
    var projectNames = false
}

enum StatisticsShareExport {
    struct Item: Equatable, Sendable {
        let label: String
        let value: String
    }

    /// Kacheln der Teilen-Karte und Zeilen des Markdown-Texts, in Reihenfolge.
    static func items(data: StatisticsPageData, options: StatisticsShareOptions, locale: Locale = .current) -> [Item] {
        let report = data.report
        var items: [Item] = []
        if options.times {
            items.append(Item(label: String(localized: "Active time"), value: StatisticsFormat.hoursShort(report.activeSeconds, locale: locale)))
            items.append(Item(label: String(localized: "Agent time"), value: StatisticsFormat.hoursShort(report.agentSeconds, locale: locale)))
        }
        if options.tokens {
            items.append(Item(label: String(localized: "Tokens"), value: StatisticsFormat.tokens(report.totalTokens, locale: locale)))
            items.append(Item(label: String(localized: "Top model"), value: report.models.first?.displayName ?? "–"))
        }
        if options.euros {
            items.append(Item(label: String(localized: "API value"), value: StatisticsFormat.euro(report.totalEUR, locale: locale)))
            items.append(Item(
                label: String(localized: "Leverage"),
                value: report.leverage.map { StatisticsFormat.multiplier($0, locale: locale) } ?? "–"
            ))
        }
        items.append(Item(label: String(localized: "New chats"), value: StatisticsFormat.count(report.chatsStarted, locale: locale)))
        items.append(Item(label: String(localized: "Dictations"), value: StatisticsFormat.count(report.dictations, locale: locale)))
        return items
    }

    /// Die größten Projekte nach Gegenwert — `nil`, wenn Projektnamen aus sind.
    static func topProjects(data: StatisticsPageData, options: StatisticsShareOptions, limit: Int = 3) -> [String]? {
        guard options.projectNames else { return nil }
        return Array(data.report.projects.prefix(limit).map(\.name))
    }

    /// Markdown für Slack oder Mail.
    static func markdown(
        data: StatisticsPageData,
        options: StatisticsShareOptions,
        periodPhrase: String,
        locale: Locale = .current
    ) -> String {
        var lines: [String] = ["**WhisperM8 · \(periodPhrase)**", ""]
        lines.append("| | |")
        lines.append("|---|---:|")
        for item in items(data: data, options: options, locale: locale) {
            lines.append("| \(item.label) | \(item.value) |")
        }
        if options.tokens, !data.report.models.isEmpty {
            lines.append("")
            lines.append("**" + String(localized: "Models") + "**")
            for row in data.report.models.prefix(5) {
                var line = "- \(row.displayName): " + StatisticsFormat.tokens(row.usage.totalTokens, locale: locale)
                    + " " + String(localized: "tokens")
                if options.euros, let eur = row.eur {
                    line += " · " + StatisticsFormat.euro(eur, locale: locale)
                }
                lines.append(line)
            }
        }
        if let projects = topProjects(data: data, options: options), !projects.isEmpty {
            lines.append("")
            lines.append(String(localized: "Top projects: \(projects.joined(separator: ", "))"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
