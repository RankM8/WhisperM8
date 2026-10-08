import Foundation

// MARK: - ChatGPT-Abo-Transkription (GPT-Backend)
//
// Diktat-Anbieter „ChatGPT-Abo": Das Audio geht an den lokalen GPT-Proxy
// (`claude-code-proxy`, Route `/v1/audio/transcriptions`, nur mit
// `CCP_CODEX_TRANSCRIPTIONS_API=1`), der es mit dem ChatGPT-Login des
// GPT-Backends an den inoffiziellen Endpoint `chatgpt.com/backend-api/transcribe`
// weiterreicht.
//
// Direkt an den INSTANZ-Port, nie über den Mix-Router: der entscheidet nach dem
// JSON-Feld `model`; ein Multipart-Body hat keins und landete bei Anthropic.
//
// Konto = aktives GPT-Profil (wie der Router für Requests ohne Profil-Header).
// Ist das aktive Profil nicht angemeldet, gibt es einen klaren Fehler — kein
// stiller Rückfall auf main, damit vorhersehbar bleibt, welches Konto das Audio
// bekommt. Kein automatischer Rückfall auf Groq/OpenAI: Audio ginge sonst still
// an einen anderen Anbieter. Die Aufnahme ist bei jedem Fehler gesichert.

/// Abhängigkeiten als Closures (Repo-Konvention) — Defaults =
/// `ClaudeCodeProxyManager.shared` und die App-Einstellungen.
struct ChatGPTTranscriptionDependencies {
    /// Kill-Switch `chatGPTTranscriptionEnabled`.
    var isFeatureEnabled: () -> Bool
    /// `claudeGPTBackendEnabled` — ohne GPT-Backend kein Proxy-Prozess.
    var isBackendEnabled: () -> Bool
    /// Aktives GPT-Profil, `nil` = main. Liest eine Datei — nur off-main.
    var activeProfile: () -> String?
    /// Port der laufenden Instanz des Profils (`nil` = Instanz unbekannt).
    var knownPort: (String?) -> Int?
    /// Blockierend (Health-Probe, Startschleife) — nur off-main aufrufen.
    var ensureRunning: (String?) -> Result<Void, ClaudeCodeProxyError>
    /// Blockierend für main (Health-Probe) — nur off-main aufrufen.
    var instanceOrigin: (String?) -> ClaudeCodeProxyInstanceOrigin
    /// Version des aufgelösten Proxy-Binarys (für die Fehlermeldung).
    var binaryVersion: () -> String?
    /// Health-Probe für den Prewarm (blockierend).
    var isReachable: (Int) -> Bool
    var sessionProvider: (TimeInterval) -> URLSession

    static var live: ChatGPTTranscriptionDependencies {
        let manager = ClaudeCodeProxyManager.shared
        return ChatGPTTranscriptionDependencies(
            isFeatureEnabled: { AppPreferences.shared.isChatGPTTranscriptionEnabled },
            isBackendEnabled: { AppPreferences.shared.claudeGPTBackendEnabled },
            activeProfile: {
                // Profil-Kill-Switch aus → alles über main.
                guard AppPreferences.shared.isGPTAccountProfilesEnabled else { return nil }
                return GPTAccountProfiles().activeProfileNameOrNil()
            },
            knownPort: { manager.port(forProfile: $0) },
            ensureRunning: { manager.ensureRunning(profile: $0) },
            instanceOrigin: { manager.instanceOrigin(forProfile: $0) },
            binaryVersion: { manager.resolvedBinary()?.version },
            isReachable: { ClaudeCodeProxyManager.isReachable(port: $0) },
            sessionProvider: { MultipartTranscriptionClient.defaultSession(timeout: $0) }
        )
    }
}

// MARK: - Fehler

