import Foundation

/// Live-Limit-Stand eines Claude-Accounts (5h-Fenster + Wochen-Limit +
/// modell-spezifisches Wochen-Limit, z. B. Fable).
struct ClaudeAccountUsage: Equatable {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Double?
    var sevenDayResetsAt: Date?
    /// Modell-gescoptes Wochen-Limit (`limits[].kind == "weekly_scoped"`),
    /// aktuell das Fable-Kontingent („halbes Wochen-Limit auf Fable 5").
    var modelWeeklyPercent: Double?
    var modelWeeklyResetsAt: Date?
    /// Anzeigename des gescopten Modells (`scope.model.display_name`).
    var modelWeeklyLabel: String?
    var fetchedAt: Date
    /// `true` = frisch vom Endpoint, `false` = aus dem Statusline-Cache.
    var isLive: Bool
    /// Warum der Live-Abruf scheiterte (`nil` = live). Damit kann die UI
    /// „Login abgelaufen" von „Cache halt alt" unterscheiden, statt Fehler
    /// still als veralteten Cache-Stand auszugeben.
    var liveFetchProblem: ClaudeUsageFetchProblem?

    /// `false` = reiner Fehler-Stand ohne ein einziges Limit (kein Cache
    /// vorhanden) — dann lohnen sich keine Gauge-Zeilen.
    var hasLimitData: Bool {
        fiveHourPercent != nil || sevenDayPercent != nil || modelWeeklyPercent != nil
    }
}

/// Grund, warum kein Live-Stand vom oauth/usage-Endpoint geholt werden konnte.
enum ClaudeUsageFetchProblem: Equatable {
    /// Kein Keychain-Secret (nie eingeloggt oder Item entfernt).
    case noCredentials
    /// Der letzte CLI-Ping meldete einen toten Login (Refresh-Token
    /// abgelehnt) — der Account braucht einen neuen Browser-Login.
    case loginExpired
    /// Token abgelaufen, aber unter dem Profil läuft gerade eine Session —
    /// deren Claude-Prozess erneuert den Token selbst, WhisperM8 pingt
    /// dann bewusst nicht. Kein Handlungsbedarf, nur kurz warten.
    case refreshBlockedBySession
    /// Access-Token abgelaufen — erst der manuelle Update-Button erneuert
    /// ihn (per CLI-Ping, `ClaudeAccountLimitPinger`).
    case tokenExpired
    /// Ping-Cooldown aktiv (letzter Ping/Fehlversuch liegt kurz zurück) —
    /// nächster Versuch frühestens ab `until`.
    case refreshCoolingDown(until: Date)
    /// Endpoint erreichbar, aber Fehlerstatus (z. B. 429 Rate-Limit).
    case httpStatus(Int)
    /// Kein Response (offline, Timeout).
    case network
}

/// Prozessweiter Cooldown für Token-Erneuerungen (CLI-Pings), pro Profil.
/// Historie: hier stand der Cooldown des eigenen OAuth-POSTs — der ist
/// ausgebaut (0 % Erfolgsquote, siehe `ClaudeAccountLimitPinger`). Der Store
/// bleibt, damit Pings nicht im Minutentakt wiederholt werden und das
/// Ergebnis des letzten Versuchs (z. B. „Login tot") sichtbar bleibt.
final class ClaudeTokenRefreshThrottle: @unchecked Sendable {
    static let shared = ClaudeTokenRefreshThrottle()

    struct Entry {
        var nextAllowedAt: Date
        /// Ergebnis des letzten Versuchs — wird während des Cooldowns weiter
        /// ausgewiesen (z. B. „Login abgelaufen" statt generischem Warten).
        var problem: ClaudeUsageFetchProblem?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Aktiver Cooldown-Eintrag, `nil` sobald `nextAllowedAt` erreicht ist.
    func blockedEntry(forProfile name: String, now: Date) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[name], entry.nextAllowedAt > now else { return nil }
        return entry
    }

    func record(profile: String, nextAllowedAt: Date, problem: ClaudeUsageFetchProblem?) {
        lock.lock(); defer { lock.unlock() }
        entries[profile] = Entry(nextAllowedAt: nextAllowedAt, problem: problem)
    }
}

