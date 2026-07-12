import Foundation

/// Rate-Limit-Stand eines Codex-/ChatGPT-Accounts, gelesen aus den lokalen
/// Session-JSONLs: Codex schreibt in jedes `token_count`-Event ein
/// `rate_limits`-Objekt (verifiziert 2026-07-12, codex 0.144): `primary`/
/// `secondary` mit `used_percent`, `window_minutes` (300 = 5h-Fenster,
/// 10080 = Woche) und `resets_at` (Epoch) plus `plan_type`. Kein Endpoint,
/// keine Tokens — reine Datei-Lektüre.
struct CodexUsage: Equatable {
    struct Window: Equatable {
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date?

        /// „5h", „Woche" oder „Xh" — abgeleitet aus der Fensterlänge.
        var label: String {
            switch windowMinutes {
            case 300: return "5h"
            case 10080: return "wk"
            default: return "\(windowMinutes / 60)h"
            }
        }
    }

    /// Modell-gescoptes Zusatz-Limit (z. B. „GPT-5.3-Codex-Spark") aus
    /// `additional_rate_limits` — das Codex-Pendant zum Fable-Wochen-Limit.
    struct ScopedLimit: Equatable {
        var name: String
        var window: Window
    }

    var primary: Window?
    var secondary: Window?
    var scopedLimits: [ScopedLimit] = []
    var planType: String?
    var emailAddress: String?
    /// Zeitstempel des Events — die Daten sind so frisch wie der letzte
    /// Codex-Turn (JSONL) bzw. der Abruf (live).
    var capturedAt: Date?
    /// `true` = frisch vom wham/usage-Endpoint, `false` = JSONL-Snapshot.
    var isLive = false
}

struct CodexUsageReader {
    var sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)
    var fileManager: FileManager = .default

    /// Jüngster bekannter Rate-Limit-Stand: durchsucht die neuesten
    /// Session-Dateien (mtime-sortiert) von hinten nach dem letzten
    /// `rate_limits`-Event. Tail-Read (256 KB) statt Voll-Parse — die
    /// JSONLs können > 50 MB groß sein.
    func latestUsage(maxFiles: Int = 6) -> CodexUsage? {
        for fileURL in newestSessionFiles(limit: maxFiles) {
            if let usage = latestUsage(inFile: fileURL) {
                return usage
            }
        }
        return nil
    }

    private func newestSessionFiles(limit: Int) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, mtime))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func latestUsage(inFile fileURL: URL) -> CodexUsage? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let tailLength: UInt64 = 256 * 1024
        let offset = fileSize > tailLength ? fileSize - tailLength : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Letztes rate_limits-Event gewinnt (Events sind chronologisch).
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let usage = Self.parseRateLimitsLine(String(line)) {
                return usage
            }
        }
        return nil
    }

    /// Parst eine `token_count`-Event-Zeile. Pure + testbar.
    static func parseRateLimitsLine(_ line: String) -> CodexUsage? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        func window(_ key: String) -> CodexUsage.Window? {
            guard let dict = rateLimits[key] as? [String: Any],
                  let percent = (dict["used_percent"] as? Double) ?? (dict["used_percent"] as? Int).map(Double.init),
                  let minutes = dict["window_minutes"] as? Int else {
                return nil
            }
            let resets = (dict["resets_at"] as? Double) ?? (dict["resets_at"] as? Int).map(Double.init)
            return CodexUsage.Window(
                usedPercent: percent,
                windowMinutes: minutes,
                resetsAt: resets.map { Date(timeIntervalSince1970: $0) }
            )
        }

        let primary = window("primary")
        let secondary = window("secondary")
        guard primary != nil || secondary != nil else { return nil }

        var capturedAt: Date?
        if let timestamp = obj["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            capturedAt = formatter.date(from: timestamp)
            if capturedAt == nil {
                formatter.formatOptions = [.withInternetDateTime]
                capturedAt = formatter.date(from: timestamp)
            }
        }

        return CodexUsage(
            primary: primary,
            secondary: secondary,
            planType: rateLimits["plan_type"] as? String,
            capturedAt: capturedAt
        )
    }
}

/// Live-Abfrage der Codex-/ChatGPT-Limits: Access-Token + Account-ID aus
/// `auth.json` des Codex-Homes, dann `GET chatgpt.com/backend-api/wham/usage`
/// (der Endpoint der offiziellen Codex-TUI; live verifiziert 2026-07-13).
/// Fallback bei Fehlern: JSONL-Snapshot via `CodexUsageReader`. Token bleibt
/// in-process, wird nie geloggt oder persistiert.
struct CodexUsageFetcher {
    var codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    /// Test-Injektion: URL-Request ausfuehren, Antwort-Body liefern.
    var httpBody: (URLRequest) async -> Data? = { request in
        try? await URLSession.shared.data(for: request).0
    }

    func fetchUsage() async -> CodexUsage? {
        if let live = await fetchLiveUsage() {
            return live
        }
        return CodexUsageReader(
            sessionsRoot: codexHome.appendingPathComponent("sessions", isDirectory: true)
        ).latestUsage()
    }

    private func fetchLiveUsage() async -> CodexUsage? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            return nil
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountID = tokens["account_id"] as? String, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        guard let body = await httpBody(request) else { return nil }
        return Self.parseWhamUsage(body, fetchedAt: Date())
    }

    /// Parst die wham/usage-Antwort: `plan_type`, `email`,
    /// `rate_limit.primary_window/secondary_window` (`used_percent`,
    /// `limit_window_seconds`, `reset_at`-Epoch) und
    /// `additional_rate_limits[]` (modell-gescopte Limits mit `limit_name`).
    static func parseWhamUsage(_ data: Data, fetchedAt: Date) -> CodexUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = obj["rate_limit"] as? [String: Any] else {
            return nil
        }

        func window(_ dict: Any?) -> CodexUsage.Window? {
            guard let dict = dict as? [String: Any],
                  let percent = (dict["used_percent"] as? Double) ?? (dict["used_percent"] as? Int).map(Double.init),
                  let seconds = dict["limit_window_seconds"] as? Int else {
                return nil
            }
            let resets = (dict["reset_at"] as? Double) ?? (dict["reset_at"] as? Int).map(Double.init)
            return CodexUsage.Window(
                usedPercent: percent,
                windowMinutes: seconds / 60,
                resetsAt: resets.map { Date(timeIntervalSince1970: $0) }
            )
        }

        let primary = window(rateLimit["primary_window"])
        let secondary = window(rateLimit["secondary_window"])
        guard primary != nil || secondary != nil else { return nil }

        var scoped: [CodexUsage.ScopedLimit] = []
        for entry in (obj["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            guard let name = entry["limit_name"] as? String,
                  let limitWindow = window((entry["rate_limit"] as? [String: Any])?["primary_window"]) else {
                continue
            }
            scoped.append(CodexUsage.ScopedLimit(name: name, window: limitWindow))
        }

        return CodexUsage(
            primary: primary,
            secondary: secondary,
            scopedLimits: scoped,
            planType: obj["plan_type"] as? String,
            emailAddress: obj["email"] as? String,
            capturedAt: fetchedAt,
            isLive: true
        )
    }
}