enum ChatGPTTranscriptionError: LocalizedError, Equatable {
    case featureDisabled
    case backendDisabled
    case profileNotLoggedIn(String)
    case proxyUnavailable(String)
    /// 401/403 vom Proxy selbst — Login fehlt oder Refresh gescheitert.
    case notAuthenticated
    /// 401/403 von chatgpt.com (`upstream_error`): der Proxy hatte einen
    /// gültigen Login (ein 401 wird vorher per Refresh wiederholt), ChatGPT hat
    /// trotzdem abgelehnt — meist vorübergehend (Live-Test 2026-10-08: einmal
    /// beim Kaltstart, danach 8 von 8 Erfolg). Kein „neu verbinden"-Rat.
    case upstreamRejected(statusCode: Int)
    /// 404 vom Fallback-Handler des Proxys: Route nicht registriert.
    case routeDisabled(origin: ClaudeCodeProxyInstanceOrigin, port: Int, version: String?)
    /// 404/410 von chatgpt.com (`upstream_error`) — Endpoint vermutlich weg.
    case endpointGone(statusCode: Int)
    /// 413 bzw. lokale Größenprüfung.
    case tooLarge
    /// 429 — `local` = Parallel-Limit des Proxys (4), sonst ChatGPT-Limit.
    case rateLimited(local: Bool)
    /// 400/415 und andere 4xx — Meldung des Proxys.
    case badRequest(String)
    /// 5xx.
    case upstreamUnavailable(statusCode: Int)
    /// Netzwerkfehler außer `.cancelled` (der geht unverändert durch).
    case network(URLError)

    static let minimumProxyVersionForRoute = "0.1.30"

    var errorDescription: String? {
        switch self {
        case .featureDisabled:
            return "ChatGPT-Abo-Transkription ist deaktiviert (Kill-Switch `chatGPTTranscriptionEnabled`)."
        case .backendDisabled:
            return "Für „ChatGPT-Abo“ muss das GPT-Backend aktiv sein (Einstellungen → GPT-Backend). Alternativ in den Transkriptions-Einstellungen Groq oder OpenAI wählen – die Aufnahme ist gesichert."
        case .profileNotLoggedIn(let name):
            return "Das aktive GPT-Konto „\(name)“ ist nicht angemeldet. Einstellungen → GPT-Backend → ChatGPT-Konten."
        case .proxyUnavailable(let reason):
            return "Der GPT-Proxy konnte nicht gestartet werden: \(reason)"
        case .notAuthenticated:
            return "Das GPT-Backend ist nicht bei ChatGPT angemeldet oder der Login ist abgelaufen. Einstellungen → GPT-Backend → „Mit ChatGPT-Konto verbinden“. (`codex login` reicht nicht – der Proxy hat einen eigenen Login.)"
        case .upstreamRejected(let statusCode):
            return "ChatGPT hat die Transkription abgewiesen (HTTP \(statusCode)) – meist vorübergehend, bitte erneut versuchen; die Aufnahme ist gesichert. Hält es an, den Login unter Einstellungen → GPT-Backend prüfen oder Groq/OpenAI wählen."
        case .routeDisabled(let origin, let port, let version):
            switch origin {
            case .external:
                return "Auf Port \(port) läuft ein GPT-Proxy, der nicht von WhisperM8 gestartet wurde und die Transkription nicht aktiviert hat. Starte ihn mit `CCP_CODEX_TRANSCRIPTIONS_API=1` neu oder beende ihn – dann startet WhisperM8 einen eigenen."
            case .selfStarted, .notRunning:
                let versionText = version.map { " (v\($0))" } ?? ""
                return "Der GPT-Proxy\(versionText) kennt den Transkriptions-Endpoint nicht (nötig ab v\(Self.minimumProxyVersionForRoute)). Ein Neustart von WhisperM8 aktualisiert ihn."
            }
        case .endpointGone(let statusCode):
            return "ChatGPT hat den inoffiziellen Transkriptions-Endpoint abgelehnt (HTTP \(statusCode)) – er ist möglicherweise weggefallen. Wechsle in den Einstellungen auf Groq oder OpenAI; die Aufnahme ist gesichert."
        case .tooLarge:
            return "Aufnahme zu groß für ChatGPT (max. 25 MB)."
        case .rateLimited(let local):
            return local
                ? "Zu viele gleichzeitige Transkriptionen über den GPT-Proxy – bitte gleich erneut versuchen."
                : "ChatGPT-Limit erreicht – später erneut versuchen oder anderen Anbieter wählen."
        case .badRequest(let message):
            return "ChatGPT-Transkription hat die Anfrage abgelehnt: \(message)"
        case .upstreamUnavailable(let statusCode):
            return "ChatGPT-Transkription ist gerade nicht erreichbar (HTTP \(statusCode))."
        case .network(let error):
            return "Netzwerkfehler bei der ChatGPT-Transkription: \(error.localizedDescription)"
        }
    }
}

