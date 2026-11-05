import Foundation

/// Zeitraum der Statistik-Seite.
enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case all

    var id: String { rawValue }
}

/// Fertig gerechnete Werte für die Statistik-Seite. Rein und ohne I/O: aus
/// `StatsDatabase` + Zeitraum + Einstellungen. Die Seite rechnet nichts selbst.
struct StatisticsReport: Equatable, Sendable {
    /// Ein Balken im Zeit-Diagramm (Stunde, Tag oder Monat).
    struct Bucket: Equatable, Sendable, Identifiable {
        var id: Int
        /// Achsenbeschriftung, leer = keine Beschriftung an diesem Balken.
        var label: String
        /// Ausführlich für den Tooltip („Montag, 2. Nov.“).
        var detail: String
        var activeSeconds: Double
        var agentSeconds: Double
        /// Liegt in der Zukunft: „noch keine Daten“ statt 0.
        var isFuture: Bool
    }

    struct ModelRow: Equatable, Sendable, Identifiable {
        var id: String { model }
        var model: String
        var displayName: String
        var isOpenAI: Bool
        var usage: TokenUsage
        /// `nil`: Modell ohne bekannten Preis.
        var usd: Double?
        var eur: Double?
    }

    struct ProjectRow: Equatable, Sendable, Identifiable {
        var id: String { name }
        var name: String
        var eur: Double
        var tokens: Int
        var chats: Int
    }

    struct LimitRow: Equatable, Sendable, Identifiable {
        var id: String { account }
        var account: String
        var provider: String
        var plan: String?
        var current: LimitSnapshot?
        /// Älteste zuerst, genau 8 Einträge (`nil` = keine Daten für die Woche).
        var weeklyPeaks: [Double?]
        var weeksAtLimit: Int
    }

    struct GitRow: Equatable, Sendable, Identifiable {
        var id: String { project }
        var project: String
        var commits: Int
        var pullRequests: Int
    }

    var period: StatisticsPeriod
    var rangeStart: Date
    var rangeEnd: Date
    /// Tage im Zeitraum bis heute (für Abo-Anteil und Durchschnitte).
    var elapsedDays: Int
    /// Tage mit aktiver Zeit > 0.
    var activeDays: Int

    // Zeit
    var activeSeconds: Double
    var foregroundSeconds: Double
    var agentSeconds: Double
    var averageConcurrent: Double
    var peakConcurrent: Int
    var previousActiveSeconds: Double?
    var buckets: [Bucket]

    // Token & Geld
    var accounts: [String]
    var models: [ModelRow]
    var totalUSD: Double
    var totalEUR: Double
    var usdEurRate: Double
    var projects: [ProjectRow]
    var subscriptionMonthlyEUR: Double
    var subscriptionCostEUR: Double
    /// Gegenwert ÷ Abo-Kosten im Zeitraum. `nil` ohne Abos.
    var leverage: Double?

    // Chats
    var chatsStarted: Int
    var chatsByKind: [StatsChatKind: Int]
    var subagents: Int

    // Diktate
    var dictations: Int
    var dictationAudioSeconds: Double
    var dictationWords: Int
    /// Häufigste Modi, absteigend.
    var dictationModes: [(name: String, count: Int)]

    // Git
    var commits: Int
    var pullRequests: Int
    var git: [GitRow]

    // Limits (unabhängig vom Zeitraum)
    var limits: [LimitRow]

    var totalTokens: Int { models.reduce(0) { $0 + $1.usage.totalTokens } }

    static func == (lhs: StatisticsReport, rhs: StatisticsReport) -> Bool {
        lhs.period == rhs.period && lhs.rangeStart == rhs.rangeStart && lhs.rangeEnd == rhs.rangeEnd
            && lhs.activeSeconds == rhs.activeSeconds && lhs.agentSeconds == rhs.agentSeconds
            && lhs.buckets == rhs.buckets && lhs.models == rhs.models && lhs.projects == rhs.projects
            && lhs.chatsStarted == rhs.chatsStarted && lhs.dictations == rhs.dictations
            && lhs.limits == rhs.limits && lhs.git == rhs.git && lhs.leverage == rhs.leverage
            && lhs.dictationModes.map(\.name) == rhs.dictationModes.map(\.name)
            && lhs.dictationModes.map(\.count) == rhs.dictationModes.map(\.count)
    }
}

