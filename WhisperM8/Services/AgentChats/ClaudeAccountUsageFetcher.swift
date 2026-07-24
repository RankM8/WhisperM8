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
    /// Access-Token abgelaufen und der Refresh-Token wurde abgelehnt oder
    /// fehlt — der Account braucht einen neuen Browser-Login.
    case loginExpired
    /// Token abgelaufen, aber unter dem Profil läuft gerade eine Session —
    /// deren Claude-Prozess erneuert den Token selbst, WhisperM8 rotiert
    /// dann bewusst nicht mit. Kein Handlungsbedarf, nur kurz warten.
    case refreshBlockedBySession
    /// Access-Token abgelaufen, Refresh im passiven Modus bewusst
    /// übersprungen — erst der manuelle Update-Button rotiert Tokens.
    case tokenExpired
    /// Refresh-Cooldown aktiv (z. B. nach einem 429 des Token-Endpoints) —
    /// nächster Versuch frühestens ab `until`.
    case refreshCoolingDown(until: Date)
    /// Endpoint erreichbar, aber Fehlerstatus (z. B. 429 Rate-Limit).
    case httpStatus(Int)
    /// Kein Response (offline, Timeout).
    case network
}

/// Prozessweiter Cooldown für Token-Refreshes, pro Profil. Der
/// OAuth-Token-Endpoint ist streng pro IP gedrosselt (429-Sperren im
/// Minuten- bis Stundenbereich, beobachtet 2026-07-23) — auch der manuelle
/// Update-Button darf ihn deshalb nicht beliebig oft treffen.
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
/// Abgelaufene Access-Tokens (inaktive Accounts, Claude Code refresht nur bei
/// laufender Session) werden NUR auf explizite Anforderung erneuert
/// (`allowTokenRefresh: true`, der manuelle Update-Button): `refreshToken`
/// gegen den OAuth-Token-Endpoint tauschen und das rotierte Secret
/// feld-erhaltend in die Keychain zurückschreiben. Passive Abrufe (onAppear
/// von Tab/Popover) treffen den Token-Endpoint nie — er ist streng pro IP
/// gedrosselt. Zusätzlich Cooldown pro Profil (`ClaudeTokenRefreshThrottle`)
/// und kein Refresh, solange unter dem Profil eine Session läuft — deren
/// Claude-Prozess rotiert selbst, eine parallele Rotation würde seinen
/// Refresh-Token entwerten.
///
/// Antworten werden in den Statusline-Cache gespiegelt, Fallback-Kette bei
/// Fehlern: Cache (mit `liveFetchProblem`) → leerer Fehler-Stand. Tokens
/// bleiben in-process und werden nie geloggt.
struct ClaudeAccountUsageFetcher {
    /// Public client_id von Claude Code — derselbe, mit dem das CLI seinen
    /// OAuth-Flow fährt (verifiziert 2026-07-23 gegen v2.1.207).
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "claude-code/2.1.207"

    var profiles = ClaudeAccountProfiles()

