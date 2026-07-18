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

    private enum ListenerStartAction {
        case complete(Result<Void, Error>)
        case start(NWListener, generation: UInt64)
    }

    typealias UpstreamURLResolver = (Upstream) -> URL

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

    private let upstreamURLResolver: UpstreamURLResolver
    private let listenerQueue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.listener")
    private let lifecycleQueue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.lifecycle")
    private var listener: NWListener?
    private var requestedPort: Int?
    private var boundPortStorage: Int?
    private var connections: [UUID: ClientConnection] = [:]
    private var generation: UInt64 = 0

    init(upstreamURLResolver: @escaping UpstreamURLResolver = { upstream in
        switch upstream {
        case .codexProxy:
            return URL(
                string: "http://127.0.0.1:\(AppPreferences.shared.claudeGPTBackendPort)"
            )!
        case .anthropic:
            return URL(string: "https://api.anthropic.com")!
        }
    }) {
        self.upstreamURLResolver = upstreamURLResolver
    }

    convenience init(codexProxyURL: URL, anthropicURL: URL) {
        self.init { upstream in
            switch upstream {
            case .codexProxy: return codexProxyURL
            case .anthropic: return anthropicURL
            }
        }
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
        guard let model = model(in: body), model.hasPrefix("gpt-") else {
            return .anthropic
        }
        return .codexProxy
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
        private let onFinish: () -> Void
        private let queue = DispatchQueue(label: "com.whisperm8.claude-gpt-router.client")
        private var buffer = Data()
        private var requestHead: HTTPRequestHead?
        private var upstreamTask: StreamingUpstreamTask?
        private var didFinish = false
        private var didSendResponseHead = false
        private var requestModel: String?
        private var requestUpstream: Upstream?

        init(
            connection: NWConnection,
            upstreamURLResolver: @escaping UpstreamURLResolver,
            onFinish: @escaping () -> Void
        ) {
            self.connection = connection
            self.upstreamURLResolver = upstreamURLResolver
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
                guard !self.didFinish, self.upstreamTask == nil else { return }
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
            let upstream = ClaudeGPTMixRouter.upstream(for: body)
            let model = ClaudeGPTMixRouter.model(in: body)
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
            guard !didFinish, !didSendResponseHead else { return }
            didSendResponseHead = true
            let headers = response.allHeaderFields.compactMap { key, value -> HTTPHeader? in
                guard let name = key as? String else { return nil }
                return HTTPHeader(name: name, value: String(describing: value))
            }
            let forwarded = ClaudeGPTMixRouter.filteredHeaders(headers)
            var head = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(response.statusCode))\r\n"
            for header in forwarded {
                head += "\(header.name): \(header.value)\r\n"
            }
            head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            send(Data(head.utf8))
            log(status: response.statusCode)
        }

        private func receive(upstreamData data: Data) {
            guard !didFinish, didSendResponseHead, !data.isEmpty else { return }
            var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
            chunk.append(data)
            chunk.append(Data("\r\n".utf8))
            send(chunk)
        }

        private func completeUpstream(error: Error?) {
            upstreamTask = nil
            guard !didFinish else { return }
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

        private func sendSimpleResponse(status: Int, reason: String) {
            guard !didFinish else { return }
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
            upstreamTask?.cancel()
            upstreamTask = nil
            onFinish()
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
