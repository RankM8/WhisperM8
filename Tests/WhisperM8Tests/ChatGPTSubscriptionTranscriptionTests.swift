import Foundation
import XCTest
@testable import WhisperM8

/// ChatGPT-Abo-Transkription: Request-Form, Fehler-Mapping, Bootstrap/Retry
/// und Prewarm — komplett ohne Netz (URLProtocol-Stub) und ohne echten Proxy
/// (Abhängigkeiten als Closures).
final class ChatGPTSubscriptionTranscriptionTests: XCTestCase {
    override func tearDown() {
        ChatGPTStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Hilfen

    /// Zähl-Spy für die Abhängigkeiten (Aufrufe kommen von globalen Queues).
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _ensureCalls: [String?] = []
        private var _originCalls = 0
        private var _sessionCalls = 0
        private var _ensured = false

        var ensureCalls: [String?] { lock.withLock { _ensureCalls } }
        var originCalls: Int { lock.withLock { _originCalls } }
        var sessionCalls: Int { lock.withLock { _sessionCalls } }
        var ensured: Bool { lock.withLock { _ensured } }

        func recordEnsure(_ profile: String?) { lock.withLock { _ensureCalls.append(profile); _ensured = true } }
        func recordOrigin() { lock.withLock { _originCalls += 1 } }
        func recordSession() { lock.withLock { _sessionCalls += 1 } }
    }

