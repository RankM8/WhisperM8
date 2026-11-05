import Foundation

// Datenmodell der Statistik-Seite. Alles hier ist reines Wertmodell ohne I/O:
// Tageswerte (`StatsDay`), Limit-Verlauf (`LimitHistory`) und die Gesamtdatei
// (`StatsDatabase`). Gespeichert wird es vom `StatisticsStore`.
//
// Decoding ist tolerant: fehlende Felder fallen auf ihre Standardwerte zurück,
// damit neue Felder alte Dateien nicht unlesbar machen.

/// Token-Verbrauch eines Modells in einem Konto oder Projekt.
///
/// `input` ist die NICHT gecachte Eingabe. Codex meldet `input_tokens`
/// inklusive Cache — der Codex-Leser zieht `cached_input_tokens` vorher ab.
struct TokenUsage: Codable, Equatable, Sendable {
    var messages: Int = 0
    var input: Int = 0
    var output: Int = 0
    var cacheWrite5m: Int = 0
    var cacheWrite1h: Int = 0
    var cacheRead: Int = 0

    init(
        messages: Int = 0,
        input: Int = 0,
        output: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0
    ) {
        self.messages = messages
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    var totalTokens: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var isEmpty: Bool { messages == 0 && totalTokens == 0 }

    mutating func add(_ other: TokenUsage) {
        messages += other.messages
        input += other.input
        output += other.output
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        cacheRead += other.cacheRead
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        var sum = lhs
        sum.add(rhs)
        return sum
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheWrite5m = try c.decodeIfPresent(Int.self, forKey: .cacheWrite5m) ?? 0
        cacheWrite1h = try c.decodeIfPresent(Int.self, forKey: .cacheWrite1h) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
    }
}

/// Wie ein Chat gestartet wurde — Grundlage für „Womit gearbeitet wurde“.
enum StatsChatKind: String, Codable, CaseIterable, Sendable {
    case claude
    case gpt
    case codex
    case background
}

/// Alle Werte eines Kalendertags (lokale Zeitzone).
struct StatsDay: Codable, Equatable, Sendable {
    /// Fenster vorne UND Eingabe in den letzten `StatisticsTime.idleThreshold` Sekunden.
    var activeSeconds: Double = 0
    /// Ein WhisperM8-Fenster war vorne, egal ob mit Eingabe.
    var foregroundSeconds: Double = 0
    /// Zeit, in der mindestens ein Chat gearbeitet hat.
    var agentWorkingSeconds: Double = 0
    /// Integral der Anzahl arbeitender Chats über die Zeit (für den Durchschnitt:
    /// `concurrencySeconds / agentWorkingSeconds`).
    var concurrencySeconds: Double = 0
    var peakConcurrent: Int = 0
    /// 24 Werte, Index = Stunde. Leer, solange nichts gezählt wurde.
    var hourlyActiveSeconds: [Double] = []
    var hourlyAgentSeconds: [Double] = []

    /// Schlüssel: `StatsChatKind.rawValue`.
    var chatsStarted: [String: Int] = [:]
    /// Subagent-Läufe, aus den Claude-Protokollen gezählt.
    var subagentsStarted: Int = 0

    var dictations: Int = 0
    var dictationAudioSeconds: Double = 0
    var dictationWords: Int = 0
    /// Schlüssel: Anzeigename des Ausgabemodus.
    var dictationModes: [String: Int] = [:]

    /// Modell → Konto → Verbrauch. Konto: Claude-Profilname (`main`, `RankM8`, …),
    /// `codex` für die Codex-CLI.
    var tokens: [String: [String: TokenUsage]] = [:]
    /// Projektname → Modell → Verbrauch.
    var projectTokens: [String: [String: TokenUsage]] = [:]

    /// Projektname → neu gestartete Chats.
    var projectChats: [String: Int] = [:]

    /// Projektname → Anzahl.
    var commits: [String: Int] = [:]
    var pullRequests: [String: Int] = [:]

    init() {}

    var chatsStartedTotal: Int { chatsStarted.values.reduce(0, +) }

    mutating func addHourly(active seconds: Double, hour: Int) {
        guard (0..<24).contains(hour) else { return }
        if hourlyActiveSeconds.count != 24 { hourlyActiveSeconds = Array(repeating: 0, count: 24) }
        hourlyActiveSeconds[hour] += seconds
    }