// MARK: - Fehler-Mapping (pur)

enum ChatGPTTranscriptionErrorMapper {
    /// Fehler-JSON des Proxys. Transkriptions-Fehler sind OpenAI-förmig
    /// (`error.code`, `error.message`, `error.type`); der Fallback-Handler für
    /// unbekannte Routen antwortet Anthropic-förmig (`error.type: "not_found"`,
    /// kein `code`).
    struct ErrorBody: Equatable {
        var code: String?
        var type: String?
        var message: String?

        static func parse(_ body: String) -> ErrorBody {
            guard
                let data = body.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = object["error"] as? [String: Any]
            else { return ErrorBody() }
            return ErrorBody(
                code: error["code"] as? String,
                type: error["type"] as? String,
                message: error["message"] as? String
            )
        }
    }

    /// Fehler-Code, den der Proxy für eine von chatgpt.com abgelehnte Anfrage
    /// durchreicht (Status bleibt der des Upstreams).
    static let upstreamErrorCode = "upstream_error"
    static let localCapacityCode = "local_capacity_exceeded"

    /// Muss für diesen Status/Body die Herkunft der Instanz bestimmt werden?
    /// Nur bei einer fehlenden Route (404 ohne `upstream_error`) — die Abfrage
    /// kostet für main eine Health-Probe.
    static func needsInstanceOrigin(statusCode: Int, body: String) -> Bool {
        statusCode == 404 && ErrorBody.parse(body).code != upstreamErrorCode
    }

    /// Pur: Status + Fehler-JSON → Fehlerfall.
    static func map(
        statusCode: Int,
        body: String,
        origin: ClaudeCodeProxyInstanceOrigin,
        port: Int,
        version: String?
    ) -> ChatGPTTranscriptionError {
        let parsed = ErrorBody.parse(body)
        switch statusCode {
        case 401, 403:
            // Eigene Auth-Fehler des Proxys tragen `authentication_error` bzw.
            // `permission_error`; nur `upstream_error` kommt von chatgpt.com.
            if parsed.code == upstreamErrorCode {
                return .upstreamRejected(statusCode: statusCode)
            }
            return .notAuthenticated
        case 404:
            if parsed.code == upstreamErrorCode {
                return .endpointGone(statusCode: 404)
            }
            return .routeDisabled(origin: origin, port: port, version: version)
        case 410:
            return .endpointGone(statusCode: 410)
        case 413:
            return .tooLarge
        case 429:
            return .rateLimited(local: parsed.code == localCapacityCode)
        case 400..<500:
            return .badRequest(message(parsed, rawBody: body, statusCode: statusCode))
        default:
            return .upstreamUnavailable(statusCode: statusCode)
        }
    }

    private static func message(_ parsed: ErrorBody, rawBody: String, statusCode: Int) -> String {
        if let message = parsed.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        let trimmed = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "HTTP \(statusCode)" : String(trimmed.prefix(200))
    }
}

// MARK: - Service

final class ChatGPTSubscriptionTranscriptionService: TranscriptionServiceProtocol {
    private let dependencies: ChatGPTTranscriptionDependencies

