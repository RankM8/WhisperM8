import Foundation
import XCTest
@testable import WhisperM8

/// Diktat-Nacharbeit über das GPT-Backend: Form der Anfrage, Antwort- und
/// Fehlerauswertung, Proxy-Start mit einem zweiten Versuch und Abbruch.
/// Ohne Netz (eigener URLProtocol-Stub) und ohne echten Proxy.
final class GPTBackendPostProcessorTests: XCTestCase {
    override func tearDown() {
        GPTBackendStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Hilfen

    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _ensureCalls: [String?] = []
        private var _ensured = false
        var ensureCalls: [String?] { lock.withLock { _ensureCalls } }
        var ensured: Bool { lock.withLock { _ensured } }
        func recordEnsure(_ profile: String?) { lock.withLock { _ensureCalls.append(profile); _ensured = true } }
    }

    private func dependencies(
        spy: Spy = Spy(),
        backendEnabled: Bool = true,
        profile: String? = "office",
        portBeforeEnsure: Int? = 18_775,
        ensureResult: Result<Void, ClaudeCodeProxyError> = .success(()),
        proxyModels: Set<String>? = ["gpt-6.1-sol"],
        supportsFast: Bool = true
    ) -> GPTBackendPostProcessingDependencies {
        GPTBackendPostProcessingDependencies(
            isBackendEnabled: { backendEnabled },
            activeProfile: { profile },
            knownPort: { _ in spy.ensured ? 18_775 : portBeforeEnsure },
            ensureRunning: { profile in
                spy.recordEnsure(profile)
                return ensureResult
            },
            proxyModels: { proxyModels },
            supportsFast: { _ in supportsFast },
            sessionProvider: { _ in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [GPTBackendStubURLProtocol.self]
                return URLSession(configuration: configuration)
            }
        )
    }