/// Fragt die 5h-/Wochen-Limits eines Account-Profils ab: OAuth-Token aus dem
/// Keychain (Service-Name deterministisch aus dem Profil berechnet), dann
/// `GET api.anthropic.com/api/oauth/usage` — derselbe (inoffizielle) Endpoint,
/// den auch die Statusline und Community-Monitore nutzen.
///
/// Der Fetcher ist strikt PASSIV: er rotiert nie Tokens. Der frühere eigene
/// Refresh-POST auf den OAuth-Token-Endpoint ist ausgebaut — er wurde in der
/// Praxis zu null Prozent akzeptiert (streng pro IP gedrosselt, 429-Sperren
/// im 25+-Minuten-Bereich; Befund 2026-08-09) und riskierte, den
/// Refresh-Token einer parallel startenden CLI zu entwerten. Abgelaufene
/// Tokens erneuert ausschließlich der `ClaudeAccountLimitPinger` (manueller
/// Update-Button) über die Claude-CLI selbst, deren Refresh nachweislich
/// durchgeht.
///
/// Antworten werden in den Statusline-Cache gespiegelt, Fallback-Kette bei
/// Fehlern: Cache (mit `liveFetchProblem`) → leerer Fehler-Stand. Tokens
/// bleiben in-process und werden nie geloggt.
struct ClaudeAccountUsageFetcher {
    static let userAgent = "claude-code/2.1.207"

    var profiles = ClaudeAccountProfiles()