    private func dependencies(
        spy: Spy,
        featureEnabled: Bool = true,
        backendEnabled: Bool = true,
        profile: String? = nil,
        portBeforeEnsure: Int? = 18_799,
        portAfterEnsure: Int? = 18_799,
        ensureResult: Result<Void, ClaudeCodeProxyError> = .success(()),
        origin: ClaudeCodeProxyInstanceOrigin = .selfStarted,
        version: String? = "0.1.44",
        reachable: Bool = true
    ) -> ChatGPTTranscriptionDependencies {
        ChatGPTTranscriptionDependencies(
            isFeatureEnabled: { featureEnabled },
            isBackendEnabled: { backendEnabled },
            activeProfile: { profile },
            knownPort: { _ in spy.ensured ? portAfterEnsure : portBeforeEnsure },
            ensureRunning: { profile in
                spy.recordEnsure(profile)
                return ensureResult
            },
            instanceOrigin: { _ in
                spy.recordOrigin()
                return origin
            },
            binaryVersion: { version },
            isReachable: { _ in reachable },
            sessionProvider: { _ in
                spy.recordSession()
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ChatGPTStubURLProtocol.self]
                return URLSession(configuration: configuration)
            }
        )
    }

    private func tempAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatgpt-stt-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    private static func response(_ request: URLRequest, status: Int, body: String) -> ChatGPTStubURLProtocol.Outcome {
        .response(
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    private func transcribe(
        _ dependencies: ChatGPTTranscriptionDependencies,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String {
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let service = ChatGPTSubscriptionTranscriptionService(dependencies: dependencies)
        return try await service.transcribe(audioURL: audio, language: "de", audioDuration: 2)
    }

    private func expectError(
        _ dependencies: ChatGPTTranscriptionDependencies,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Error? {
        do {
            _ = try await transcribe(dependencies)
            XCTFail("Fehler erwartet", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Request-Form

    func testRequestGoesDirectlyToInstancePortWithoutAuthorization() async throws {
        let spy = Spy()
        ChatGPTStubURLProtocol.handler = { request in
            Self.response(
                request,
                status: 200,
                body: #"{"text":"hallo welt","asset_pointer":"sediment://file_x","asset_ttl":2592000,"asset_format":"m4a"}"#
            )
        }

        let text = try await transcribe(dependencies(spy: spy))

        XCTAssertEqual(text, "hallo welt", "Zusatzfelder werden ignoriert, nur `text` zählt")
        let requests = ChatGPTStubURLProtocol.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18799/v1/audio/transcriptions")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(spy.ensureCalls.isEmpty, "Port bekannt → kein Bootstrap")
    }

    // MARK: - Schalter

    func testFeatureOrBackendOffThrowsBeforeAnyWork() async {
        for (feature, backend, expected) in [
            (false, true, ChatGPTTranscriptionError.featureDisabled),
            (true, false, ChatGPTTranscriptionError.backendDisabled),
        ] {
            let spy = Spy()
            let error = await expectError(dependencies(spy: spy, featureEnabled: feature, backendEnabled: backend))
            XCTAssertEqual(error as? ChatGPTTranscriptionError, expected)
            XCTAssertTrue(spy.ensureCalls.isEmpty)
            XCTAssertEqual(spy.sessionCalls, 0)
        }
        XCTAssertTrue(ChatGPTStubURLProtocol.requests.isEmpty)
    }

    // MARK: - Bootstrap

    func testUnknownPortBootstrapsActiveProfileOnceThenUsesNewPort() async throws {
        let spy = Spy()
        ChatGPTStubURLProtocol.handler = { request in
            Self.response(request, status: 200, body: #"{"text":"ok"}"#)
        }

        let text = try await transcribe(dependencies(
            spy: spy, profile: "work", portBeforeEnsure: nil, portAfterEnsure: 18_811
        ))

        XCTAssertEqual(text, "ok")
        XCTAssertEqual(spy.ensureCalls, ["work"])
        XCTAssertEqual(ChatGPTStubURLProtocol.requests.first?.url?.port, 18_811)
    }

    func testProfileNotLoggedInSurfacesWithoutRequest() async {
        let spy = Spy()
        let error = await expectError(dependencies(
            spy: spy, profile: "x", portBeforeEnsure: nil,
            ensureResult: .failure(.profileNotLoggedIn("x"))
        ))
        XCTAssertEqual(error as? ChatGPTTranscriptionError, .profileNotLoggedIn("x"))
        XCTAssertEqual(spy.sessionCalls, 0, "kein stiller Rückfall auf main, kein Request")
        XCTAssertTrue(ChatGPTStubURLProtocol.requests.isEmpty)
    }

    func testOtherBootstrapFailureBecomesProxyUnavailable() async {
        let spy = Spy()
        let error = await expectError(dependencies(
            spy: spy, portBeforeEnsure: nil, ensureResult: .failure(.binaryMissing)
        ))
        guard case .proxyUnavailable(let reason)? = error as? ChatGPTTranscriptionError else {
            return XCTFail("Erwartet proxyUnavailable, erhalten \(String(describing: error))")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Retry bei „Connection refused"

    func testConnectionRefusedStartsProxyAndRetriesExactlyOnce() async throws {
        let spy = Spy()
        ChatGPTStubURLProtocol.handler = { request in
            ChatGPTStubURLProtocol.requests.count == 1
                ? .failure(URLError(.cannotConnectToHost))
                : Self.response(request, status: 200, body: #"{"text":"zweiter Versuch"}"#)
        }

        let text = try await transcribe(dependencies(spy: spy, profile: "work"))

        XCTAssertEqual(text, "zweiter Versuch")
        XCTAssertEqual(spy.ensureCalls, ["work"])
        XCTAssertEqual(ChatGPTStubURLProtocol.requests.count, 2)
    }

    func testSecondConnectionRefusedBecomesProxyUnavailable() async {
        let spy = Spy()
        ChatGPTStubURLProtocol.handler = { _ in .failure(URLError(.cannotConnectToHost)) }

        let error = await expectError(dependencies(spy: spy))

        guard case .proxyUnavailable? = error as? ChatGPTTranscriptionError else {
            return XCTFail("Erwartet proxyUnavailable, erhalten \(String(describing: error))")
        }
        XCTAssertEqual(spy.ensureCalls.count, 1)
        XCTAssertEqual(ChatGPTStubURLProtocol.requests.count, 2)
    }

    func testConnectionLostIsNotRetried() async {
        let spy = Spy()
        ChatGPTStubURLProtocol.handler = { _ in .failure(URLError(.networkConnectionLost)) }

        let error = await expectError(dependencies(spy: spy))

        guard case .network(let urlError)? = error as? ChatGPTTranscriptionError else {
            return XCTFail("Erwartet network, erhalten \(String(describing: error))")
        }
        XCTAssertEqual(urlError.code, .networkConnectionLost)
        XCTAssertTrue(spy.ensureCalls.isEmpty)
        XCTAssertEqual(ChatGPTStubURLProtocol.requests.count, 1)
    }

    func testCancelledPassesThroughUnchanged() async {
        let spy = Spy()
        ChatGPTStubURLProtocol.handler = { _ in .failure(URLError(.cancelled)) }

        let error = await expectError(dependencies(spy: spy))

        XCTAssertEqual((error as? URLError)?.code, .cancelled, "Cancel/ESC-Pfad des Coordinators hängt daran")
        XCTAssertTrue(spy.ensureCalls.isEmpty)
    }

    // MARK: - HTTP-Fehler im Service

    func testMissingRouteQueriesOriginButUpstream404DoesNot() async {
        let routeSpy = Spy()
        ChatGPTStubURLProtocol.handler = { request in
            Self.response(request, status: 404, body: #"{"type":"error","error":{"type":"not_found","message":"No route for POST /v1/audio/transcriptions"}}"#)
        }
        let routeError = await expectError(dependencies(spy: routeSpy, origin: .external))
        XCTAssertEqual(
            routeError as? ChatGPTTranscriptionError,
            .routeDisabled(origin: .external, port: 18_799, version: "0.1.44")
        )
        XCTAssertEqual(routeSpy.originCalls, 1)

        ChatGPTStubURLProtocol.reset()
        let upstreamSpy = Spy()
        ChatGPTStubURLProtocol.handler = { request in
            Self.response(request, status: 404, body: #"{"error":{"message":"Codex transcription service returned HTTP 404","type":"invalid_request_error","param":null,"code":"upstream_error"}}"#)
        }
        let upstreamError = await expectError(dependencies(spy: upstreamSpy))
        XCTAssertEqual(upstreamError as? ChatGPTTranscriptionError, .endpointGone(statusCode: 404))
        XCTAssertEqual(upstreamSpy.originCalls, 0)
    }

    // MARK: - Mapper (pur)

    private func map(_ status: Int, _ body: String, origin: ClaudeCodeProxyInstanceOrigin = .selfStarted) -> ChatGPTTranscriptionError {
        ChatGPTTranscriptionErrorMapper.map(statusCode: status, body: body, origin: origin, port: 18_765, version: "0.1.44")
    }

    private func openAIError(code: String, message: String = "msg", type: String = "invalid_request_error") -> String {
        #"{"error":{"message":"\#(message)","type":"\#(type)","param":null,"code":"\#(code)"}}"#
    }

    func testMapperTable() {
        let notFound = #"{"type":"error","error":{"type":"not_found","message":"No route for POST /v1/audio/transcriptions"}}"#

        XCTAssertEqual(map(401, openAIError(code: "authentication_error", type: "authentication_error")), .notAuthenticated)
        XCTAssertEqual(map(403, openAIError(code: "permission_error", type: "permission_error")), .notAuthenticated)
        // Von chatgpt.com durchgereicht (Proxy-Login war gültig) → kein „neu verbinden".
        XCTAssertEqual(map(403, openAIError(code: "upstream_error", type: "permission_error")), .upstreamRejected(statusCode: 403))
        XCTAssertEqual(map(401, openAIError(code: "upstream_error", type: "authentication_error")), .upstreamRejected(statusCode: 401))
        // Ohne lesbaren Code bleibt es beim Login-Hinweis.
        XCTAssertEqual(map(401, ""), .notAuthenticated)
        XCTAssertEqual(
            map(404, notFound, origin: .selfStarted),
            .routeDisabled(origin: .selfStarted, port: 18_765, version: "0.1.44")
        )
        XCTAssertEqual(
            map(404, notFound, origin: .external),
            .routeDisabled(origin: .external, port: 18_765, version: "0.1.44")
        )
        XCTAssertEqual(map(404, openAIError(code: "upstream_error")), .endpointGone(statusCode: 404))
        XCTAssertEqual(map(410, openAIError(code: "upstream_error")), .endpointGone(statusCode: 410))
        XCTAssertEqual(map(413, openAIError(code: "request_too_large")), .tooLarge)
        XCTAssertEqual(map(429, openAIError(code: "local_capacity_exceeded", type: "rate_limit_error")), .rateLimited(local: true))
        XCTAssertEqual(map(429, openAIError(code: "rate_limit_error", type: "rate_limit_error")), .rateLimited(local: false))
        XCTAssertEqual(
            map(400, openAIError(code: "invalid_request", message: "Unsupported multipart field 'response_format'")),
            .badRequest("Unsupported multipart field 'response_format'")
        )
        XCTAssertEqual(
            map(415, openAIError(code: "unsupported_media_type", message: "Transcription request must use multipart/form-data")),
            .badRequest("Transcription request must use multipart/form-data")
        )
        XCTAssertEqual(map(502, openAIError(code: "upstream_error", type: "api_error")), .upstreamUnavailable(statusCode: 502))
        XCTAssertEqual(map(503, openAIError(code: "transcriptions_api_unavailable", type: "api_error")), .upstreamUnavailable(statusCode: 503))
        XCTAssertEqual(map(504, ""), .upstreamUnavailable(statusCode: 504))
        // Kaputtes JSON: 404 gilt als fehlende Route, 400 übernimmt den Rohtext.
        XCTAssertEqual(map(404, "<html>nope"), .routeDisabled(origin: .selfStarted, port: 18_765, version: "0.1.44"))
        XCTAssertEqual(map(400, "{kaputt"), .badRequest("{kaputt"))
        XCTAssertEqual(map(400, ""), .badRequest("HTTP 400"))
    }

    func testNeedsInstanceOriginOnlyForMissingRoute() {
        XCTAssertTrue(ChatGPTTranscriptionErrorMapper.needsInstanceOrigin(statusCode: 404, body: #"{"error":{"type":"not_found"}}"#))
        XCTAssertFalse(ChatGPTTranscriptionErrorMapper.needsInstanceOrigin(statusCode: 404, body: openAIError(code: "upstream_error")))
        XCTAssertFalse(ChatGPTTranscriptionErrorMapper.needsInstanceOrigin(statusCode: 401, body: ""))
    }

    func testErrorDescriptionsAreGermanAndNonEmpty() {
        let cases: [(ChatGPTTranscriptionError, String)] = [
            (.featureDisabled, "deaktiviert"),
            (.backendDisabled, "GPT-Backend"),
            (.profileNotLoggedIn("work"), "nicht angemeldet"),
            (.proxyUnavailable("x"), "nicht gestartet"),
            (.notAuthenticated, "codex login"),
            (.upstreamRejected(statusCode: 403), "vorübergehend"),
            (.routeDisabled(origin: .external, port: 18_765, version: nil), "CCP_CODEX_TRANSCRIPTIONS_API=1"),
            (.routeDisabled(origin: .selfStarted, port: 18_765, version: "0.1.29"), "Neustart"),
            (.endpointGone(statusCode: 404), "weggefallen"),
            (.tooLarge, "25 MB"),
            (.rateLimited(local: true), "gleichzeitige"),
            (.rateLimited(local: false), "Limit"),
            (.badRequest("m"), "abgelehnt"),
            (.upstreamUnavailable(statusCode: 503), "nicht erreichbar"),
            (.network(URLError(.timedOut)), "Netzwerkfehler"),
        ]
        for (error, keyword) in cases {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty)
            XCTAssertTrue(description.contains(keyword), "\(error): \(description)")
        }
        XCTAssertTrue(
            ChatGPTTranscriptionError.routeDisabled(origin: .external, port: 18_765, version: nil)
                .errorDescription?.contains("18765") == true
        )
    }

    // MARK: - Prewarm

    private func prewarm(
        _ provider: TranscriptionProvider,
        _ dependencies: ChatGPTTranscriptionDependencies
    ) {
        let done = expectation(description: "prewarm")
        ChatGPTTranscriptionWarmup.prewarmIfNeeded(
            provider: provider,
            dependencies: dependencies,
            queue: .global(qos: .userInitiated),
            completion: { done.fulfill() }
        )
        wait(for: [done], timeout: 5)
    }

    func testPrewarmOnlyForChatGPTWithFeatureAndBackend() {
        let spy = Spy()
        prewarm(.groq, dependencies(spy: spy, portBeforeEnsure: nil))
        prewarm(.chatgpt, dependencies(spy: spy, featureEnabled: false, portBeforeEnsure: nil))
        prewarm(.chatgpt, dependencies(spy: spy, backendEnabled: false, portBeforeEnsure: nil))
        XCTAssertTrue(spy.ensureCalls.isEmpty)
    }

    func testPrewarmStartsProxyOnlyWhenNotReachable() {
        let reachableSpy = Spy()
        prewarm(.chatgpt, dependencies(spy: reachableSpy, reachable: true))
        XCTAssertTrue(reachableSpy.ensureCalls.isEmpty, "läuft schon → nichts tun")

        let downSpy = Spy()
        prewarm(.chatgpt, dependencies(spy: downSpy, profile: "work", reachable: false))
        XCTAssertEqual(downSpy.ensureCalls, ["work"])

        let unknownPortSpy = Spy()
        prewarm(.chatgpt, dependencies(spy: unknownPortSpy, profile: "work", portBeforeEnsure: nil))
        XCTAssertEqual(unknownPortSpy.ensureCalls, ["work"])
    }
}

/// Eigener URLProtocol-Stub (nicht `MockURLProtocol`), damit sich die
/// statischen Handler der beiden Testklassen nie in die Quere kommen.
final class ChatGPTStubURLProtocol: URLProtocol {
    enum Outcome {
        case response(HTTPURLResponse, Data)
        case failure(Error)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> Outcome)?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: ((URLRequest) -> Outcome)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch handler(request) {
        case .response(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
