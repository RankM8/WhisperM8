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
    static let shared = ClaudeGPTMixRouter()

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
    private static let maximumHeaderBytes = 64 * 1_024
    private static let maximumBodyBytes = 64 * 1_024 * 1_024
    private static let maximumDiagnosticErrorBytes = 64 * 1_024

    private let upstreamURLResolver: UpstreamURLResolver
    private let gptContextWindowResolver: GPTContextWindowResolver
    private let listenerQueue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.listener")
    private let lifecycleQueue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.lifecycle")
    private var listener: NWListener?
    private var requestedPort: Int?
    private var boundPortStorage: Int?
    private var connections: [UUID: ClientConnection] = [:]
    private var generation: UInt64 = 0

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
        }
    ) {
        self.upstreamURLResolver = upstreamURLResolver
        self.gptContextWindowResolver = gptContextWindowResolver
    }

    convenience init(
        codexProxyURL: URL,
        anthropicURL: URL,
        gptContextWindow: Int = AppPreferences.claudeGPTDefaultContextWindow
    ) {
        self.init(
            upstreamURLResolver: { upstream in
                switch upstream {
                case .codexProxy: return codexProxyURL
                case .anthropic: return anthropicURL
                }
            },
            gptContextWindowResolver: { gptContextWindow }
        )
    }

    var listeningPort: Int? {
        lifecycleQueue.sync { boundPortStorage }
    }

    @discardableResult
    func start(port: Int) -> Result<Void, Error> {
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
        stopped.connections.forEach { $0.cancel() }
    }

    private func stop(generation expectedGeneration: UInt64) {
        let stopped: (listener: NWListener?, connections: [ClientConnection])? = lifecycleQueue.sync {
            guard generation == expectedGeneration else { return nil }
            return detachCurrentListener()
        }

        stopped?.listener?.cancel()
        stopped?.connections.forEach { $0.cancel() }
    }

    /// Nur auf `lifecycleQueue` aufrufen. Die Generation verhindert, dass
    /// ein alter Startfehler einen inzwischen neu gestarteten Listener stoppt.
    private func detachCurrentListener() -> (listener: NWListener?, connections: [ClientConnection]) {
        generation &+= 1
        let stoppedListener = listener
        listener = nil
        requestedPort = nil
        boundPortStorage = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        return (stoppedListener, activeConnections)
    }

    /// Nur auf `lifecycleQueue` aufrufen. Bei einem asynchronen Listenerfehler
    /// werden auch alle bereits angenommenen Verbindungen idempotent beendet.
    private func detachFailedListener() {
        let stopped = detachCurrentListener()
        stopped.connections.forEach { $0.cancel() }
    }

    static func model(in body: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            let dictionary = object as? [String: Any],
            let model = dictionary["model"] as? String
        else {
            return nil
        }
        return model
    }

    static func upstream(for body: Data) -> Upstream {
        guard let model = model(in: body) else { return .anthropic }
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
        guard let canonical = ClaudeGPTModelAlias.canonicalGPTModel(trimmed) else {
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
                message = "The experimental 372k context profile is verified only for gpt-5.6-sol. Switch to Sol or select the standard 272k profile and retry."
            } else {
                message = "Unsupported GPT model for the configured context profile. Supported models: gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5, gpt-5.4, and gpt-5.4-mini. All except gpt-5.4-mini optionally support -fast."
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
        let id = UUID()
        let client: ClientConnection? = lifecycleQueue.sync {
            guard generation == expectedGeneration, listener === sourceListener else {
                return nil
            }
            let client = ClientConnection(
                connection: connection,
                upstreamURLResolver: upstreamURLResolver,
                gptContextWindowResolver: gptContextWindowResolver,
                onFinish: { [weak self] in self?.removeConnection(id: id) }
            )
            connections[id] = client
            return client
        }
        guard let client else { return false }
        client.start()
        return true
    }

    private func removeConnection(id: UUID) {
        lifecycleQueue.async { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
    }
}

private extension ClaudeGPTMixRouter {
    final class ClientConnection {
        private let connection: NWConnection
        private let upstreamURLResolver: UpstreamURLResolver
        private let gptContextWindowResolver: GPTContextWindowResolver
        private let onFinish: () -> Void
        private let queue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.client")
        private var buffer = Data()
        private var requestHead: HTTPRequestHead?
        private var upstreamTask: StreamingUpstreamTask?
        private var didFinish = false
        private var didSendResponseHead = false
        // Synchron beim ersten Fehler-Response gesetzt (didFinish folgt erst
        // asynchron in der Send-Completion) — verhindert, dass die Receive-
        // Schleife eine zweite Response auf denselben Socket schreibt.
        private var didScheduleResponse = false
        private var requestModel: String?
        private var requestUpstream: Upstream?
        private var upstreamStatusCode: Int?
        private var upstreamErrorBuffer: Data?
        private var upstreamErrorBytes = 0
        private var overflowProbe: CodexSyntheticOverflowProbe?
        private var deferredResponseHead: Data?
        private var overflowProbeTimer: DispatchSourceTimer?
        private var holdsOverflowProbeBudget = false

        init(
            connection: NWConnection,
            upstreamURLResolver: @escaping UpstreamURLResolver,
            gptContextWindowResolver: @escaping GPTContextWindowResolver,
            onFinish: @escaping () -> Void
        ) {
            self.connection = connection
            self.upstreamURLResolver = upstreamURLResolver
            self.gptContextWindowResolver = gptContextWindowResolver
            self.onFinish = onFinish
        }

        func start() {
            queue.async { [weak self] in
                guard let self, !self.didFinish else { return }
                self.connection.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.finish() }
                    if case .cancelled = state { self?.finish() }
                }
                self.connection.start(queue: self.queue)
                self.receiveMore()
            }
        }

        func cancel() {
            queue.async { [weak self] in
                guard let self, !self.didFinish else { return }
                self.connection.cancel()
                self.finish()
            }
        }

        private func receiveMore() {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1_024
            ) { [weak self] data, _, isComplete, error in
                guard let self, !self.didFinish else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.consumeBuffer()
                }
                guard !self.didFinish, !self.didScheduleResponse, self.upstreamTask == nil else {
                    return
                }
                if error != nil || isComplete {
                    self.sendSimpleResponse(status: 400, reason: "Bad Request")
                } else {
                    self.receiveMore()
                }
            }
        }

        private func consumeBuffer() {
            if requestHead == nil {
                let delimiter = Data("\r\n\r\n".utf8)
                guard let headerRange = buffer.range(of: delimiter) else {
                    if buffer.count > ClaudeGPTMixRouter.maximumHeaderBytes {
                        sendSimpleResponse(status: 431, reason: "Request Header Fields Too Large")
                    }
                    return
                }
                let headData = Data(buffer[..<headerRange.lowerBound])
                buffer.removeSubrange(..<headerRange.upperBound)
                switch ClaudeGPTMixRouter.parseRequestHead(headData) {
                case .success(let head):
                    guard head.contentLength <= ClaudeGPTMixRouter.maximumBodyBytes else {
                        sendSimpleResponse(status: 413, reason: "Content Too Large")
                        return
                    }
                    requestHead = head
                case .failure(.lengthRequired):
                    sendSimpleResponse(status: 411, reason: "Length Required")
                    return
                case .failure(.badRequest):
                    sendSimpleResponse(status: 400, reason: "Bad Request")
                    return
                }
            }

            guard let requestHead, buffer.count >= requestHead.contentLength else { return }
            let body = Data(buffer.prefix(requestHead.contentLength))
            forward(requestHead: requestHead, body: body)
        }

        private func forward(requestHead: HTTPRequestHead, body: Data) {
            if ClaudeGPTMixRouter.hasUnsupportedContentEncoding(requestHead.headers) {
                let errorBody = ClaudeGPTMixRouter.anthropicInvalidRequestBody(
                    message: "Unsupported Content-Encoding. Send the request body with identity encoding."
                )
                Logger.claudeGPTRouter.warning("encoded_request_body_rejected status=415")
                sendJSONResponse(
                    status: 415,
                    reason: "Unsupported Media Type",
                    body: errorBody
                )
                return
            }

            let model = ClaudeGPTMixRouter.model(in: body)
            let upstream = ClaudeGPTMixRouter.upstream(for: body)
            if let errorBody = ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: model,
                contextWindow: gptContextWindowResolver()
            ) {
                requestModel = model
                requestUpstream = upstream
                Logger.claudeGPTRouter.warning(
                    "gpt_model_rejected model=\(model ?? "nil", privacy: .public)"
                )
                sendJSONResponse(status: 400, reason: "Bad Request", body: errorBody)
                return
            }
            let baseURL = upstreamURLResolver(upstream)
            guard
                let url = URL(string: requestHead.target, relativeTo: baseURL)?.absoluteURL,
                url.scheme == baseURL.scheme,
                url.host == baseURL.host,
                url.port == baseURL.port
            else {
                sendSimpleResponse(status: 400, reason: "Bad Request")
                return
            }

            let host = Self.hostHeader(for: baseURL)
            let forwardedHeaders = ClaudeGPTMixRouter.upstreamHeaders(
                from: requestHead.headers,
                upstream: upstream,
                host: host,
                bodyLength: body.count
            )
            var request = URLRequest(url: url, timeoutInterval: 600)
            request.httpMethod = requestHead.method
            request.httpBody = body.isEmpty ? nil : body
            var headerFields: [String: String] = [:]
            for header in forwardedHeaders {
                headerFields[header.name] = header.value
            }
            // Die pure Filterfunktion entscheidet zielabhaengig, ob Claude-OAuth
            // erhalten bleibt oder vor dem lokalen Codex-Proxy entfernt wird.
            request.allHTTPHeaderFields = headerFields

            requestModel = model
            requestUpstream = upstream
            let task = StreamingUpstreamTask(
                callbackQueue: queue,
                onResponse: { [weak self] response in self?.receive(response: response) },
                onData: { [weak self] data in self?.receive(upstreamData: data) },
                onCompletion: { [weak self] error in self?.completeUpstream(error: error) }
            )
            upstreamTask = task
            task.start(request: request)
        }

        private func receive(response: HTTPURLResponse) {
            guard !didFinish, !didSendResponseHead, deferredResponseHead == nil else { return }
            upstreamStatusCode = response.statusCode
            if (400...499).contains(response.statusCode) {
                upstreamErrorBuffer = Data()
                upstreamErrorBytes = 0
            }
            let headers = response.allHeaderFields.compactMap { key, value -> HTTPHeader? in
                guard let name = key as? String else { return nil }
                return HTTPHeader(name: name, value: String(describing: value))
            }
            let forwarded = ClaudeGPTMixRouter.responseHeaders(headers)
            var head = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(response.statusCode))\r\n"
            for header in forwarded {
                head += "\(header.name): \(header.value)\r\n"
            }
            head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            let headData = Data(head.utf8)

            let shouldProbe = requestUpstream == .codexProxy
                && response.statusCode == 200
                && ClaudeGPTMixRouter.isEventStreamContentType(
                    response.value(forHTTPHeaderField: "Content-Type")
                )
                && SyntheticOverflowProbeBudget.acquire()
            if shouldProbe {
                holdsOverflowProbeBudget = true
                overflowProbe = CodexSyntheticOverflowProbe()
                deferredResponseHead = headData
                scheduleOverflowProbeTimeout()
            } else {
                didSendResponseHead = true
                send(headData)
            }
            log(status: response.statusCode)
        }

        private func receive(upstreamData data: Data) {
            guard !didFinish, !data.isEmpty else { return }
            if var probe = overflowProbe {
                let decision = probe.ingest(data)
                let accepted = probe.lastAcceptedByteCount
                overflowProbe = probe
                switch decision {
                case .pending:
                    return
                case .overflow:
                    handleSyntheticOverflow()
                    return
                case .passThrough:
                    let remainder = accepted < data.count ? Data(data.dropFirst(accepted)) : Data()
                    flushOverflowProbeFailOpen(additionalData: remainder)
                    return
                }
            }
            guard didSendResponseHead else { return }
            captureUpstreamErrorDiagnostics(data)
            sendChunk(data)
        }

        private func captureUpstreamErrorDiagnostics(_ data: Data) {
            if upstreamErrorBuffer != nil {
                upstreamErrorBytes += data.count
                let remainingCapacity = max(
                    0,
                    ClaudeGPTMixRouter.maximumDiagnosticErrorBytes
                        - (upstreamErrorBuffer?.count ?? 0)
                )
                if remainingCapacity > 0 {
                    upstreamErrorBuffer?.append(data.prefix(remainingCapacity))
                }
            }
        }

        private func sendChunk(_ data: Data) {
            guard !data.isEmpty else { return }
            var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
            chunk.append(data)
            chunk.append(Data("\r\n".utf8))
            send(chunk)
        }

        private func scheduleOverflowProbeTimeout() {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + CodexSyntheticOverflowProbe.deadlineSeconds)
            timer.setEventHandler { [weak self] in
                self?.flushOverflowProbeFailOpen(additionalData: Data())
            }
            overflowProbeTimer = timer
            timer.resume()
        }

        private func flushOverflowProbeFailOpen(additionalData: Data) {
            guard let probe = overflowProbe, let head = deferredResponseHead else { return }
            let prefix = probe.bufferedData
            clearOverflowProbe()
            deferredResponseHead = nil
            didSendResponseHead = true
            send(head)
            sendChunk(prefix)
            sendChunk(additionalData)
        }

        private func handleSyntheticOverflow() {
            guard overflowProbe != nil, !didSendResponseHead, !didScheduleResponse else { return }
            clearOverflowProbe()
            deferredResponseHead = nil
            upstreamTask?.cancel()
            let limit = min(
                max(gptContextWindowResolver(), AppPreferences.claudeGPTContextWindowRange.lowerBound),
                ClaudeGPTModelAlias.maximumConfigurableContextWindow
            )
            let body = ClaudeGPTMixRouter.anthropicInvalidRequestBody(
                message: "prompt is too long: \(limit + 1) tokens > \(limit)"
            )
            sendJSONResponse(status: 400, reason: "Bad Request", body: body)
        }

        private func clearOverflowProbe() {
            overflowProbeTimer?.cancel()
            overflowProbeTimer = nil
            overflowProbe = nil
            if holdsOverflowProbeBudget {
                holdsOverflowProbeBudget = false
                SyntheticOverflowProbeBudget.release()
            }
        }

        private func completeUpstream(error: Error?) {
            upstreamTask = nil
            guard !didFinish, !didScheduleResponse else { return }
            if var probe = overflowProbe {
                if error != nil {
                    clearOverflowProbe()
                    deferredResponseHead = nil
                    log(status: 502)
                    sendSimpleResponse(status: 502, reason: "Bad Gateway")
                    return
                }
                let decision = probe.finish()
                overflowProbe = probe
                if decision == .overflow {
                    handleSyntheticOverflow()
                    return
                }
                flushOverflowProbeFailOpen(additionalData: Data())
            }
            logUpstreamErrorDiagnosticsIfNeeded()
            if !didSendResponseHead {
                log(status: 502)
                sendSimpleResponse(status: 502, reason: "Bad Gateway")
                return
            }

            // Nach versandtem Status kann HTTP den Status nicht mehr auf 502
            // wechseln. Ein sauber abgeschlossenes Upstream-Streaming bekommt
            // den 0-Chunk; bei spaetem Fehler signalisiert ein Verbindungsabbruch
            // dem Client dagegen die unvollstaendige Antwort.
            if error == nil {
                send(Data("0\r\n\r\n".utf8), closesConnection: true)
            } else {
                connection.cancel()
                finish()
            }
        }

        private func sendJSONResponse(status: Int, reason: String, body: Data) {
            guard !didFinish, !didSendResponseHead, !didScheduleResponse else { return }
            didScheduleResponse = true
            let head = Data(
                "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
            )
            var response = head
            response.append(body)
            send(response, closesConnection: true)
        }

        private func sendSimpleResponse(status: Int, reason: String) {
            guard !didFinish, !didSendResponseHead, !didScheduleResponse else { return }
            didScheduleResponse = true
            let body = Data("\(status) \(reason)\n".utf8)
            let head = Data(
                "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
            )
            var response = head
            response.append(body)
            send(response, closesConnection: true)
        }

        private func send(_ data: Data, closesConnection: Bool = false) {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || closesConnection {
                    self.connection.cancel()
                    self.finish()
                }
            })
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            clearOverflowProbe()
            upstreamTask?.cancel()
            upstreamTask = nil
            onFinish()
        }

        private func logUpstreamErrorDiagnosticsIfNeeded() {
            guard let status = upstreamStatusCode,
                  (400...499).contains(status),
                  let body = upstreamErrorBuffer else { return }
            let diagnostics = ClaudeGPTMixRouter.upstreamErrorDiagnostics(from: body)
            Logger.claudeGPTRouter.warning(
                "upstream_client_error model=\(self.requestModel ?? "nil", privacy: .public) upstream=\(self.requestUpstream?.rawValue ?? "unknown", privacy: .public) status=\(status) errorType=\(diagnostics.errorType ?? "nil", privacy: .public) errorCode=\(diagnostics.errorCode ?? "nil", privacy: .public) contextLimit=\(diagnostics.isContextLimit ? "true" : "false", privacy: .public) responseBytes=\(self.upstreamErrorBytes) capturedBytes=\(diagnostics.capturedBytes)"
            )
            upstreamErrorBuffer = nil
        }

        private func log(status: Int) {
            Logger.claudeGPTRouter.info(
                "model=\(self.requestModel ?? "nil", privacy: .public) upstream=\(self.requestUpstream?.rawValue ?? "unknown", privacy: .public) status=\(status)"
            )
        }

        private static func hostHeader(for url: URL) -> String {
            guard let host = url.host else { return "" }
            guard let port = url.port else { return host }
            let isDefaultPort = (url.scheme == "http" && port == 80)
                || (url.scheme == "https" && port == 443)
            return isDefaultPort ? host : "\(host):\(port)"
        }

        private static func reasonPhrase(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 201: return "Created"
            case 202: return "Accepted"
            case 204: return "No Content"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 408: return "Request Timeout"
            case 409: return "Conflict"
            case 415: return "Unsupported Media Type"
            case 429: return "Too Many Requests"
            case 500: return "Internal Server Error"
            case 502: return "Bad Gateway"
            case 503: return "Service Unavailable"
            default: return "Upstream Response"
            }
        }
    }

    final class StreamingUpstreamTask: NSObject, URLSessionDataDelegate {
        private let callbackQueue: DispatchQueue
        private let onResponse: (HTTPURLResponse) -> Void
        private let onData: (Data) -> Void
        private let onCompletion: (Error?) -> Void
        private var session: URLSession?
        private var task: URLSessionDataTask?

        init(
            callbackQueue: DispatchQueue,
            onResponse: @escaping (HTTPURLResponse) -> Void,
            onData: @escaping (Data) -> Void,
            onCompletion: @escaping (Error?) -> Void
        ) {
            self.callbackQueue = callbackQueue
            self.onResponse = onResponse
            self.onData = onData
            self.onCompletion = onCompletion
        }

        func start(request: URLRequest) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 600
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            // URLSession- und NWConnection-Callbacks teilen absichtlich genau
            // dieselbe Queue; damit sind Completion und Cancel streng geordnet.
            delegateQueue.underlyingQueue = callbackQueue
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }

        func cancel() {
            task?.cancel()
            task = nil
            session?.invalidateAndCancel()
            session = nil
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let response = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            onResponse(response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            onData(data)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            onCompletion(error)
            self.task = nil
            session.finishTasksAndInvalidate()
            self.session = nil
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