    mutating func addHourly(agent seconds: Double, hour: Int) {
        guard (0..<24).contains(hour) else { return }
        if hourlyAgentSeconds.count != 24 { hourlyAgentSeconds = Array(repeating: 0, count: 24) }
        hourlyAgentSeconds[hour] += seconds
    }

    mutating func addTokens(_ usage: TokenUsage, model: String, account: String, project: String?) {
        tokens[model, default: [:]][account, default: TokenUsage()].add(usage)
        if let project, !project.isEmpty {
            projectTokens[project, default: [:]][model, default: TokenUsage()].add(usage)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
        foregroundSeconds = try c.decodeIfPresent(Double.self, forKey: .foregroundSeconds) ?? 0
        agentWorkingSeconds = try c.decodeIfPresent(Double.self, forKey: .agentWorkingSeconds) ?? 0
        concurrencySeconds = try c.decodeIfPresent(Double.self, forKey: .concurrencySeconds) ?? 0
        peakConcurrent = try c.decodeIfPresent(Int.self, forKey: .peakConcurrent) ?? 0
        hourlyActiveSeconds = try c.decodeIfPresent([Double].self, forKey: .hourlyActiveSeconds) ?? []
        hourlyAgentSeconds = try c.decodeIfPresent([Double].self, forKey: .hourlyAgentSeconds) ?? []
        chatsStarted = try c.decodeIfPresent([String: Int].self, forKey: .chatsStarted) ?? [:]
        subagentsStarted = try c.decodeIfPresent(Int.self, forKey: .subagentsStarted) ?? 0
        dictations = try c.decodeIfPresent(Int.self, forKey: .dictations) ?? 0
        dictationAudioSeconds = try c.decodeIfPresent(Double.self, forKey: .dictationAudioSeconds) ?? 0
        dictationWords = try c.decodeIfPresent(Int.self, forKey: .dictationWords) ?? 0
        dictationModes = try c.decodeIfPresent([String: Int].self, forKey: .dictationModes) ?? [:]
        tokens = try c.decodeIfPresent([String: [String: TokenUsage]].self, forKey: .tokens) ?? [:]
        projectTokens = try c.decodeIfPresent([String: [String: TokenUsage]].self, forKey: .projectTokens) ?? [:]
        projectChats = try c.decodeIfPresent([String: Int].self, forKey: .projectChats) ?? [:]
        commits = try c.decodeIfPresent([String: Int].self, forKey: .commits) ?? [:]
        pullRequests = try c.decodeIfPresent([String: Int].self, forKey: .pullRequests) ?? [:]
    }
}

/// Ein Limit-Stand eines Kontos.
struct LimitSnapshot: Codable, Equatable, Sendable {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var weekPercent: Double?
    var weekResetsAt: Date?
    var capturedAt: Date
}

/// Limit-Verlauf eines Kontos: letzter Stand plus höchste Wochen-Auslastung je
/// Woche (Schlüssel: Montag der Woche als Tagesschlüssel).
struct LimitHistory: Codable, Equatable, Sendable {
    /// `claude` oder `chatgpt` — bestimmt die Anzeige.
    var provider: String
    /// Optionaler Plan-Name („Max“, „Pro“).
    var plan: String?
    var current: LimitSnapshot?
    var weeklyPeaks: [String: Double] = [:]

    init(provider: String, plan: String? = nil, current: LimitSnapshot? = nil, weeklyPeaks: [String: Double] = [:]) {
        self.provider = provider
        self.plan = plan
        self.current = current
        self.weeklyPeaks = weeklyPeaks
    }

    /// Übernimmt einen neuen Stand. Ältere Stände als der gespeicherte werden
    /// ignoriert, der Wochen-Höchstwert wächst nur.
    mutating func record(_ snapshot: LimitSnapshot, calendar: Calendar = .current) {
        if let current, current.capturedAt > snapshot.capturedAt { return }
        current = snapshot
        if let week = snapshot.weekPercent {
            let key = StatisticsTime.weekKey(for: snapshot.capturedAt, calendar: calendar)
            weeklyPeaks[key] = max(weeklyPeaks[key] ?? 0, week)
        }
    }
}

/// Stand des einmaligen Einlesens der Protokoll-Historie.
struct StatsBackfillState: Codable, Equatable, Sendable {
    var totalFiles: Int = 0
    var processedFiles: Int = 0
    var startedAt: Date?
    var finishedAt: Date?
    var isPaused: Bool = false

