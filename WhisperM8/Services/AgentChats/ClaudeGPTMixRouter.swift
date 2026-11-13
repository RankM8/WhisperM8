import Foundation
import Network

enum ClaudeGPTMixRouterError: LocalizedError, Equatable {
    case invalidPort(Int)
    case alreadyRunning(port: Int)
    case listenerFailed(String)
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Ungueltiger GPT-Router-Port: \(port)."
        case .alreadyRunning(let port):
            return "Der GPT-Router laeuft bereits auf Port \(port)."
        case .listenerFailed(let reason):
            return "Der GPT-Router konnte nicht gestartet werden: \(reason)"
        case .startTimedOut:
            return "Der GPT-Router wurde nicht rechtzeitig bereit."
        }
    }
}

/// Kleiner loopback-only HTTP/1.1-Router fuer Claude-/GPT-Mischsessions.
/// Client-Verbindungen verarbeiten bewusst genau einen Request und antworten
/// mit `Connection: close`; Upstream-Antworten werden trotzdem sofort als
/// HTTP-Chunks gestreamt, damit SSE nicht bis zum Response-Ende puffert.
final class ClaudeGPTMixRouter {
    static let shared: ClaudeGPTMixRouter = {
        let router = ClaudeGPTMixRouter()
        // LR-GPT-001: Das produktive Router-Objekt verlangt fuer GPT-Modelle das
        // lokale Token (Kill-Switch `gptRouterAuthEnabled`). Frisch erzeugte
        // Router (Tests) erzwingen nichts.
        router.authTokenResolver = {
            guard AppPreferences.shared.isGPTRouterAuthEnabled else { return nil }
            return ClaudeGPTRouterToken.shared.current()
        }
        return router
    }()

    enum Upstream: String, Equatable {
        case codexProxy = "codex-proxy"
        case anthropic
    }

    struct HTTPHeader: Equatable {
        var name: String
        var value: String
    }

    struct HTTPRequestHead: Equatable {
        var method: String
        var target: String
        var version: String
        var headers: [HTTPHeader]
        var contentLength: Int
    }

    enum HTTPRequestParseError: Error, Equatable {
        case badRequest
        case lengthRequired
    }

    struct UpstreamErrorDiagnostics: Equatable {
        var errorType: String?
        var errorCode: String?
        var isContextLimit: Bool
        var capturedBytes: Int
    }

    private enum ListenerStartAction {
        case complete(Result<Void, Error>)
        case start(NWListener, generation: UInt64)
    }

    typealias UpstreamURLResolver = (Upstream) -> URL
    typealias GPTContextWindowResolver = () -> Int