    init(dependencies: ChatGPTTranscriptionDependencies = .live) {
        self.dependencies = dependencies
    }

    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval?) async throws -> String {
        // 1. Schalter prüfen — bevor irgendetwas im Netz oder am Proxy passiert.
        guard dependencies.isFeatureEnabled() else { throw ChatGPTTranscriptionError.featureDisabled }
        guard dependencies.isBackendEnabled() else { throw ChatGPTTranscriptionError.backendDisabled }

        let startedAt = Date()
        let deps = dependencies
        // 2. Profil (Dateizugriff) und Port off-main lesen.
        let (profile, initialPort) = await Self.offMain { () -> (String?, Int?) in
            let profile = deps.activeProfile()
            return (profile, deps.knownPort(profile))
        }
        let profileLabel = profile ?? GPTAccountProfiles.mainProfileName

        var bootstrapMs = 0
        var port: Int
        if let initialPort {
            port = initialPort
        } else {
            let bootstrapStart = Date()
            port = try await bootstrap(profile: profile)
            bootstrapMs = Self.milliseconds(since: bootstrapStart)
        }
        try Task.checkCancellation()

        do {
            let text: String
            do {
                text = try await send(audioURL: audioURL, language: language, audioDuration: audioDuration, port: port)
            } catch let error as URLError where error.code == .cannotConnectToHost {
                // 4. „Connection refused" kommt sofort und heißt: der Request
                // hat den Proxy nie erreicht — genau ein Start + ein Retry,
                // ohne Risiko eines doppelten Uploads.
                Logger.transcription.info(
                    "chatgpt_transcription_connect_refused port=\(port, privacy: .public) profile=\(profileLabel, privacy: .public) — starte Proxy und versuche einmal erneut"
                )
                let bootstrapStart = Date()
                port = try await bootstrap(profile: profile)
                bootstrapMs += Self.milliseconds(since: bootstrapStart)
                try Task.checkCancellation()
                do {
                    text = try await send(audioURL: audioURL, language: language, audioDuration: audioDuration, port: port)
                } catch let retryError as URLError where retryError.code == .cannotConnectToHost {
                    throw ChatGPTTranscriptionError.proxyUnavailable(
                        "Keine Verbindung zu 127.0.0.1:\(port) (\(retryError.localizedDescription))"
                    )
                }
            }
            Logger.transcription.info(
                "chatgpt_transcription status=200 ms=\(Self.milliseconds(since: startedAt), privacy: .public) profile=\(profileLabel, privacy: .public) bootstrap_ms=\(bootstrapMs, privacy: .public)"
            )
            return text
        } catch {
            let mapped = await mapFailure(error, profile: profile, port: port)
            Logger.transcription.info(
                "chatgpt_transcription status=\(Self.statusLabel(for: error), privacy: .public) ms=\(Self.milliseconds(since: startedAt), privacy: .public) profile=\(profileLabel, privacy: .public) bootstrap_ms=\(bootstrapMs, privacy: .public) error=\(Self.errorLabel(for: mapped), privacy: .public)"
            )
            throw mapped
        }
    }

    // MARK: Ablauf-Bausteine

    /// Proxy für das Profil hochfahren (blockierend, deshalb off-main) und
    /// den Port neu lesen.
    private func bootstrap(profile: String?) async throws -> Int {
        let deps = dependencies
        let (result, port) = await Self.offMain { () -> (Result<Void, ClaudeCodeProxyError>, Int?) in
            let result = deps.ensureRunning(profile)
            return (result, deps.knownPort(profile))
        }
        switch result {
        case .failure(.profileNotLoggedIn(let name)):
            throw ChatGPTTranscriptionError.profileNotLoggedIn(name)
        case .failure(let error):
            throw ChatGPTTranscriptionError.proxyUnavailable(error.localizedDescription)
        case .success:
            guard let port else {
                throw ChatGPTTranscriptionError.proxyUnavailable("Port der Proxy-Instanz unbekannt.")
            }
            return port
        }
    }

    private func send(
        audioURL: URL,
        language: String?,
        audioDuration: TimeInterval?,
        port: Int
    ) async throws -> String {
        // Kein API-Key: der Proxy authentifiziert selbst. Die Antwort trägt
        // neben `text` weitere Felder (`asset_pointer` …) — dekodiert wird
        // nur `text`.
        let client = MultipartTranscriptionClient(
            apiKey: nil,
            config: .chatGPTProxy(port: port),
            sessionProvider: dependencies.sessionProvider
        )
        return try await client.transcribe(audioURL: audioURL, language: language, audioDuration: audioDuration)
    }

    /// 5./6. Fehler übersetzen. Abbruch (`CancellationError`,
    /// `URLError.cancelled`) geht UNVERÄNDERT durch — der Cancel/ESC-Pfad des
    /// Coordinators hängt daran.
    private func mapFailure(_ error: Error, profile: String?, port: Int) async -> Error {
        switch error {
        case is CancellationError:
            return error
        case let urlError as URLError where urlError.code == .cancelled:
            return error
        case let urlError as URLError:
            return ChatGPTTranscriptionError.network(urlError)
        case is ChatGPTTranscriptionError:
            return error
        case TranscriptionError.fileTooLarge:
            return ChatGPTTranscriptionError.tooLarge
        case TranscriptionError.apiError(let statusCode, let body):
            var origin: ClaudeCodeProxyInstanceOrigin = .notRunning
            var version: String?
            if ChatGPTTranscriptionErrorMapper.needsInstanceOrigin(statusCode: statusCode, body: body) {
                let deps = dependencies
                (origin, version) = await Self.offMain { (deps.instanceOrigin(profile), deps.binaryVersion()) }
            }
            return ChatGPTTranscriptionErrorMapper.map(
                statusCode: statusCode,
                body: body,
                origin: origin,
                port: port,
                version: version
            )
        default:
            return error
        }
    }

    // MARK: Hilfen

    /// Blockierende Arbeit auf einer globalen Queue statt auf dem Aufrufer-
    /// Thread (der kann der Main Actor sein).
    static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private static func statusLabel(for error: Error) -> String {
        if case TranscriptionError.apiError(let statusCode, _) = error { return String(statusCode) }
        if error is URLError { return "url_error" }
        return "none"
    }

    /// Kurzer, inhaltsfreier Fehlername fürs Log (nie Text oder Audio).
    private static func errorLabel(for error: Error) -> String {
        guard let error = error as? ChatGPTTranscriptionError else {
            return String(describing: type(of: error))
        }
        switch error {
        case .featureDisabled: return "feature_disabled"
        case .backendDisabled: return "backend_disabled"
        case .profileNotLoggedIn: return "profile_not_logged_in"
        case .proxyUnavailable: return "proxy_unavailable"
        case .notAuthenticated: return "not_authenticated"
        case .upstreamRejected(let statusCode): return "upstream_rejected_\(statusCode)"
        case .routeDisabled(let origin, _, _): return "route_disabled_\(origin)"
        case .endpointGone: return "endpoint_gone"
        case .tooLarge: return "too_large"
        case .rateLimited(let local): return local ? "rate_limited_local" : "rate_limited"
        case .badRequest: return "bad_request"
        case .upstreamUnavailable: return "upstream_unavailable"
        case .network(let urlError): return "network_\(urlError.code.rawValue)"
        }
    }
}