extension StatisticsReport {
    /// Rechnet den Bericht. `accountFilter`: nur dieses Konto (`nil` = alle).
    static func build(
        database: StatsDatabase,
        period: StatisticsPeriod,
        accountFilter: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        subscriptions: [StatisticsSubscription] = [],
        usdEurRate: Double = StatisticsSettings.fallbackUsdEurRate,
        locale: Locale = .current
    ) -> StatisticsReport {
        let range = dateRange(for: period, database: database, now: now, calendar: calendar)
        let dayKeys = keys(from: range.start, through: min(range.end, now), calendar: calendar)
        let days = dayKeys.compactMap { database.days[$0] }

        // Zeit
        let active = days.reduce(0) { $0 + $1.activeSeconds }
        let foreground = days.reduce(0) { $0 + $1.foregroundSeconds }
        let agent = days.reduce(0) { $0 + $1.agentWorkingSeconds }
        let concurrency = days.reduce(0) { $0 + $1.concurrencySeconds }
        let peak = days.map(\.peakConcurrent).max() ?? 0
        let elapsedDays = max(1, dayKeys.count)
        let activeDays = days.filter { $0.activeSeconds > 0 }.count

        var previousActive: Double?
        if period != .all, let prev = previousRange(for: period, start: range.start, calendar: calendar) {
            let prevKeys = keys(from: prev.start, through: prev.end, calendar: calendar)
            let value = prevKeys.compactMap { database.days[$0]?.activeSeconds }.reduce(0, +)
            previousActive = prevKeys.contains { database.days[$0] != nil } ? value : nil
        }

        // Token
        var perModel: [String: TokenUsage] = [:]
        var accountSet = Set<String>()
        var perProject: [String: (eur: Double, tokens: Int)] = [:]
        var chatsPerProject: [String: Int] = [:]
        for day in days {
            for (model, accounts) in day.tokens {
                for (account, usage) in accounts {
                    accountSet.insert(account)
                    if let accountFilter, account != accountFilter { continue }
                    perModel[model, default: TokenUsage()].add(usage)
                }
            }
            if accountFilter == nil {
                for (project, models) in day.projectTokens {
                    for (model, usage) in models {
                        let eur = (ModelPricing.costUSD(model: model, usage: usage) ?? 0) * usdEurRate
                        perProject[project, default: (0, 0)].eur += eur
                        perProject[project, default: (0, 0)].tokens += usage.totalTokens
                    }
                }
            }
            for (project, count) in day.projectChats {
                chatsPerProject[project, default: 0] += count
            }
        }
        let models = perModel.map { model, usage -> ModelRow in
            let usd = ModelPricing.costUSD(model: model, usage: usage)
            return ModelRow(
                model: model,
                displayName: ModelPricing.displayName(for: model),
                isOpenAI: ModelPricing.isOpenAIModel(model),
                usage: usage,
                usd: usd,
                eur: usd.map { $0 * usdEurRate }
            )
        }
        .filter { !$0.usage.isEmpty }
        .sorted { ($0.usd ?? -1, $0.usage.totalTokens) > ($1.usd ?? -1, $1.usage.totalTokens) }
        let totalUSD = models.compactMap(\.usd).reduce(0, +)
        let totalEUR = totalUSD * usdEurRate

        let projectNames = Set(perProject.keys).union(chatsPerProject.keys)
        let projects = projectNames.map { name in
            ProjectRow(
                name: name,
                eur: perProject[name]?.eur ?? 0,
                tokens: perProject[name]?.tokens ?? 0,
                chats: chatsPerProject[name] ?? 0
            )
        }
        .sorted { ($0.eur, $0.chats) > ($1.eur, $1.chats) }

        // Geld
        let monthly = subscriptions.reduce(0) { $0 + $1.monthlyTotal }
        let subscriptionCost = monthly * 12 / 365 * Double(elapsedDays)
        let leverage = subscriptionCost > 0 ? totalEUR / subscriptionCost : nil

        // Chats
        var byKind: [StatsChatKind: Int] = [:]
        for day in days {
            for (raw, count) in day.chatsStarted {
                guard let kind = StatsChatKind(rawValue: raw) else { continue }
                byKind[kind, default: 0] += count
            }
        }

        // Diktate
        var modes: [String: Int] = [:]
        for day in days { for (mode, count) in day.dictationModes { modes[mode, default: 0] += count } }

        // Git
        var commitsByProject: [String: Int] = [:]
        var prsByProject: [String: Int] = [:]
        for day in days {
            for (p, c) in day.commits { commitsByProject[p, default: 0] += c }
            for (p, c) in day.pullRequests { prsByProject[p, default: 0] += c }
        }
        let git = Set(commitsByProject.keys).union(prsByProject.keys).map {
            GitRow(project: $0, commits: commitsByProject[$0] ?? 0, pullRequests: prsByProject[$0] ?? 0)
        }
        .sorted { ($0.commits + $0.pullRequests, $1.project) > ($1.commits + $1.pullRequests, $0.project) }

        return StatisticsReport(
            period: period,
            rangeStart: range.start,
            rangeEnd: range.end,
            elapsedDays: elapsedDays,
            activeDays: activeDays,
            activeSeconds: active,
            foregroundSeconds: foreground,
            agentSeconds: agent,
            averageConcurrent: agent > 0 ? concurrency / agent : 0,
            peakConcurrent: peak,
            previousActiveSeconds: previousActive,
            buckets: buckets(for: period, database: database, range: range, now: now, calendar: calendar, locale: locale),
            accounts: accountSet.sorted { lhs, rhs in
                if lhs == "main" { return true }
                if rhs == "main" { return false }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            },
            models: models,
            totalUSD: totalUSD,
            totalEUR: totalEUR,
            usdEurRate: usdEurRate,
            projects: projects,
            subscriptionMonthlyEUR: monthly,
            subscriptionCostEUR: subscriptionCost,
            leverage: leverage,
            chatsStarted: byKind.values.reduce(0, +),
            chatsByKind: byKind,
            subagents: days.reduce(0) { $0 + $1.subagentsStarted },
            dictations: days.reduce(0) { $0 + $1.dictations },
            dictationAudioSeconds: days.reduce(0) { $0 + $1.dictationAudioSeconds },
            dictationWords: days.reduce(0) { $0 + $1.dictationWords },
            dictationModes: modes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { (name: $0.key, count: $0.value) },
            commits: commitsByProject.values.reduce(0, +),
            pullRequests: prsByProject.values.reduce(0, +),
            git: git,
            limits: limitRows(database: database, now: now, calendar: calendar)
        )
    }

