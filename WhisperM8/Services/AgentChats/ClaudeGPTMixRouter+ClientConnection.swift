import Foundation

// Client-Verbindung und Upstream-Strom des Mix-Routers. Die HTTP-Logik ist für
// beide Lauscher-Varianten dieselbe; nur die Ein- und Ausgabe kommt über
// `ClaudeGPTRouterClientTransport` (NWConnection in der App, BSD-Socket im
// Router-Dienst, Plan neustart-ohne-chatverlust.md, Paket 3).
extension ClaudeGPTMixRouter {
    final class ClientConnection {
        private let connection: ClaudeGPTRouterClientTransport
        private let upstreamURLResolver: UpstreamURLResolver
        private let gptContextWindowResolver: GPTContextWindowResolver
        private let profileRouting: ProfileRouting
        private let authTokenResolver: () -> String?
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
        /// GPT-Konto-Profil des Requests (nur Codex-Upstream, `nil` = main).
        private var requestProfile: String?
        private var upstreamStatusCode: Int?
        private var upstreamErrorBuffer: Data?
        private var upstreamErrorBytes = 0
        private var overflowProbe: CodexSyntheticOverflowProbe?
        private var deferredResponseHead: Data?
        private var overflowProbeTimer: DispatchSourceTimer?
        private var holdsOverflowProbeBudget = false

        init(
            connection: ClaudeGPTRouterClientTransport,
            upstreamURLResolver: @escaping UpstreamURLResolver,
            gptContextWindowResolver: @escaping GPTContextWindowResolver,
            profileRouting: ProfileRouting,
            authTokenResolver: @escaping () -> String?,
            onFinish: @escaping () -> Void
        ) {
            self.connection = connection
            self.upstreamURLResolver = upstreamURLResolver
            self.gptContextWindowResolver = gptContextWindowResolver
            self.profileRouting = profileRouting
            self.authTokenResolver = authTokenResolver
            self.onFinish = onFinish
        }

        func start() {
            queue.async { [weak self] in
                guard let self, !self.didFinish else { return }
                self.connection.start(queue: self.queue) { [weak self] in
                    self?.finish()
                }
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
            connection.receive(maximumLength: 64 * 1_024) { [weak self] data, isComplete, failed in
                guard let self, !self.didFinish else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.consumeBuffer()
                }
                guard !self.didFinish, !self.didScheduleResponse, self.upstreamTask == nil else {
                    return
                }
                if failed || isComplete {
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

            // `auto`/`gpt-auto` (z. B. aus Agent-Frontmatter) wird hier auf das
            // neueste Katalogmodell umgeschrieben — der Aufrufer muss keine
            // konkrete ID kennen, die morgen veraltet ist.
            // Body wird dabei höchstens einmal voll geparst (LR-GPT-008).
            let prepared = ClaudeGPTMixRouter.prepareRequestBody(body)
            let body = prepared.body
            let model = prepared.model
            let upstream = prepared.upstream
            if upstream == .codexProxy, let expected = authTokenResolver(),
               !ClaudeGPTRouterToken.matches(
                   requestHead.headers.first {
                       $0.name.caseInsensitiveCompare(ClaudeGPTRouterToken.headerName) == .orderedSame
                   }?.value,
                   expected: expected
               ) {
                // Weder Profilstart noch Upstream-Zugriff ohne Token (LR-GPT-001).
                requestModel = model
                requestUpstream = upstream
                Logger.claudeGPTRouter.warning("gpt_router_token_rejected status=401")
                sendJSONResponse(
                    status: 401,
                    reason: "Unauthorized",
                    body: ClaudeGPTMixRouter.anthropicAuthErrorBody(
                        message: "GPT-Backend: lokales Router-Token fehlt oder ist ungültig. Chat in WhisperM8 neu starten (ältere Hintergrund-Agents einmal neu spawnen)."
                    )
                )
                return
            }
            if let sanitized = prepared.sanitization {
                // Das OpenAI-Backend validiert Tool-Schemas mit einer Regex-
                // Engine ohne Unicode-Klassen; Claude Codes Artifact-Tool
                // trägt `\p{Cc}…` im `pattern` → 400 „is not a 'regex'" und
                // jeder gpt-/general-purpose-Subagent starb sofort
                // (Befund 2026-09-09/12). Nur für den Codex-Upstream, Anthropic
                // versteht die Patterns.
                Logger.claudeGPTRouter.info(
                    "gpt_tool_schema_patterns_stripped count=\(sanitized.removedPatterns) tools=\(sanitized.affectedTools.joined(separator: ","), privacy: .public)"
                )
            }
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
            var baseURL = upstreamURLResolver(upstream)
            if upstream == .codexProxy, profileRouting.isEnabled() {
                // Konto der Session: Header, sonst das aktive Profil (E4).
                // `nil` = main → Backend-Port wie bisher.
                var profile = ClaudeGPTMixRouter.profileName(in: requestHead.headers)
                    ?? profileRouting.activeProfile()
                if let promoted = profile, profileRouting.wasPromotedToMain(promoted) {
                    profile = GPTAccountProfiles.mainProfileName
                }
                if let profile, profile != GPTAccountProfiles.mainProfileName {
                    requestProfile = profile
                    guard let profileURL = profileRouting.proxyURL(profile) else {
                        requestModel = model
                        requestUpstream = upstream
                        let message: String
                        if profileRouting.isLoggedIn(profile) {
                            Logger.claudeGPTRouter.warning(
                                "gpt_profile_proxy_unavailable profile=\(profile, privacy: .public) — Instanz wird gestartet, Request bekommt 503"
                            )
                            profileRouting.startInstance(profile)
                            message = "GPT-Konto „\(profile)“ ist nicht verbunden. WhisperM8 startet die Proxy-Instanz — bitte in wenigen Sekunden erneut senden."
                        } else {
                            Logger.claudeGPTRouter.warning(
                                "gpt_profile_not_logged_in profile=\(profile, privacy: .public) — Request bekommt 503"
                            )
                            message = "GPT-Konto „\(profile)“ ist nicht angemeldet. Bitte in den Einstellungen (GPT-Backend) anmelden oder den Chat im Kontextmenü auf ein anderes Konto umstellen."
                        }
                        sendJSONResponse(
                            status: 503,
                            reason: "Service Unavailable",
                            body: ClaudeGPTMixRouter.anthropicAPIErrorBody(message: message)
                        )
                        return
                    }
                    baseURL = profileURL
                } else if profile != nil {
                    requestProfile = GPTAccountProfiles.mainProfileName
                }
            }
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
            connection.send(data) { [weak self] failed in
                guard let self else { return }
                if failed || closesConnection {
                    self.connection.cancel()
                    self.finish()
                }
            }
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            // Idempotent; schließt beim BSD-Transport den Deskriptor, bei
            // NWConnection räumt es eine fehlgeschlagene Verbindung ab.
            connection.cancel()
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
                "model=\(self.requestModel ?? "nil", privacy: .public) upstream=\(self.requestUpstream?.rawValue ?? "unknown", privacy: .public) profile=\(self.requestProfile ?? "main", privacy: .public) status=\(status)"
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