    var isRunning: Bool { startedAt != nil && finishedAt == nil }
    var fraction: Double { totalFiles > 0 ? min(1, Double(processedFiles) / Double(totalFiles)) : 0 }
}

/// Zusammenfassung des letzten Protokoll-Laufs für die Zeile „Letzte Auswertung“.
struct StatsScanInfo: Codable, Equatable, Sendable {
    var finishedAt: Date
    var filesRead: Int
    var duration: TimeInterval
    /// Komprimierte Codex-Protokolle (`.jsonl.zst`), die mangels `zstd`
    /// übersprungen wurden. `nil` = keine (auch in älteren Dateien).
    var skippedCompressedFiles: Int?
}

/// Gesamtdatei `statistics/stats.json`.
struct StatsDatabase: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = StatsDatabase.currentVersion
    /// Schlüssel: Tagesschlüssel `yyyy-MM-dd` (lokal).
    var days: [String: StatsDay] = [:]
    /// Schlüssel: Kontoname (`main`, `RankM8`, `chatgpt:<profil>`, `codex`).
    var limits: [String: LimitHistory] = [:]
    var backfill = StatsBackfillState()
    var lastScan: StatsScanInfo?
    /// Wurden die Chat-Starts der Zeit vor der Statistik aus `createdAt` nachgetragen?
    var chatsBackfilled: Bool = false

    init() {}

    mutating func updateDay(_ key: String, _ body: (inout StatsDay) -> Void) {
        var day = days[key] ?? StatsDay()
        body(&day)
        days[key] = day
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? StatsDatabase.currentVersion
        days = try c.decodeIfPresent([String: StatsDay].self, forKey: .days) ?? [:]
        limits = try c.decodeIfPresent([String: LimitHistory].self, forKey: .limits) ?? [:]
        backfill = try c.decodeIfPresent(StatsBackfillState.self, forKey: .backfill) ?? StatsBackfillState()
        lastScan = try c.decodeIfPresent(StatsScanInfo.self, forKey: .lastScan)
        chatsBackfilled = try c.decodeIfPresent(Bool.self, forKey: .chatsBackfilled) ?? false
    }
}

// MARK: - Zeit-Helfer

enum StatisticsTime {
    /// Ab so vielen Sekunden ohne Eingabe gilt WhisperM8 als „vorne, aber nicht aktiv“.
    static let idleThreshold: TimeInterval = 5 * 60

    /// Tagesschlüssel `yyyy-MM-dd` in der Zeitzone des Kalenders. Ohne
    /// DateFormatter, damit er auf jeder Queue billig und threadsicher ist.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Tagesschlüssel des Montags der Woche von `date`.
    static func weekKey(for date: Date, calendar: Calendar = .current) -> String {
        dayKey(for: startOfWeek(for: date, calendar: calendar), calendar: calendar)
    }

    static func startOfWeek(for date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Montag
        cal.minimumDaysInFirstWeek = 4
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start
        return start ?? cal.startOfDay(for: date)
    }

    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Ein Stück eines Zeitraums, das in genau eine Stunde eines Tages fällt.
    struct Slice: Equatable {
        let dayKey: String
        let hour: Int
        let seconds: Double
    }

    /// Teilt `[start, end)` an Stunden- (und damit Tages-)Grenzen.
    static func slices(from start: Date, to end: Date, calendar: Calendar = .current) -> [Slice] {
        guard end > start else { return [] }
        var result: [Slice] = []
        var cursor = start
        // Obergrenze gegen Endlosschleifen bei kaputten Uhren: höchstens 8 Tage.
        var guardCount = 0
        while cursor < end, guardCount < 24 * 8 {
            guardCount += 1
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)
            let hourEnd = hourStart?.end ?? end
            let sliceEnd = min(hourEnd, end)
            let hour = calendar.component(.hour, from: cursor)
            result.append(Slice(
                dayKey: dayKey(for: cursor, calendar: calendar),
                hour: hour,
                seconds: sliceEnd.timeIntervalSince(cursor)
            ))
            cursor = sliceEnd
        }
        return result
    }
}