    /// Test-Injektion: URL-Request ausführen → (Body, HTTP-Status).
    var httpResponse: (URLRequest) async -> (Data?, Int?) = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (nil, nil)
        }
        return (data, (response as? HTTPURLResponse)?.statusCode)
    }

    /// Profile, unter denen gerade eine Session läuft — deren Claude-Prozess
    /// hält den Token selbst frisch (kein Ping nötig, präzisere UI-Auskunft).
    var busyProfileNames: () async -> Set<String> = defaultBusyProfileNames

    /// Default: laufende PTYs der App gegen die Session-Stempel des Stores
    /// auflösen. Static, damit der `ClaudeAccountLimitPinger` dieselbe
    /// Definition nutzt.
    static func defaultBusyProfileNames() async -> Set<String> {
        await MainActor.run {
            let running = AgentTerminalRegistry.shared.activeSessionIDs
            guard !running.isEmpty else { return [] }
            let sessions = AgentSessionStore().loadWorkspace().sessions
            return Set(
                sessions
                    .filter { running.contains($0.id) }
                    .map { $0.claudeProfileName ?? ClaudeAccountProfiles.mainProfileName }
            )
        }
    }

    /// Cache-Basis wie in der Statusline: `${TMPDIR:-/tmp/}` — macOS' privates
    /// per-User-Temp-Verzeichnis, für App und Shells desselben Users identisch.
    var temporaryDirectory: String = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"

    var now: () -> Date = Date.init

    /// Cooldown-Store — injizierbar, damit Tests nicht über das
    /// prozessweite Singleton koppeln.
    var refreshThrottle: ClaudeTokenRefreshThrottle = .shared

    /// Holt Usage ausschließlich mit dem vorhandenen Access-Token;
    /// abgelaufen → Cache + präzises Problem, ohne irgendeinen Token-Endpoint
    /// zu berühren.
    func fetchUsage(forProfile name: String) async -> ClaudeAccountUsage? {
        switch await fetchLiveUsage(forProfile: name) {
        case .usage(let usage):
            return usage
        case .problem(let problem):
            if var cached = cachedUsage(forProfile: name) {
                cached.liveFetchProblem = problem
                return cached
            }
            // Nie eingeloggt + kein Cache: nichts anzuzeigen. Sonst einen
            // leeren Stand liefern, damit die UI den Fehler ausweisen kann.
            guard problem != .noCredentials else { return nil }
            return ClaudeAccountUsage(fetchedAt: now(), isLive: false, liveFetchProblem: problem)
        }
    }

    // MARK: - Live-Fetch

    private enum LiveResult {
        case usage(ClaudeAccountUsage)
        case problem(ClaudeUsageFetchProblem)
    }

    private func fetchLiveUsage(forProfile name: String) async -> LiveResult {
        guard let secret = readSecret(forProfile: name) else {
            return .problem(.noCredentials)
        }

        // Abgelaufenes Token würde garantiert 401en — gar nicht erst anfragen.
        if let expiresAt = secret.expiresAt, expiresAt.timeIntervalSince(now()) < 60 {
            return .problem(await expiredTokenProblem(forProfile: name))
        }

        let (body, status) = await httpResponse(usageRequest(token: secret.accessToken))
        guard let status else { return .problem(.network) }
        guard (200..<300).contains(status) else {
            // 401 trotz (laut Stempel) gültigem Token: vorzeitig entwertet —
            // gleiche Auskunft wie „abgelaufen", der Update-Ping hilft auch hier.
            guard status != 401 else {
                return .problem(await expiredTokenProblem(forProfile: name))
            }
            return .problem(.httpStatus(status))
        }
        guard let body, let usage = Self.parseUsage(body, fetchedAt: now(), isLive: true) else {
            return .problem(.httpStatus(status))
        }
        writeCache(body, forProfile: name)
        return .usage(usage)
    }

    /// Präzise Auskunft bei abgelaufenem Token: ein Cooldown-Eintrag des
    /// letzten Ping-Versuchs (z. B. „Login abgelaufen") schlägt die Heuristik;
    /// läuft eine Session unter dem Profil, erneuert die den Token gleich
    /// selbst; sonst das generische „Update drücken".
    private func expiredTokenProblem(forProfile name: String) async -> ClaudeUsageFetchProblem {
        if let entry = refreshThrottle.blockedEntry(forProfile: name, now: now()) {
            return entry.problem ?? .refreshCoolingDown(until: entry.nextAllowedAt)
        }
        if await busyProfileNames().contains(name) {
            return .refreshBlockedBySession
        }
        return .tokenExpired
    }

    private func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Keychain-Secret (nur lesen — Rotation macht die CLI)

    private struct KeychainSecret {
        var accessToken: String
        var expiresAt: Date?
    }

    private func readSecret(forProfile name: String) -> KeychainSecret? {
        let service = profiles.keychainService(forProfile: name)
        let (status, secret) = profiles.securityRunner(["find-generic-password", "-s", service, "-w"])
        guard status == 0,
              let data = secret.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = raw["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        let millis = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init)
        return KeychainSecret(
            accessToken: token,
            expiresAt: millis.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: - Cache

    /// Fallback: letzter Stand aus dem Statusline-Cache (gleiche Datei, die
    /// `statusline-command.sh` und `ccs status` schreiben). Liest zusätzlich
    /// den Alt-Pfad unter literal `/tmp/`, den frühere App-Versionen schrieben.
    private func cachedUsage(forProfile name: String) -> ClaudeAccountUsage? {
        for path in [cachePath(forProfile: name), legacyCachePath(forProfile: name)] {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
            if let usage = Self.parseUsage(data, fetchedAt: mtime, isLive: false) {
                return usage
            }
        }
        return nil
    }

    private func cachePath(forProfile name: String) -> String {
        (temporaryDirectory as NSString).appendingPathComponent("claude-usage-cache-\(name).json")
    }

    private func legacyCachePath(forProfile name: String) -> String {
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

        // Modell-gescoptes Wochen-Limit aus dem limits-Array (z. B. Fable:
        // kind=weekly_scoped, scope.model.display_name="Fable").
        var modelPercent: Double?
        var modelReset: Date?
        var modelLabel: String?
        if let limits = obj["limits"] as? [[String: Any]],
           let scoped = limits.first(where: { ($0["kind"] as? String) == "weekly_scoped" }) {
            modelPercent = (scoped["percent"] as? Double) ?? (scoped["percent"] as? Int).map(Double.init)
            modelReset = parseResetDate(scoped["resets_at"])
            let scope = scoped["scope"] as? [String: Any]
            modelLabel = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
        }

        guard fiveHour != nil || sevenDay != nil || modelPercent != nil else { return nil }
        return ClaudeAccountUsage(
            fiveHourPercent: fiveHour,
            fiveHourResetsAt: fiveHourReset,
            sevenDayPercent: sevenDay,
            sevenDayResetsAt: sevenDayReset,
            modelWeeklyPercent: modelPercent,
            modelWeeklyResetsAt: modelReset,
            modelWeeklyLabel: modelLabel,
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
