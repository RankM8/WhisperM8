import Foundation

// Reine Parser für die Protokollzeilen von Claude Code und Codex. Kein I/O,
// kein Zustand — der `StatisticsLogScanner` füttert sie Zeile für Zeile.
//
// Teuer ist hier nur das JSON-Dekodieren. Deshalb prüft jeder Parser zuerst
// auf Byte-Ebene, ob die Zeile überhaupt in Frage kommt: Die allermeisten
// Zeilen sind Werkzeug-Ausgaben und Nutzertexte, die wir nie anfassen.

/// Ein Verbrauchseintrag aus einer Claude-Antwort.
struct ClaudeUsageRecord: Equatable, Sendable {
    /// Hash aus `message.id` + `requestId`. Claude schreibt pro Content-Block
    /// eine eigene Zeile mit identischer usage; ohne Dedup zählte jede
    /// Antwort mehrfach. `nil`, wenn die Zeile keine IDs trägt.
    var dedupKey: UInt64?
    /// Modellname, im Fast-Modus mit `ModelPricing.fastSuffix`.
    var model: String
    var timestamp: Date
    /// Letzter Pfadteil von `cwd`.
    var project: String?
    var usage: TokenUsage
}

/// Gesamtstand eines Codex-`token_count`-Events (`total_token_usage`).
/// `input` enthält bei Codex die gecachte Eingabe mit.
struct CodexTokenTotals: Codable, Equatable, Sendable {
    var input: Int = 0
    var cached: Int = 0
    var output: Int = 0

    var isZero: Bool { input == 0 && cached == 0 && output == 0 }
}

/// Ein Fenster aus `rate_limits.primary` bzw. `.secondary`.
struct CodexRateWindow: Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Date?
}

struct CodexRateLimits: Equatable, Sendable {
    var windows: [CodexRateWindow]
    var planType: String?

    /// Fenster bis zu einem Tag zählen als „5 h“, längere als Woche. Codex
    /// sortiert sie nicht fest: je nach Plan steht die Woche in `primary`.
    func snapshot(capturedAt: Date) -> LimitSnapshot? {
        guard !windows.isEmpty else { return nil }
        var snapshot = LimitSnapshot(capturedAt: capturedAt)
        for window in windows {
            if window.windowMinutes <= 24 * 60 {
                snapshot.fiveHourPercent = window.usedPercent
                snapshot.fiveHourResetsAt = window.resetsAt
            } else {
                snapshot.weekPercent = window.usedPercent
                snapshot.weekResetsAt = window.resetsAt
            }
        }
        return snapshot
    }
}

/// Was eine Codex-Zeile für die Statistik bedeutet.
enum CodexLogEvent: Equatable, Sendable {
    case sessionMeta(cwd: String?)
    case turnContext(model: String?, cwd: String?)
    /// `totals == nil`: Event ohne `info` (kommt vor, trägt dann oft nur Limits).
    case tokenCount(timestamp: Date, totals: CodexTokenTotals?, rateLimits: CodexRateLimits?)
}

enum StatisticsLogParser {
    /// Konto für GPT-Antworten, die über den lokalen Proxy in Claude Code liefen.
    static let gptProxyAccount = "gpt-proxy"
    /// Konto für die Codex-CLI.
    static let codexAccount = "codex"
    /// Modellname, falls ein Codex-Event vor dem ersten `turn_context` kommt.
    static let codexFallbackModel = "codex"

    // MARK: - Claude