    private static let hopByHopHeaderNames: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "host",
        "content-length",
    ]
    static let maximumHeaderBytes = 64 * 1_024
    static let maximumBodyBytes = 64 * 1_024 * 1_024
    static let maximumDiagnosticErrorBytes = 64 * 1_024

    private let upstreamURLResolver: UpstreamURLResolver
    private let gptContextWindowResolver: GPTContextWindowResolver

    // MARK: GPT-Konto-Profile (Routing pro Session)

    /// Request-Header, mit dem eine Session ihr GPT-Konto nennt. Gesetzt vom
    /// `AgentCommandBuilder` ueber `ANTHROPIC_CUSTOM_HEADERS`; wird vor JEDEM
    /// Upstream entfernt (Anthropic soll ihn nie sehen).
    static let profileHeaderName = "X-WhisperM8-GPT-Profile"

    /// Erwartetes lokales Token fuer Requests an das GPT-Backend (LR-GPT-001);
    /// `nil` = nicht erzwingen. Nur der Codex-Upstream ist geschuetzt — `claude-*`
    /// geht mit dem eigenen Anthropic-Login des Aufrufers durch und verbraucht
    /// kein GPT-Konto. Der Token-Header wird vor JEDEM Upstream entfernt.
    ///
    /// Abwaegung Altbestand: Prozesse, die vor dem Update mit Router-URL, aber
    /// ohne Token gestartet wurden (Hintergrund-Agents des Supervisors), bekommen
    /// fuer GPT-Modelle eine erklaerende 401 bis zum Neustart. PTY-Chats sind
    /// Kinder der App und starten nach jedem App-Neustart ohnehin neu (mit Token).
    var authTokenResolver: () -> String? = { nil }

    /// Kill-Switch: aus → Header ignorieren, alles laeuft ueber main.
    var profilesEnabledResolver: () -> Bool = { AppPreferences.shared.isGPTAccountProfilesEnabled }

    /// Ziel-URL der Proxy-Instanz eines Zusatzprofils; `nil` = laeuft nicht.
    var codexProxyURLResolver: (String) -> URL? = { profile in
        guard let port = ClaudeCodeProxyManager.shared.port(forProfile: profile) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Profil fuer Requests OHNE Header (Sessions von vor dem Update, extern
    /// gestartete Prozesse mit Router-URL): das aktive Profil, nicht stur
    /// main — sonst liefe ein alter Chat nach dem Kontowechsel weiter gegen
    /// das erschoepfte Konto (Entscheidung E4 im Plan).
    var activeProfileResolver: () -> String? = { GPTAccountProfiles().activeProfileNameOrNil() }

    /// Fire-and-forget-Start einer fehlenden Instanz, damit der naechste
    /// Request durchkommt. Laeuft off-queue; der aktuelle Request bekommt 503.
    var profileInstanceStarter: (String) -> Void = { profile in
        ClaudeCodeProxyManager.shared.startInstanceInBackground(profile: profile)
    }

    /// Profilname aus dem Request-Header: „main" (ausdruecklich das Hauptkonto,
    /// kontostabil auch bei aktivem Zusatzprofil) oder ein gueltiger Profilname.
    /// Alles andere gilt als nicht gesetzt → E4-Fallback auf das aktive Profil.
    static func profileName(in headers: [HTTPHeader]) -> String? {
        guard let header = headers.first(where: {
            $0.name.caseInsensitiveCompare(profileHeaderName) == .orderedSame
        }) else {
            return nil
        }
        let value = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == GPTAccountProfiles.mainProfileName { return value }
        guard GPTAccountProfiles.isValidProfileName(value) else { return nil }
        return value
    }

    /// Wurde das Profil in diesem App-Lauf zum Hauptkonto? Dann gilt sein
    /// (beim Spawn eingefrorener) Header als main — der Grant liegt jetzt dort.
    var promotedProfileResolver: (String) -> Bool = { GPTPromotedProfiles.shared.wasPromoted($0) }

    /// Ist das Profil angemeldet (eigene Auth-Datei)? Entscheidet im 503-Pfad,
    /// ob ein Start ueberhaupt Sinn hat — sonst versprach die Antwort „startet
    /// gleich" fuer ein abgemeldetes Konto in Endlosschleife.
    var profileLoggedInResolver: (String) -> Bool = { profile in
        GPTAccountProfiles().profile(named: profile).isLoggedIn
    }

    /// Snapshot der Profil-Routing-Closures fuer eine Client-Verbindung —
    /// beim Annehmen der Verbindung gezogen, damit Tests die Resolver vor dem
    /// Start setzen koennen und die Verbindung keinen Router-Backref braucht.
    struct ProfileRouting {
        var isEnabled: () -> Bool
        var proxyURL: (String) -> URL?
        var activeProfile: () -> String?
        var startInstance: (String) -> Void
        var isLoggedIn: (String) -> Bool
        var wasPromotedToMain: (String) -> Bool = { _ in false }
    }

    private func makeProfileRouting() -> ProfileRouting {
        ProfileRouting(
            isEnabled: profilesEnabledResolver,
            proxyURL: codexProxyURLResolver,
            activeProfile: activeProfileResolver,
            startInstance: profileInstanceStarter,
            isLoggedIn: profileLoggedInResolver,
            wasPromotedToMain: promotedProfileResolver
        )
    }

    static func anthropicAuthErrorBody(message: String) -> Data {
        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": "authentication_error", "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"type":"error","error":{"type":"authentication_error","message":"Unauthorized."}}"#.utf8)
    }

    /// Anthropic-foermiger `api_error` — fuer Zustaende, die kein Fehler des
    /// Requests sind (Instanz des Kontos nicht erreichbar).
    static func anthropicAPIErrorBody(message: String) -> Data {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": "api_error",
                "message": message,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"type":"error","error":{"type":"api_error","message":"GPT backend unavailable."}}"#.utf8)
    }
    /// Worauf der Router lauscht. `.network` ist der Router in der App wie
    /// bisher (`NWListener`); `.bsdSockets` nutzt der Router-Dienst, weil nur
    /// ein BSD-Socket an die nächste Generation übergeben werden kann.
    enum ListenerKind: Equatable {
        case network
        case bsdSockets
    }

    let listenerKind: ListenerKind
    private let listenerQueue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.listener")
    let lifecycleQueue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.lifecycle")
    private var listener: NWListener?
    /// Nur bei `.bsdSockets` (siehe `+SocketListener`). Zugriff auf `lifecycleQueue`.
    var socketListener: ClaudeGPTRouterSocketListener?
    var requestedPort: Int?
    var boundPortStorage: Int?
    var connections: [UUID: ClientConnection] = [:]
    /// Letzte angenommene oder beendete Verbindung (Leerlauf-Frist des
    /// Router-Dienstes: auch kurze Anfragen zählen). Zugriff auf `lifecycleQueue`.
    var lastActivityAtStorage = Date()

    var lastActivityAt: Date {
        lifecycleQueue.sync { lastActivityAtStorage }
    }
    var generation: UInt64 = 0

    init(
        upstreamURLResolver: @escaping UpstreamURLResolver = { upstream in
            switch upstream {
            case .codexProxy:
                return URL(
                    string: "http://127.0.0.1:\(AppPreferences.shared.claudeGPTBackendPort)"
                )!
            case .anthropic:
                return URL(string: "https://api.anthropic.com")!
            }
        },
        gptContextWindowResolver: @escaping GPTContextWindowResolver = {
            AppPreferences.shared.claudeGPTContextWindow
        },
        listenerKind: ListenerKind = .network
    ) {
        self.upstreamURLResolver = upstreamURLResolver
        self.gptContextWindowResolver = gptContextWindowResolver
        self.listenerKind = listenerKind
    }

    convenience init(
        codexProxyURL: URL,
        anthropicURL: URL,
        gptContextWindow: Int = AppPreferences.claudeGPTDefaultContextWindow,
        listenerKind: ListenerKind = .network
    ) {
        self.init(
            upstreamURLResolver: { upstream in
                switch upstream {
                case .codexProxy: return codexProxyURL
                case .anthropic: return anthropicURL
                }
            },
            gptContextWindowResolver: { gptContextWindow },
            listenerKind: listenerKind
        )
        // Feste Upstream-URLs = Test-/Sonderbetrieb ohne Konto-Profile. Die
        // Resolver bleiben setzbar; ohne ausdrueckliche Zuweisung darf kein
        // Test am echten `~/.gpt-profiles/.active` der Maschine haengen.
        profilesEnabledResolver = { false }
        activeProfileResolver = { nil }
        codexProxyURLResolver = { _ in nil }
        profileInstanceStarter = { _ in }
        profileLoggedInResolver = { _ in true }
        promotedProfileResolver = { _ in false }
    }

    var listeningPort: Int? {
        lifecycleQueue.sync { boundPortStorage }
    }

    @discardableResult
    func start(port: Int) -> Result<Void, Error> {
        if listenerKind == .bsdSockets {
            return startSocketListener(port: port)
        }
        guard (0...65_535).contains(port), let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failure(ClaudeGPTMixRouterError.invalidPort(port))
        }

        let action: ListenerStartAction = lifecycleQueue.sync {
            if listener != nil {
                let runningPort = requestedPort ?? port
                return .complete(
                    runningPort == port
                        ? .success(())
                        : .failure(ClaudeGPTMixRouterError.alreadyRunning(port: runningPort))
                )
            }

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: networkPort
            )

            do {
                let newListener = try NWListener(using: parameters)
                generation &+= 1
                listener = newListener
                requestedPort = port
                return .start(newListener, generation: generation)
            } catch {
                return .complete(.failure(
                    ClaudeGPTMixRouterError.listenerFailed(error.localizedDescription)
                ))
            }
        }

        guard case .start(let newListener, let startGeneration) = action else {
            guard case .complete(let result) = action else {
                return .failure(ClaudeGPTMixRouterError.startTimedOut)
            }
            return result
        }

        let readySemaphore = DispatchSemaphore(value: 0)
        let startupLock = NSLock()
        var startupResult: Result<Void, Error>?

        func completeStartup(_ result: Result<Void, Error>) {
            startupLock.lock()
            guard startupResult == nil else {
                startupLock.unlock()
                return
            }
            startupResult = result
            startupLock.unlock()
            readySemaphore.signal()
        }

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self else {
                completeStartup(.failure(
                    ClaudeGPTMixRouterError.listenerFailed("Router wurde freigegeben.")
                ))
                return
            }
            self.lifecycleQueue.async {
                let isCurrent = self.generation == startGeneration
                    && self.listener === newListener
                switch state {
                case .ready where isCurrent:
                    self.boundPortStorage = newListener?.port.map { Int($0.rawValue) }
                    completeStartup(.success(()))
                case .ready:
                    completeStartup(.failure(
                        ClaudeGPTMixRouterError.listenerFailed("Listener wurde ersetzt.")
                    ))
                case .failed(let error):
                    if isCurrent {
                        self.detachFailedListener()
                    }
                    completeStartup(.failure(
                        ClaudeGPTMixRouterError.listenerFailed(error.localizedDescription)
                    ))
                case .cancelled:
                    if isCurrent {
                        self.detachFailedListener()
                    }
                    completeStartup(.failure(
                        ClaudeGPTMixRouterError.listenerFailed("Listener wurde beendet.")
                    ))
                default:
                    break
                }
            }
        }
        newListener.newConnectionHandler = { [weak self, weak newListener] connection in
            guard self?.accept(
                connection,
                from: newListener,
                generation: startGeneration
            ) == true else {
                connection.cancel()
                return
            }
        }
        newListener.start(queue: listenerQueue)

        guard readySemaphore.wait(timeout: .now() + 3) == .success else {
            stop(generation: startGeneration)
            return .failure(ClaudeGPTMixRouterError.startTimedOut)
        }

        startupLock.lock()
        let result = startupResult ?? .failure(ClaudeGPTMixRouterError.startTimedOut)
        startupLock.unlock()
        if case .failure = result {
            stop(generation: startGeneration)
        }
        return result
    }

    func stop() {
        let stopped = lifecycleQueue.sync { detachCurrentListener() }

        stopped.listener?.cancel()
        stopped.socketListener?.close()
        stopped.connections.forEach { $0.cancel() }
    }

    private func stop(generation expectedGeneration: UInt64) {
        let stopped: DetachedListener? = lifecycleQueue.sync {
            guard generation == expectedGeneration else { return nil }
            return detachCurrentListener()
        }

        stopped?.listener?.cancel()
        stopped?.socketListener?.close()
        stopped?.connections.forEach { $0.cancel() }
    }

    struct DetachedListener {
        var listener: NWListener?
        var socketListener: ClaudeGPTRouterSocketListener?
        var connections: [ClientConnection]
    }

    /// Nur auf `lifecycleQueue` aufrufen. Die Generation verhindert, dass
    /// ein alter Startfehler einen inzwischen neu gestarteten Listener stoppt.
    func detachCurrentListener() -> DetachedListener {
        generation &+= 1
        let stoppedListener = listener
        listener = nil
        let stoppedSocketListener = socketListener
        socketListener = nil
        requestedPort = nil
        boundPortStorage = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        return DetachedListener(
            listener: stoppedListener,
            socketListener: stoppedSocketListener,
            connections: activeConnections
        )
    }

    /// Nur auf `lifecycleQueue` aufrufen. Bei einem asynchronen Listenerfehler
    /// werden auch alle bereits angenommenen Verbindungen idempotent beendet.
    private func detachFailedListener() {
        let stopped = detachCurrentListener()
        stopped.connections.forEach { $0.cancel() }
    }

    /// `model` des Request-Bodys: Byte-Scan der obersten Objektebene, nur bei
    /// Unsicherheit voller Parse (LR-GPT-008, siehe `+RequestBody`).
    static func model(in body: Data) -> String? {
        switch scanTopLevelModel(in: body) {
        case .found(let model):
            return model
        case .absent:
            return nil
        case .unsure:
            guard
                let object = parseBody(body),
                let dictionary = object as? [String: Any],
                let model = dictionary["model"] as? String
            else {
                return nil
            }
            return model
        }
    }

    /// Ersetzt `auto`, `gpt-auto` (jeweils optional `-fast`, `[1m]`) im
    /// Request-Body durch den kanonischen Frontier-Alias. Alle anderen
    /// Bodies bleiben byte-identisch.
    static func resolvingAutoModel(in body: Data) -> Data {
        resolvingAutoModel(in: body, requestedModel: model(in: body)).body
    }

    struct ToolSchemaSanitization: Equatable {
        var body: Data
        var removedPatterns: Int
        var affectedTools: [String]
    }

    /// true, wenn ein JSON-Schema-`pattern` Konstrukte enthält, die die
    /// Schema-Validierung des Codex-Backends nicht kennt (Unicode-Klassen
    /// `\p{…}`/`\P{…}`). ASCII-Patterns bleiben unangetastet.
    static func isUnsupportedUpstreamPattern(_ pattern: String) -> Bool {
        pattern.contains("\\p{") || pattern.contains("\\P{")
    }

    /// Entfernt in `tools[*].input_schema` rekursiv jedes `pattern`, das das
    /// Backend ablehnen würde. Bodies ohne Befund bleiben byte-identisch.
    static func sanitizingToolSchemas(in body: Data) -> ToolSchemaSanitization {
        let untouched = ToolSchemaSanitization(body: body, removedPatterns: 0, affectedTools: [])
        // Rohtext-Vorfilter: ohne Bytefolge eines Unicode-Klassen-Patterns ist
        // nichts zu entfernen — dann kein Parse (LR-GPT-008).
        guard mayContainUnsupportedPattern(body),
              let object = parseBody(body),
              var dictionary = object as? [String: Any],
              var tools = dictionary["tools"] as? [[String: Any]] else {
            return untouched
        }
        var removed = 0
        var affected: [String] = []
        for index in tools.indices {
            guard let schema = tools[index]["input_schema"] else { continue }
            var count = 0
            let cleaned = strippingUnsupportedPatterns(schema, removed: &count)
            guard count > 0 else { continue }
            tools[index]["input_schema"] = cleaned
            removed += count
            affected.append(tools[index]["name"] as? String ?? "#\(index)")
        }
        guard removed > 0 else { return untouched }
        dictionary["tools"] = tools
        guard let rewritten = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return untouched
        }
        return ToolSchemaSanitization(body: rewritten, removedPatterns: removed, affectedTools: affected)
    }

    private static func strippingUnsupportedPatterns(_ node: Any, removed: inout Int) -> Any {
        if var dictionary = node as? [String: Any] {
            if let pattern = dictionary["pattern"] as? String, isUnsupportedUpstreamPattern(pattern) {
                dictionary.removeValue(forKey: "pattern")
                removed += 1
            }
            for (key, value) in dictionary {
                dictionary[key] = strippingUnsupportedPatterns(value, removed: &removed)
            }
            return dictionary
        }
        if let array = node as? [Any] {
            return array.map { strippingUnsupportedPatterns($0, removed: &removed) }
        }
        return node
    }

    static func upstream(for body: Data) -> Upstream {
        upstream(forModel: model(in: body))
    }

    static func upstream(forModel model: String?) -> Upstream {
        guard let model else { return .anthropic }
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("gpt-") ? .codexProxy : .anthropic
    }

    static func hasUnsupportedContentEncoding(_ headers: [HTTPHeader]) -> Bool {
        headers
            .filter { $0.name.caseInsensitiveCompare("content-encoding") == .orderedSame }
            .flatMap { $0.value.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { !$0.isEmpty && $0 != "identity" }
    }

    static func isEventStreamContentType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let mediaType = rawValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "text/event-stream"
    }

    /// Direkte `/model`-Eingaben muessen bereits der kanonischen, kapazitaets-
    /// kompatiblen Allowlist entsprechen. Dadurch fallen Grossschreibung,
    /// Whitespace, `[1m]`, alte 128k-Modelle und unbekannte GPT-IDs weder in den
    /// Anthropic-Zweig noch unter ein zu grosses gemeinsames MAX_CONTEXT.
    static func gptModelValidationErrorResponse(
        for model: String?,
        contextWindow: Int
    ) -> Data? {
        guard let model else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("gpt-") else { return nil }
        // `canonicalGPTModel` normalisiert nur (Lowercase, `[1m]`) und prueft die
        // Allowlist NICHT — fuer jedes `gpt-`-Praefix kommt ein Wert zurueck.
        // Ohne den zweiten Guard fiel eine unbekannte Basis erst in die
        // Kapazitaetspruefung und bekam beim 900k-Profil die Profilmeldung:
        // ein Tippfehler im Modellnamen las sich dann als Kontextfensterproblem.
        // Die Basis-Pruefung laeuft absichtlich VOR der Kanonik-Meldung — sonst
        // riete die Antwort zum Retry mit einer weiterhin ungueltigen ID.
        guard let canonical = ClaudeGPTModelAlias.canonicalGPTModel(trimmed),
              ClaudeGPTModelAlias.maximumContextWindow(for: canonical) != nil else {
            return anthropicInvalidRequestBody(message: "Invalid GPT model identifier.")
        }

        if trimmed != canonical {
            return anthropicInvalidRequestBody(
                message: "Non-canonical GPT model identifier. Use \(canonical) and retry."
            )
        }
        guard ClaudeGPTModelAlias.isSupportedCanonicalModel(
            canonical,
            contextWindow: contextWindow
        ) else {
            let message: String
            if contextWindow > ClaudeGPTModelAlias.maximumConfigurableContextWindow {
                message = "The configured GPT context window exceeds the largest verified profile of \(ClaudeGPTModelAlias.maximumConfigurableContextWindow) tokens. Reduce the setting and retry."
            } else if contextWindow > ClaudeGPTModelAlias.maximumKnownSharedContextWindow {
                message = "The extended 900k context profile is available only for 1M-class models per the Codex catalog: \(ClaudeGPTModelAlias.supportedModelsSummary(contextWindow: contextWindow)). Switch to one of these models or select the standard 272k profile and retry."
            } else {
                message = "Unsupported GPT model for the configured context profile. Supported models per the Codex catalog: \(ClaudeGPTModelAlias.supportedModelsSummary(contextWindow: contextWindow)). Models with a priority tier optionally support -fast."
            }
            return anthropicInvalidRequestBody(message: message)
        }
        return nil
    }

    static func anthropicInvalidRequestBody(message: String) -> Data {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": "invalid_request_error",
                "message": message,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Invalid request."}}"#.utf8)
    }

    /// Extrahiert aus echten HTTP-4xx-Antworten nur datenschutzarme Metadaten.
    /// Der freie Message-Text wird zur Klassifikation gelesen, aber nie geloggt.
    /// Der beobachtete 200-SSE-Synthetic-Fehler wird separat nur in einem
    /// begrenzten Prefix untersucht; normale Streams gehen ab dem ersten
    /// semantischen Event unveraendert in den Pass-through.
    static func upstreamErrorDiagnostics(from body: Data) -> UpstreamErrorDiagnostics {
        let object = try? JSONSerialization.jsonObject(with: body)
        let root = object as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let errorType = safeErrorIdentifier(error?["type"])
        let errorCode = safeErrorIdentifier(error?["code"])
        let message = (error?["message"] as? String)?.lowercased() ?? ""
        let classifier = [errorType, errorCode, message]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let isContextLimit = classifier.contains("context_length")
            || classifier.contains("context window")
            || classifier.contains("maximum context")
            || classifier.contains("prompt is too long")

        return UpstreamErrorDiagnostics(
            errorType: errorType,
            errorCode: errorCode,
            isContextLimit: isContextLimit,
            capturedBytes: body.count
        )
    }

    private static func safeErrorIdentifier(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    static func filteredHeaders(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        let connectionTokens = Set(headers
            .filter { $0.name.caseInsensitiveCompare("connection") == .orderedSame }
            .flatMap { header in
                header.value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            }
            .filter { !$0.isEmpty })
        let blockedNames = hopByHopHeaderNames.union(connectionTokens)
        return headers.filter { !blockedNames.contains($0.name.lowercased()) }
    }

    /// Header fuer die Weitergabe der Upstream-Antwort an den Client:
    /// Hop-by-Hop-Header raus, und Content-Encoding ebenfalls — URLSession
    /// hat den Body bereits transparent dekodiert (der Upstream-Request geht
    /// ohne Client-Accept-Encoding raus, URLSession verhandelt selbst). Der
    /// Header wuerde den Client sonst Klartext entpacken lassen.
    static func responseHeaders(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        filteredHeaders(headers).filter {
            $0.name.caseInsensitiveCompare("content-encoding") != .orderedSame
        }
    }

    static func upstreamHeaders(
        from headers: [HTTPHeader],
        upstream: Upstream,
        host: String,
        bodyLength: Int
    ) -> [HTTPHeader] {
        var result = filteredHeaders(headers)
        // Der Konto-Header ist ein reines Router-Signal — weder Anthropic noch
        // der Proxy bekommen ihn zu sehen.
        result.removeAll {
            $0.name.caseInsensitiveCompare(profileHeaderName) == .orderedSame
        }
        result.removeAll {
            $0.name.caseInsensitiveCompare(ClaudeGPTRouterToken.headerName) == .orderedSame
        }
        if upstream == .codexProxy {
            result.removeAll { header in
                let name = header.name.lowercased()
                return name == "authorization"
                    || name == "x-api-key"
                    || name.hasPrefix("anthropic-")
            }
        }
        // Accept-Encoding des Clients wird NICHT weitergereicht: URLSession
        // verhandelt die Kompression selbst und dekomprimiert transparent —
        // in der Praxis auch dann, wenn der Request einen eigenen
        // Accept-Encoding-Header traegt. Der Client bekaeme sonst Klartext
        // mit weitergereichtem "Content-Encoding: gzip" und scheitert beim
        // Entpacken (ZlibError). Gegenstueck: `responseHeaders` entfernt
        // Content-Encoding aus der Antwort.
        result.removeAll {
            $0.name.caseInsensitiveCompare("accept-encoding") == .orderedSame
        }
        result.append(HTTPHeader(name: "Host", value: host))
        if bodyLength > 0 {
            result.append(HTTPHeader(name: "Content-Length", value: String(bodyLength)))
        }
        return result
    }

    static func parseRequestHead(_ data: Data) -> Result<HTTPRequestHead, HTTPRequestParseError> {
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.badRequest)
        }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        guard let requestLine = lines.first else {
            return .failure(.badRequest)
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard
            requestParts.count == 3,
            !requestParts[0].isEmpty,
            requestParts[1].hasPrefix("/"),
            !requestParts[1].hasPrefix("//"),
            requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0"
        else {
            return .failure(.badRequest)
        }

        var headers: [HTTPHeader] = []
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return .failure(.badRequest)
            }
            let name = String(line[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure(.badRequest) }
            headers.append(HTTPHeader(name: name, value: value))
        }

        if headers.contains(where: {
            $0.name.caseInsensitiveCompare("transfer-encoding") == .orderedSame
                && !$0.value.isEmpty
        }) {
            return .failure(.lengthRequired)
        }

        let contentLengthValues = headers
            .filter { $0.name.caseInsensitiveCompare("content-length") == .orderedSame }
            .map(\.value)
        let parsedLengths = contentLengthValues.compactMap(Int.init)
        guard
            parsedLengths.count == contentLengthValues.count,
            parsedLengths.allSatisfy({ $0 >= 0 }),
            Set(parsedLengths).count <= 1
        else {
            return .failure(.badRequest)
        }

        return .success(HTTPRequestHead(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            version: String(requestParts[2]),
            headers: headers,
            contentLength: parsedLengths.first ?? 0
        ))
    }

    private func accept(
        _ connection: NWConnection,
        from sourceListener: NWListener?,
        generation expectedGeneration: UInt64
    ) -> Bool {
        accept(transport: ClaudeGPTRouterNWTransport(connection)) {
            self.generation == expectedGeneration && self.listener === sourceListener
        }
    }

    /// Legt die Client-Verbindung an, wenn `isCurrent` (auf `lifecycleQueue`
    /// geprüft) den Lauscher noch als aktuell bestätigt.
    func accept(
        transport: ClaudeGPTRouterClientTransport,
        isCurrent: () -> Bool
    ) -> Bool {
        let id = UUID()
        let client: ClientConnection? = lifecycleQueue.sync {
            guard isCurrent() else {
                return nil
            }
            let client = ClientConnection(
                connection: transport,
                upstreamURLResolver: upstreamURLResolver,
                gptContextWindowResolver: gptContextWindowResolver,
                profileRouting: makeProfileRouting(),
                authTokenResolver: authTokenResolver,
                onFinish: { [weak self] in self?.removeConnection(id: id) }
            )
            connections[id] = client
            lastActivityAtStorage = Date()
            return client
        }
        guard let client else { return false }
        client.start()
        return true
    }

    func removeConnection(id: UUID) {
        lifecycleQueue.async { [weak self] in
            self?.connections.removeValue(forKey: id)
            self?.lastActivityAtStorage = Date()
        }
    }
}

enum SyntheticOverflowProbeBudget {
    private static let lock = NSLock()
    private static var active = 0
    static let maximumActive = 64

    static func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < maximumActive else { return false }
        active += 1
        return true
    }

    static func release() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }

    static func resetForTesting() {
        lock.lock()
        active = 0
        lock.unlock()
    }
}