    /// Test-Injektion: URL-Request ausführen → (Body, HTTP-Status).
    var httpResponse: (URLRequest) async -> (Data?, Int?) = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (nil, nil)
        }
        return (data, (response as? HTTPURLResponse)?.statusCode)
    }

    /// Profile, unter denen gerade eine Session läuft — für die darf der
    /// Refresh-Token nicht rotiert werden. Default: laufende PTYs der App
    /// gegen die Session-Stempel des Stores auflösen.
    var busyProfileNames: () async -> Set<String> = {
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

    /// `allowTokenRefresh: false` (Default, alle automatischen Aufrufe) holt
    /// Usage nur mit dem vorhandenen Access-Token; abgelaufen → Cache +
    /// `.tokenExpired`, ohne den Token-Endpoint zu berühren. `true` gibt es
    /// nur für den manuellen Update-Button.
    func fetchUsage(forProfile name: String, allowTokenRefresh: Bool = false) async -> ClaudeAccountUsage? {
        switch await fetchLiveUsage(forProfile: name, allowTokenRefresh: allowTokenRefresh) {
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

    private func fetchLiveUsage(forProfile name: String, allowTokenRefresh: Bool) async -> LiveResult {
        guard var secret = readSecret(forProfile: name) else {
            return .problem(.noCredentials)
        }

        // Proaktiver Refresh: abgelaufenes Token würde garantiert 401en.
        var refreshAttempted = false
        var refreshFailure: RefreshFailure?
        if let expiresAt = secret.expiresAt, expiresAt.timeIntervalSince(now()) < 60 {
            guard allowTokenRefresh else { return .problem(passiveProblem(forProfile: name)) }
            refreshAttempted = true
            switch await refreshSecret(secret, forProfile: name) {
            case .success(let refreshed): secret = refreshed
            case .failure(let failure): refreshFailure = failure
            }
        }

        var (body, status) = await httpResponse(usageRequest(token: secret.accessToken))

        // Reaktiver Refresh: 401 trotz (scheinbar) gültigem Token → genau EIN
        // Refresh-Versuch pro Fetch, nie zwei Rotationen hintereinander.
        if status == 401, !refreshAttempted {
            guard allowTokenRefresh else { return .problem(passiveProblem(forProfile: name)) }
            refreshAttempted = true
            switch await refreshSecret(secret, forProfile: name) {
            case .success(let refreshed):
                (body, status) = await httpResponse(usageRequest(token: refreshed.accessToken))
            case .failure(let failure):
                refreshFailure = failure
            }
        }

        guard let status else { return .problem(.network) }
        guard (200..<300).contains(status) else {
            guard status == 401 else { return .problem(.httpStatus(status)) }
            // 401: nur ein ABGELEHNTER Refresh-Token bedeutet „Login tot" —
            // ein gescheiterter Refresh (Rate-Limit, offline, Session läuft)
            // darf nicht als „bitte neu einloggen" ausgewiesen werden.
            switch refreshFailure {
            case nil, .rejected: return .problem(.loginExpired)
            case .blockedBySession: return .problem(.refreshBlockedBySession)
            case .coolingDown(let until, let lastProblem):
                return .problem(lastProblem ?? .refreshCoolingDown(until: until))
            case .http(let refreshStatus): return .problem(.httpStatus(refreshStatus))
            case .network: return .problem(.network)
            }
        }
        guard let body, let usage = Self.parseUsage(body, fetchedAt: now(), isLive: true) else {
            return .problem(.httpStatus(status))
        }
        writeCache(body, forProfile: name)
        return .usage(usage)
    }

    /// Problem-Zuordnung im passiven Modus (kein Refresh erlaubt): ein noch
    /// laufender Cooldown aus einem früheren Update-Versuch ist die
    /// präzisere Auskunft (z. B. „Login abgelaufen") als das generische
    /// „Token abgelaufen — Update drücken".
    private func passiveProblem(forProfile name: String) -> ClaudeUsageFetchProblem {
        refreshThrottle.blockedEntry(forProfile: name, now: now())?.problem ?? .tokenExpired
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

    // MARK: - Keychain-Secret + Token-Refresh

    /// Das komplette Keychain-Secret eines Profils. `raw` trägt ALLE Felder
    /// (auch `mcpOAuth` etc.) — beim Write-back nach einer Rotation darf
    /// nichts davon verloren gehen, sonst zerlegt WhisperM8 Claude Codes Login.
    private struct KeychainSecret {
        var raw: [String: Any]
        var oauth: [String: Any]
        var accessToken: String

        var refreshToken: String? { oauth["refreshToken"] as? String }
        var expiresAt: Date? {
            let millis = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init)
            return millis.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
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
        return KeychainSecret(raw: raw, oauth: oauth, accessToken: token)
    }

    /// Warum ein Refresh-Versuch scheiterte — entscheidet, ob der Fetch als
    /// „Login abgelaufen" (rejected) oder als vorübergehendes Problem endet.
    private enum RefreshFailure: Error {
        /// Kein refreshToken vorhanden oder der Endpoint hat ihn abgelehnt
        /// (400/401, invalid grant) — nur ein neuer Browser-Login hilft.
        case rejected
        /// Session unter dem Profil aktiv → Rotation bewusst unterlassen.
        case blockedBySession
        /// Cooldown aktiv — kein POST abgesetzt. Trägt den ggf. präziseren
        /// Grund des letzten Versuchs.
        case coolingDown(until: Date, lastProblem: ClaudeUsageFetchProblem?)
        /// Endpoint-Fehler (z. B. 429 Rate-Limit) — später erneut versuchen.
        case http(Int)
        case network
    }

    /// Tauscht den `refreshToken` gegen frische Tokens und schreibt das
    /// rotierte Secret zurück in die Keychain.
    private func refreshSecret(_ secret: KeychainSecret, forProfile name: String) async -> Result<KeychainSecret, RefreshFailure> {
        guard let refreshToken = secret.refreshToken, !refreshToken.isEmpty else { return .failure(.rejected) }
        guard await !busyProfileNames().contains(name) else {
            Logger.agentStore.info("claude_token_refresh_skipped profile=\(name, privacy: .public) reason=session_running")
            return .failure(.blockedBySession)
        }
        if let entry = refreshThrottle.blockedEntry(forProfile: name, now: now()) {
            Logger.agentStore.info("claude_token_refresh_skipped profile=\(name, privacy: .public) reason=cooldown")
            return .failure(.coolingDown(until: entry.nextAllowedAt, lastProblem: entry.problem))
        }

        var request = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.oauthClientID,
        ])

        let (data, status) = await httpResponse(request)
        guard let status else {
            Logger.agentStore.warning("claude_token_refresh_failed profile=\(name, privacy: .public) status=network")
            return .failure(.network)
        }
        guard (200..<300).contains(status), let data,
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = response["access_token"] as? String, !accessToken.isEmpty else {
            Logger.agentStore.warning("claude_token_refresh_failed profile=\(name, privacy: .public) status=\(status)")
            // 400/401 = Refresh-Token abgelehnt; alles andere ist vorübergehend.
            // Cooldown je nach Ausgang: ein 429 sperrt lange (beobachtete
            // IP-Sperren >25 min), ein toter Login braucht ohnehin keinen
            // zweiten POST — der Eintrag hält die präzise Auskunft fest.
            switch status {
            case 400, 401:
                refreshThrottle.record(
                    profile: name,
                    nextAllowedAt: now().addingTimeInterval(15 * 60),
                    problem: .loginExpired
                )
                return .failure(.rejected)
            case 429:
                refreshThrottle.record(
                    profile: name,
                    nextAllowedAt: now().addingTimeInterval(30 * 60),
                    problem: nil
                )
                return .failure(.http(status))
            default:
                refreshThrottle.record(
                    profile: name,
                    nextAllowedAt: now().addingTimeInterval(5 * 60),
                    problem: .httpStatus(status)
                )
                return .failure(.http(status))
            }
        }

        var oauth = secret.oauth
        oauth["accessToken"] = accessToken
        if let rotated = response["refresh_token"] as? String, !rotated.isEmpty {
            oauth["refreshToken"] = rotated
        }
        if let expiresIn = (response["expires_in"] as? Double) ?? (response["expires_in"] as? Int).map(Double.init) {
            oauth["expiresAt"] = Int((now().timeIntervalSince1970 + expiresIn) * 1000)
        }
        var raw = secret.raw
        raw["claudeAiOauth"] = oauth

        // Write-back ist Pflicht: der alte Refresh-Token ist nach der Rotation
        // entwertet — ginge das neue Secret verloren, wäre der Login weg.
        let service = profiles.keychainService(forProfile: name)
        if let json = (try? JSONSerialization.data(withJSONObject: raw)).flatMap({ String(data: $0, encoding: .utf8) }) {
            let (addStatus, _) = profiles.securityRunner([
                "add-generic-password", "-a", NSUserName(), "-s", service,
                "-l", service, "-w", json, "-U",
            ])
            if addStatus == 0 {
                Logger.agentStore.notice("claude_token_refreshed profile=\(name, privacy: .public)")
            } else {
                Logger.agentStore.error("claude_token_refresh_writeback_failed profile=\(name, privacy: .public) exit=\(addStatus)")
            }
        } else {
            Logger.agentStore.error("claude_token_refresh_writeback_failed profile=\(name, privacy: .public) exit=serialization")
        }
        // Auch nach Erfolg ein Cooldown: der frische Token hält Stunden, ein
        // weiterer POST innerhalb von Minuten wäre nur ein Fehlerpfad
        // (z. B. Write-back schlug fehl und der nächste Fetch liest wieder
        // das alte Secret — die alte Rotation nochmal zu versuchen ist zwecklos).
        refreshThrottle.record(
            profile: name,
            nextAllowedAt: now().addingTimeInterval(15 * 60),
            problem: nil
        )
        // Auch bei Write-back-Fehler mit dem frischen Token weiterarbeiten —
        // er ist der einzige, der jetzt noch gültig ist.
        return .success(KeychainSecret(raw: raw, oauth: oauth, accessToken: accessToken))
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