    private static let usageNeedle = Array(#""usage""#.utf8)
    private static let assistantNeedle = Array(#""assistant""#.utf8)

    /// Liest eine Claude-Zeile. `nil` für alles, was keine zählbare Antwort ist
    /// (Nutzerzeilen, Werkzeug-Ausgaben, `<synthetic>`-Platzhalter).
    static func parseClaudeLine(_ line: UnsafeRawBufferPointer) -> ClaudeUsageRecord? {
        guard contains(line, usageNeedle), contains(line, assistantNeedle) else { return nil }
        guard let base = line.baseAddress, line.count > 0 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        guard let decoded = try? JSONDecoder().decode(ClaudeLine.self, from: data) else { return nil }
        return record(from: decoded)
    }

    static func parseClaudeLine(_ line: Data) -> ClaudeUsageRecord? {
        line.withUnsafeBytes { parseClaudeLine($0) }
    }

    private static func record(from line: ClaudeLine) -> ClaudeUsageRecord? {
        guard line.type == "assistant",
              let message = line.message,
              let usage = message.usage,
              var model = message.model, !model.isEmpty, model != "<synthetic>",
              let raw = line.timestamp, let timestamp = parseTimestamp(raw)
        else { return nil }

        if usage.speed == "fast" { model += ModelPricing.fastSuffix }

        let cacheCreation = usage.cache_creation_input_tokens ?? 0
        var write5m = cacheCreation
        var write1h = 0
        if let split = usage.cache_creation,
           split.ephemeral_5m_input_tokens != nil || split.ephemeral_1h_input_tokens != nil {
            write5m = split.ephemeral_5m_input_tokens ?? 0
            write1h = split.ephemeral_1h_input_tokens ?? 0
        }

        let tokens = TokenUsage(
            messages: 1,
            input: usage.input_tokens ?? 0,
            output: usage.output_tokens ?? 0,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            cacheRead: usage.cache_read_input_tokens ?? 0
        )

        var dedupKey: UInt64?
        if message.id != nil || line.requestId != nil {
            dedupKey = AppInstance.stableHash("claude|\(message.id ?? "")|\(line.requestId ?? "")")
        }
        return ClaudeUsageRecord(
            dedupKey: dedupKey,
            model: model,
            timestamp: timestamp,
            project: projectName(fromCwd: line.cwd),
            usage: tokens
        )
    }

    /// Konto, unter dem eine Claude-Antwort zählt: GPT-Modelle laufen über den
    /// Proxy und damit über das ChatGPT-Abo, nicht über das Claude-Profil.
    static func claudeAccount(profile: String, model: String) -> String {
        model.lowercased().hasPrefix("gpt-") ? gptProxyAccount : profile
    }

    // MARK: - Codex

    private static let tokenCountNeedle = Array(#""token_count""#.utf8)
    private static let turnContextNeedle = Array(#""turn_context""#.utf8)
    private static let sessionMetaNeedle = Array(#""session_meta""#.utf8)

    static func parseCodexLine(_ line: UnsafeRawBufferPointer) -> CodexLogEvent? {
        let isTokenCount = contains(line, tokenCountNeedle)
        guard isTokenCount || contains(line, turnContextNeedle) || contains(line, sessionMetaNeedle) else { return nil }
        guard let base = line.baseAddress, line.count > 0 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        guard let decoded = try? JSONDecoder().decode(CodexLine.self, from: data) else { return nil }

        switch decoded.type {
        case "session_meta":
            return .sessionMeta(cwd: decoded.payload?.cwd)
        case "turn_context":
            return .turnContext(model: decoded.payload?.model, cwd: decoded.payload?.cwd)
        case "event_msg":
            guard let payload = decoded.payload, payload.type == "token_count",
                  let raw = decoded.timestamp, let timestamp = parseTimestamp(raw)
            else { return nil }
            let totals = payload.info?.total_token_usage.map {
                CodexTokenTotals(input: $0.input_tokens ?? 0, cached: $0.cached_input_tokens ?? 0, output: $0.output_tokens ?? 0)
            }
            var limits: CodexRateLimits?
            if let rate = payload.rate_limits {
                let windows = [rate.primary, rate.secondary].compactMap { window -> CodexRateWindow? in
                    guard let window, let percent = window.used_percent else { return nil }
                    return CodexRateWindow(
                        usedPercent: percent,
                        windowMinutes: window.window_minutes ?? 0,
                        resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) }
                    )
                }
                if !windows.isEmpty { limits = CodexRateLimits(windows: windows, planType: rate.plan_type) }
            }
            return .tokenCount(timestamp: timestamp, totals: totals, rateLimits: limits)
        default:
            return nil
        }
    }

    static func parseCodexLine(_ line: Data) -> CodexLogEvent? {
        line.withUnsafeBytes { parseCodexLine($0) }
    }

    /// Verbrauch zwischen zwei Gesamtständen. Wiederholte Events liefern
    /// `nil`. Fällt ein Wert (neue Zählung), zählt der neue Stand als Zuwachs.
    static func codexDelta(from previous: CodexTokenTotals, to current: CodexTokenTotals) -> TokenUsage? {
        func diff(_ new: Int, _ old: Int) -> Int { new >= old ? new - old : new }
        let input = diff(current.input, previous.input)
        let cached = diff(current.cached, previous.cached)
        let output = diff(current.output, previous.output)
        guard input > 0 || cached > 0 || output > 0 else { return nil }
        return TokenUsage(
            messages: 1,
            input: max(0, input - cached),
            output: output,
            cacheRead: cached
        )
    }

    // MARK: - Hilfen

    /// Letzter Pfadteil eines Arbeitsordners: `/Users/x/repos/whisperm8` → `whisperm8`.
    static func projectName(fromCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed.isEmpty ? nil : trimmed }
        let name = trimmed[trimmed.index(after: slash)...]
        return name.isEmpty ? nil : String(name)
    }

    /// ISO-8601 ohne Formatter: `2026-10-29T18:11:39.406Z` oder mit
    /// `+02:00`. Der `ISO8601DateFormatter` wäre bei Hunderttausenden Zeilen
    /// spürbar teurer.
    static func parseTimestamp(_ text: String) -> Date? {
        let utf8 = Array(text.utf8)
        guard utf8.count >= 19 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for i in start..<(start + length) {
                let byte = utf8[i]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard utf8[4] == 45, utf8[7] == 45, utf8[10] == 84 || utf8[10] == 32, utf8[13] == 58, utf8[16] == 58,
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < utf8.count, utf8[index] == 46 {
            index += 1
            var scale = 0.1
            while index < utf8.count, utf8[index] >= 48, utf8[index] <= 57 {
                fraction += Double(utf8[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offsetSeconds = 0
        if index < utf8.count {
            let sign = utf8[index]
            if sign == 43 || sign == 45 {
                // `+0200` oder `+02:00`
                let digits = utf8[(index + 1)...].filter { $0 != 58 }
                guard digits.count >= 4, digits.prefix(4).allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
                let d = Array(digits.prefix(4)).map { Int($0 - 48) }
                offsetSeconds = ((d[0] * 10 + d[1]) * 3600 + (d[2] * 10 + d[3]) * 60) * (sign == 45 ? -1 : 1)
            } else if sign != 90 {
                return nil
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Tage seit 1970-01-01 (Algorithmus von Howard Hinnant).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in
            memmem(base, haystack.count, n.baseAddress, n.count) != nil
        }
    }
}

// MARK: - Dekodier-Strukturen (nur die Felder, die wir brauchen)

private struct ClaudeLine: Decodable {
    var type: String?
    var timestamp: String?
    var cwd: String?
    var requestId: String?
    var message: Message?

    struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    // swiftlint:disable identifier_name
    struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_creation_input_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation: CacheCreation?
        var speed: String?
    }

    struct CacheCreation: Decodable {
        var ephemeral_5m_input_tokens: Int?
        var ephemeral_1h_input_tokens: Int?
    }
}

private struct CodexLine: Decodable {
    var timestamp: String?
    var type: String?
    var payload: Payload?

    struct Payload: Decodable {
        var type: String?
        var cwd: String?
        var model: String?
        var info: Info?
        var rate_limits: RateLimits?

        enum CodingKeys: String, CodingKey { case type, cwd, model, info, rate_limits }

        // Tolerant: ein Feld mit unerwartetem Typ (Codex ändert sein Format
        // gelegentlich) soll nicht die ganze Zeile kosten.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            info = try? c.decodeIfPresent(Info.self, forKey: .info)
            rate_limits = try? c.decodeIfPresent(RateLimits.self, forKey: .rate_limits)
        }
    }

    struct Info: Decodable {
        var total_token_usage: Usage?
    }

    struct Usage: Decodable {
        var input_tokens: Int?
        var cached_input_tokens: Int?
        var output_tokens: Int?
    }

    struct RateLimits: Decodable {
        var primary: Window?
        var secondary: Window?
        var plan_type: String?
    }

    struct Window: Decodable {
        var used_percent: Double?
        var window_minutes: Int?
        var resets_at: Double?
    }
    // swiftlint:enable identifier_name
}