// MARK: - Prewarm

/// Fährt beim Aufnahmestart den Proxy des aktiven Profils hoch, damit der
/// Upload nach dem Stopp nicht auf den Start warten muss. Läuft komplett im
/// Hintergrund (das Profil wird erst dort gelesen — Dateizugriff) und
/// höchstens einmal gleichzeitig.
enum ChatGPTTranscriptionWarmup {
    private static let lock = NSLock()
    private static var isRunning = false

    static func prewarmIfNeeded(
        provider: TranscriptionProvider,
        dependencies: ChatGPTTranscriptionDependencies = .live,
        queue: DispatchQueue = .global(qos: .utility),
        completion: (() -> Void)? = nil
    ) {
        guard provider == .chatgpt,
              dependencies.isFeatureEnabled(),
              dependencies.isBackendEnabled() else {
            completion?()
            return
        }
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            completion?()
            return
        }
        isRunning = true
        lock.unlock()

        queue.async {
            defer {
                lock.lock()
                isRunning = false
                lock.unlock()
                completion?()
            }
            let profile = dependencies.activeProfile()
            if let port = dependencies.knownPort(profile), dependencies.isReachable(port) {
                return
            }
            if case .failure(let error) = dependencies.ensureRunning(profile) {
                Logger.transcription.info(
                    "chatgpt_transcription_prewarm_failed profile=\(profile ?? GPTAccountProfiles.mainProfileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