    // MARK: - Zeiträume

    static func dateRange(
        for period: StatisticsPeriod,
        database: StatsDatabase,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .day:
            return (today, calendar.date(byAdding: .day, value: 1, to: today) ?? now)
        case .week:
            let start = StatisticsTime.startOfWeek(for: now, calendar: calendar)
            return (start, calendar.date(byAdding: .day, value: 7, to: start) ?? now)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            return (interval?.start ?? today, interval?.end ?? now)
        case .all:
            let first = database.days.keys.sorted().first.flatMap { StatisticsTime.date(fromDayKey: $0, calendar: calendar) }
            let start = calendar.dateInterval(of: .month, for: first ?? now)?.start ?? today
            return (start, calendar.date(byAdding: .day, value: 1, to: today) ?? now)
        }
    }

    static func previousRange(for period: StatisticsPeriod, start: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .all: return nil
        }
        guard let prevStart = calendar.date(byAdding: component, value: -1, to: start),
              let prevEnd = calendar.date(byAdding: .second, value: -1, to: start) else { return nil }
        return (prevStart, prevEnd)
    }

    /// Alle Tagesschlüssel von `start` bis einschließlich des Tags von `end`.
    static func keys(from start: Date, through end: Date, calendar: Calendar) -> [String] {
        var result: [String] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var guardCount = 0
        while cursor <= last, guardCount < 3700 {
            result.append(StatisticsTime.dayKey(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return result
    }

    // MARK: - Balken

    static func buckets(
        for period: StatisticsPeriod,
        database: StatsDatabase,
        range: (start: Date, end: Date),
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [Bucket] {
        switch period {
        case .day:
            let key = StatisticsTime.dayKey(for: now, calendar: calendar)
            let day = database.days[key]
            let currentHour = calendar.component(.hour, from: now)
            return (0..<24).map { hour in
                Bucket(
                    id: hour,
                    label: hour % 6 == 0 ? "\(hour)" : "",
                    detail: "\(hour)–\(hour + 1)",
                    activeSeconds: day?.hourlyActiveSeconds[safe: hour] ?? 0,
                    agentSeconds: day?.hourlyAgentSeconds[safe: hour] ?? 0,
                    isFuture: hour > currentHour
                )
            }
        case .week, .month:
            let keys = keys(from: range.start, through: calendar.date(byAdding: .second, value: -1, to: range.end) ?? range.end, calendar: calendar)
            let todayKey = StatisticsTime.dayKey(for: now, calendar: calendar)
            let weekdayFormatter = DateFormatter()
            weekdayFormatter.locale = locale
            weekdayFormatter.setLocalizedDateFormatFromTemplate("EEEEEE")
            let detailFormatter = DateFormatter()
            detailFormatter.locale = locale
            detailFormatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
            return keys.enumerated().map { index, key in
                let date = StatisticsTime.date(fromDayKey: key, calendar: calendar) ?? now
                let dayNumber = calendar.component(.day, from: date)
                let label: String
                if period == .week {
                    label = weekdayFormatter.string(from: date)
                } else {
                    label = dayNumber == 1 || dayNumber % 5 == 0 ? "\(dayNumber)" : ""
                }
                let day = database.days[key]
                return Bucket(
                    id: index,
                    label: label,
                    detail: detailFormatter.string(from: date),
                    activeSeconds: day?.activeSeconds ?? 0,
                    agentSeconds: day?.agentWorkingSeconds ?? 0,
                    isFuture: key > todayKey
                )
            }
        case .all:
            let monthFormatter = DateFormatter()
            monthFormatter.locale = locale
            monthFormatter.setLocalizedDateFormatFromTemplate("MMM")
            let detailFormatter = DateFormatter()
            detailFormatter.locale = locale
            detailFormatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            var result: [Bucket] = []
            var cursor = range.start
            var index = 0
            while cursor <= now, index < 240 {
                guard let interval = calendar.dateInterval(of: .month, for: cursor) else { break }
                let monthKeys = keys(from: interval.start, through: min(interval.end.addingTimeInterval(-1), now), calendar: calendar)
                let monthDays = monthKeys.compactMap { database.days[$0] }
                result.append(Bucket(
                    id: index,
                    label: monthFormatter.string(from: interval.start),
                    detail: detailFormatter.string(from: interval.start),
                    activeSeconds: monthDays.reduce(0) { $0 + $1.activeSeconds },
                    agentSeconds: monthDays.reduce(0) { $0 + $1.agentWorkingSeconds },
                    isFuture: false
                ))
                cursor = interval.end
                index += 1
            }
            return result
        }
    }

    // MARK: - Limits

    static func limitRows(database: StatsDatabase, now: Date, calendar: Calendar) -> [LimitRow] {
        let thisWeek = StatisticsTime.startOfWeek(for: now, calendar: calendar)
        let weekKeys: [String] = (0..<8).reversed().compactMap { back in
            calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek).map {
                StatisticsTime.dayKey(for: $0, calendar: calendar)
            }
        }
        return database.limits.map { account, history in
            let peaks = weekKeys.map { history.weeklyPeaks[$0] }
            return LimitRow(
                account: account,
                provider: history.provider,
                plan: history.plan,
                current: history.current,
                weeklyPeaks: peaks,
                weeksAtLimit: peaks.compactMap { $0 }.filter { $0 >= 99.5 }.count
            )
        }
        .sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider == "claude" }
            if lhs.account == "main" { return true }
            if rhs.account == "main" { return false }
            return lhs.account.localizedCaseInsensitiveCompare(rhs.account) == .orderedAscending
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