    private func processor(_ dependencies: GPTBackendPostProcessingDependencies, registry: GPTBackendRunRegistry = GPTBackendRunRegistry()) -> GPTBackendPostProcessor {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString).json")
        return GPTBackendPostProcessor(
            templateStore: PostProcessingTemplateStore(fileURL: missing),
            dependencies: dependencies,
            registry: registry,
            visualInputModeRaw: { CodexVisualInputMode.defaultMode.rawValue }
        )
    }

    private func cleanMode(tier: CodexServiceTier = .fast, effort: String = "low") -> OutputMode {
        OutputMode(
            id: OutputMode.cleanID,
            name: "Clean",
            shortLabel: "Clean",
            kind: .builtIn,
            templateID: PostProcessingTemplate.cleanID,
            isEnabled: true,
            isDefault: false,
            codexModelRawOverride: "gpt-6.1-sol",
            codexReasoningEffortRawOverride: effort,
            codexServiceTierRawOverride: tier.rawValue
        )
    }

    private static func ok(_ request: URLRequest, text: String) -> GPTBackendStubURLProtocol.Outcome {
        let body = #"{"content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn"}"#
        return .response(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private static func status(_ request: URLRequest, _ code: Int, _ body: String) -> GPTBackendStubURLProtocol.Outcome {
        .response(HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    // MARK: - Pure Bausteine

    func testRequestBodyIsOneUserTurnWithTextImagesAndEffort() throws {
        let image = GPTBackendImage(data: Data([1, 2, 3]), mediaType: "image/png")
        let data = try GPTBackendPostProcessor.requestBody(prompt: "Hallo", images: [image], model: "gpt-6.1-sol-fast", effort: "low")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gpt-6.1-sol-fast")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "low")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "Hallo")
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    func testUnknownEffortIsLeftOut() throws {
        let data = try GPTBackendPostProcessor.requestBody(prompt: "x", images: [], model: "gpt-6.1-sol", effort: "minimal")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["output_config"])
    }

    func testResponseTextJoinsTextBlocksAndSkipsThinking() {
        let data = Data(#"{"content":[{"type":"thinking","thinking":"geheim"},{"type":"text","text":"Hallo "},{"type":"text","text":"Welt\n"}]}"#.utf8)
        XCTAssertEqual(GPTBackendPostProcessor.responseText(from: data), "Hallo Welt")
        XCTAssertNil(GPTBackendPostProcessor.responseText(from: Data(#"{"content":[{"type":"text","text":"  "}]}"#.utf8)))
        XCTAssertNil(GPTBackendPostProcessor.responseText(from: Data("kein json".utf8)))
    }

    func testHTTPMapping() {
        XCTAssertEqual(GPTBackendPostProcessor.mapHTTP(statusCode: 401, body: Data()), .notAuthenticated)
        XCTAssertEqual(
            GPTBackendPostProcessor.mapHTTP(statusCode: 403, body: Data(#"{"error":{"code":"upstream_error","message":"nein"}}"#.utf8)),
            .http(statusCode: 403, message: "nein")
        )
        XCTAssertEqual(GPTBackendPostProcessor.mapHTTP(statusCode: 429, body: Data()), .rateLimited)
        XCTAssertEqual(GPTBackendPostProcessor.mapHTTP(statusCode: 502, body: Data()), .http(statusCode: 502, message: "HTTP 502"))
    }

    func testModelResolutionUsesFastAliasAndRejectsUnknownModels() throws {
        XCTAssertEqual(try GPTBackendPostProcessor.resolveModel(mode: cleanMode(tier: .fast), dependencies: dependencies()), "gpt-6.1-sol-fast")
        XCTAssertEqual(try GPTBackendPostProcessor.resolveModel(mode: cleanMode(tier: .standard), dependencies: dependencies()), "gpt-6.1-sol")
        XCTAssertEqual(
            try GPTBackendPostProcessor.resolveModel(mode: cleanMode(tier: .fast), dependencies: dependencies(supportsFast: false)),
            "gpt-6.1-sol"
        )
        // Liste des Proxys unbekannt: trotzdem versuchen.
        XCTAssertEqual(try GPTBackendPostProcessor.resolveModel(mode: cleanMode(tier: .standard), dependencies: dependencies(proxyModels: nil)), "gpt-6.1-sol")
        XCTAssertThrowsError(try GPTBackendPostProcessor.resolveModel(mode: cleanMode(), dependencies: dependencies(proxyModels: ["gpt-5.6-sol"]))) { error in
            XCTAssertEqual(error as? GPTBackendPostProcessingError, .modelUnavailable("gpt-6.1-sol"))
        }
    }

    func testImageMediaTypes() {
        XCTAssertEqual(GPTBackendImage.mediaType(for: URL(fileURLWithPath: "/a.JPG")), "image/jpeg")
        XCTAssertEqual(GPTBackendImage.mediaType(for: URL(fileURLWithPath: "/a.webp")), "image/webp")
        XCTAssertEqual(GPTBackendImage.mediaType(for: URL(fileURLWithPath: "/a.png")), "image/png")
    }

    // MARK: - Ablauf

    func testSuccessfulRunPostsToInstancePortAndNamesEngineAndAccount() async throws {
        GPTBackendStubURLProtocol.handler = { Self.ok($0, text: "Sauberer Text") }
        let run = try await processor(dependencies()).processRun(rawText: "äh sauber", mode: cleanMode(), language: "de", contextBundle: .empty)

        XCTAssertEqual(run.text, "Sauberer Text")
        XCTAssertEqual(run.engine, .gptBackend)
        XCTAssertEqual(run.gptProfile, "office")
        let request = try XCTUnwrap(GPTBackendStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18775/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testBackendOffThrowsWithoutRequest() async {
        do {
            _ = try await processor(dependencies(backendEnabled: false)).processRun(rawText: "x", mode: cleanMode(), language: "de", contextBundle: .empty)
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual(error as? GPTBackendPostProcessingError, .backendDisabled)
        }
        XCTAssertTrue(GPTBackendStubURLProtocol.requests.isEmpty)
    }

    func testUnknownPortStartsProxyFirst() async throws {
        let spy = Spy()
        GPTBackendStubURLProtocol.handler = { Self.ok($0, text: "ok") }
        let run = try await processor(dependencies(spy: spy, portBeforeEnsure: nil)).processRun(rawText: "x", mode: cleanMode(), language: "de", contextBundle: .empty)
        XCTAssertEqual(run.text, "ok")
        XCTAssertEqual(spy.ensureCalls, ["office"])
    }

    func testConnectionRefusedStartsProxyOnceAndRetries() async throws {
        let spy = Spy()
        var attempts = 0
        GPTBackendStubURLProtocol.handler = { request in
            attempts += 1
            return attempts == 1 ? .failure(URLError(.cannotConnectToHost)) : Self.ok(request, text: "zweiter Versuch")
        }
        let run = try await processor(dependencies(spy: spy)).processRun(rawText: "x", mode: cleanMode(), language: "de", contextBundle: .empty)
        XCTAssertEqual(run.text, "zweiter Versuch")
        XCTAssertEqual(spy.ensureCalls, ["office"])
        XCTAssertEqual(GPTBackendStubURLProtocol.requests.count, 2)
    }

    func testProfileNotLoggedInIsNamed() async {
        do {
            _ = try await processor(dependencies(portBeforeEnsure: nil, ensureResult: .failure(.profileNotLoggedIn("office"))))
                .processRun(rawText: "x", mode: cleanMode(), language: "de", contextBundle: .empty)
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual(error as? GPTBackendPostProcessingError, .profileNotLoggedIn("office"))
        }
    }

    func testHTTPErrorAndEmptyAnswerAreBackendErrors() async {
        GPTBackendStubURLProtocol.handler = { Self.status($0, 429, #"{"error":{"type":"rate_limit_error"}}"#) }
        do {
            _ = try await processor(dependencies()).processRun(rawText: "x", mode: cleanMode(), language: "de", contextBundle: .empty)
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual(error as? GPTBackendPostProcessingError, .rateLimited)
        }

        GPTBackendStubURLProtocol.handler = { Self.status($0, 200, #"{"content":[]}"#) }
        do {
            _ = try await processor(dependencies()).processRun(rawText: "x", mode: cleanMode(), language: "de", contextBundle: .empty)
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual(error as? GPTBackendPostProcessingError, .emptyResponse)
        }
    }

    func testTimeoutBecomesTimedOut() {
        XCTAssertEqual(GPTBackendPostProcessor.map(URLError(.timedOut)) as? PostProcessingError, .timedOut(GPTBackendPostProcessor.timeout))
        XCTAssertTrue(GPTBackendPostProcessor.map(URLError(.cancelled)) is CancellationError)
        XCTAssertEqual(
            GPTBackendPostProcessor.map(URLError(.notConnectedToInternet)) as? GPTBackendPostProcessingError,
            .network(URLError(.notConnectedToInternet))
        )
    }

    func testCancelButtonEndsRunAsUserCancelled() async throws {
        let registry = GPTBackendRunRegistry()
        let started = expectation(description: "Anfrage läuft")
        GPTBackendStubURLProtocol.handler = { _ in
            started.fulfill()
            return .hang
        }
        let processor = processor(dependencies(), registry: registry)
        let run = Task {
            try await processor.processRun(rawText: "x", mode: cleanMode(), language: "de", contextBundle: .empty)
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertFalse(registry.cancel(owner: .testLab), "Fremder Besitzer darf den Diktat-Lauf nicht treffen")
        XCTAssertTrue(registry.cancel(owner: .dictation))

        do {
            _ = try await run.value
            XCTFail("Abbruch erwartet")
        } catch {
            XCTAssertEqual(error as? PostProcessingError, .userCancelled)
        }
    }
}

/// Eigener URLProtocol-Stub, damit sich die statischen Handler der
/// Testklassen nie in die Quere kommen.
final class GPTBackendStubURLProtocol: URLProtocol {
    enum Outcome {
        case response(HTTPURLResponse, Data)
        case failure(Error)
        /// Keine Antwort, bis die Anfrage abgebrochen wird.
        case hang
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> Outcome)?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: ((URLRequest) -> Outcome)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

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
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}
