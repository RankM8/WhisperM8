import Foundation

/// Live-Limit-Stand eines Claude-Accounts (5h-Fenster + Wochen-Limit).
struct ClaudeAccountUsage: Equatable {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Double?
    var sevenDayResetsAt: Date?
    var fetchedAt: Date
    /// `true` = frisch vom Endpoint, `false` = aus dem Statusline-Cache.
    var isLive: Bool
}

/// Fragt die 5h-/Wochen-Limits eines Account-Profils ab: OAuth-Token aus dem
/// Keychain (Service-Name deterministisch aus dem Profil berechnet), dann
/// `GET api.anthropic.com/api/oauth/usage` — derselbe (inoffizielle) Endpoint,
/// den auch die Statusline und Community-Monitore nutzen. Antworten werden in
/// den Statusline-Cache (`/tmp/claude-usage-cache-<profil>.json`) gespiegelt,
/// Fallback-Kette bei Fehlern: Cache → nil. Das Token bleibt in-process und
/// wird nie geloggt oder persistiert.
struct ClaudeAccountUsageFetcher {
    var profiles = ClaudeAccountProfiles()
    /// Test-Injektion: URL-Request ausfuehren, Antwort-Body liefern.
    var httpBody: (URLRequest) async -> Data? = { request in
        try? await URLSession.shared.data(for: request).0
    }

    func fetchUsage(forProfile name: String) async -> ClaudeAccountUsage? {
        if let live = await fetchLiveUsage(forProfile: name) {
            return live
        }
        return cachedUsage(forProfile: name)
    }

    private func fetchLiveUsage(forProfile name: String) async -> ClaudeAccountUsage? {
        let service = profiles.keychainService(forProfile: name)
        let (status, secret) = profiles.securityRunner(["find-generic-password", "-s", service, "-w"])
        guard status == 0,
              let secretData = secret.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let credentials = try? JSONSerialization.jsonObject(with: secretData) as? [String: Any],
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("claude-code/2.1.207", forHTTPHeaderField: "User-Agent")

        guard let body = await httpBody(request),
              let usage = Self.parseUsage(body, fetchedAt: Date(), isLive: true) else {
            return nil
        }
        writeCache(body, forProfile: name)
        return usage
    }

    /// Fallback: letzter Stand aus dem Statusline-Cache (gleiche Datei, die
    /// `statusline-command.sh` und `ccs status` verwenden).
    private func cachedUsage(forProfile name: String) -> ClaudeAccountUsage? {
        let path = cachePath(forProfile: name)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        return Self.parseUsage(data, fetchedAt: mtime, isLive: false)
    }

    private func cachePath(forProfile name: String) -> String {
        "/tmp/claude-usage-cache-\(name).json"
    }

    private func writeCache(_ body: Data, forProfile name: String) {
        FileManager.default.createFile(atPath: cachePath(forProfile: name), contents: body)
    }

    /// Parst die Endpoint-Antwort (`five_hour`/`seven_day` mit `utilization`
    /// bzw. `used_percentage` und `resets_at` als ISO-String oder Epoch).
    static func parseUsage(_ data: Data, fetchedAt: Date, isLive: Bool) -> ClaudeAccountUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func window(_ key: String) -> (Double?, Date?) {
            guard let dict = obj[key] as? [String: Any] else { return (nil, nil) }
            let percent = (dict["utilization"] as? Double)
                ?? (dict["used_percentage"] as? Double)
                ?? (dict["utilization"] as? Int).map(Double.init)
            return (percent, parseResetDate(dict["resets_at"]))
        }

        let (fiveHour, fiveHourReset) = window("five_hour")
        let (sevenDay, sevenDayReset) = window("seven_day")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeAccountUsage(
            fiveHourPercent: fiveHour,
            fiveHourResetsAt: fiveHourReset,
            sevenDayPercent: sevenDay,
            sevenDayResetsAt: sevenDayReset,
            fetchedAt: fetchedAt,
            isLive: isLive
        )
    }

    static func parseResetDate(_ value: Any?) -> Date? {
        if let epoch = value as? Double { return Date(timeIntervalSince1970: epoch) }
        if let epoch = value as? Int { return Date(timeIntervalSince1970: Double(epoch)) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
