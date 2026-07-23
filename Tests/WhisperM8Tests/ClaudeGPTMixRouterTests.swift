import Darwin
import Foundation
import Network
import XCTest
@testable import WhisperM8

final class ClaudeGPTMixRouterTests: XCTestCase {
    func testDispatchRoutesOnlyGPTPrefixToCodexProxy() {
        XCTAssertEqual(
            ClaudeGPTMixRouter.upstream(for: Data(#"{"model":"  GPT-5.6-SOL-FAST[1M]  "}"#.utf8)),
            .codexProxy
        )
        XCTAssertEqual(
            ClaudeGPTMixRouter.upstream(for: Data(#"{"model":"claude-fable-5"}"#.utf8)),
            .anthropic
        )
        XCTAssertEqual(
            ClaudeGPTMixRouter.upstream(for: Data(#"{"messages":[]}"#.utf8)),
            .anthropic
        )
        XCTAssertEqual(ClaudeGPTMixRouter.upstream(for: Data("kaputt".utf8)), .anthropic)
        XCTAssertEqual(ClaudeGPTMixRouter.upstream(for: Data()), .anthropic)
    }

    func testGPTModelGuardReturnsAnthropicInvalidRequestForNoncanonicalAndUnsupportedIDs() throws {
        let noncanonicalBody = try XCTUnwrap(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: " GPT-5.6-SOL-FAST[1M] ",
                contextWindow: 272_000
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: noncanonicalBody) as? [String: Any]
        )
        let error = try XCTUnwrap(object["error"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "error")
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
        XCTAssertTrue(
            try XCTUnwrap(error["message"] as? String).contains("gpt-5.6-sol-fast")
        )
        XCTAssertNotNil(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "gpt-5.3-codex-spark",
                contextWindow: 272_000
            )
        )
        XCTAssertNotNil(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "gpt-5.6-orbit",
                contextWindow: 272_000
            )
        )
        XCTAssertNil(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "gpt-5.6-sol",
                contextWindow: 372_000
            )
        )
        let extendedTerraBody = try XCTUnwrap(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "gpt-5.6-terra",
                contextWindow: 372_000
            )
        )
        XCTAssertTrue(
            String(decoding: extendedTerraBody, as: UTF8.self)
                .contains("verified only for gpt-5.6-sol")
        )
        XCTAssertNotNil(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "gpt-5.6-sol",
                contextWindow: 372_001
            )
        )
        XCTAssertNotNil(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "gpt-5.4-mini-fast",
                contextWindow: 250_000
            )
        )
        XCTAssertNil(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "gpt-5.4-mini",
                contextWindow: 250_000
            )
        )
        XCTAssertNil(
            ClaudeGPTMixRouter.gptModelValidationErrorResponse(
                for: "claude-opus-4-8[1m]",
                contextWindow: 272_000
            )
        )
    }

    func testContentEncodingGuardAllowsOnlyIdentity() {
        XCTAssertFalse(ClaudeGPTMixRouter.hasUnsupportedContentEncoding([]))
        XCTAssertFalse(ClaudeGPTMixRouter.hasUnsupportedContentEncoding([
            .init(name: "Content-Encoding", value: "identity"),
        ]))
        XCTAssertTrue(ClaudeGPTMixRouter.hasUnsupportedContentEncoding([
            .init(name: "content-encoding", value: "gzip"),
        ]))
    }

    func testContentTypeProbeGateRequiresExactEventStreamMediaType() {
        XCTAssertTrue(ClaudeGPTMixRouter.isEventStreamContentType("text/event-stream"))
        XCTAssertTrue(ClaudeGPTMixRouter.isEventStreamContentType(" Text/Event-Stream ; charset=utf-8"))
        XCTAssertFalse(ClaudeGPTMixRouter.isEventStreamContentType(nil))
        XCTAssertFalse(ClaudeGPTMixRouter.isEventStreamContentType("application/json"))
        XCTAssertFalse(ClaudeGPTMixRouter.isEventStreamContentType("application/x-text/event-streamish"))
    }

    func testUpstreamErrorDiagnosticsClassifiesContext4xxWithoutRetainingMessage() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Maximum context length exceeded for private prompt contents"}}"#.utf8)

        XCTAssertEqual(
            ClaudeGPTMixRouter.upstreamErrorDiagnostics(from: body),
            .init(
                errorType: "invalid_request_error",
                errorCode: "context_length_exceeded",
                isContextLimit: true,
                capturedBytes: body.count
            )
        )
    }

    func testAnthropicHeadersKeepCredentialsAndReplaceHopByHopHeaders() {
        let hopByHop = [
            "Connection", "keep-alive", "Proxy-Authenticate", "proxy-authorization",
            "TE", "Trailers", "Transfer-Encoding", "Upgrade", "Host", "Content-Length",
        ]
        var headers = hopByHop.map {
            ClaudeGPTMixRouter.HTTPHeader(name: $0, value: "entfernen")
        }
        headers.append(.init(name: "Authorization", value: "Bearer abo-oauth"))
        headers.append(.init(name: "X-API-Key", value: "anthropic-key"))
        headers.append(.init(name: "anthropic-beta", value: "oauth-2025-04-20"))
        headers.append(.init(name: "Anthropic-Version", value: "2023-06-01"))

        let result = ClaudeGPTMixRouter.upstreamHeaders(
            from: headers,
            upstream: .anthropic,
            host: "api.anthropic.com",
            bodyLength: 17
        )

        XCTAssertEqual(result, [
            .init(name: "Authorization", value: "Bearer abo-oauth"),
            .init(name: "X-API-Key", value: "anthropic-key"),
            .init(name: "anthropic-beta", value: "oauth-2025-04-20"),
            .init(name: "Anthropic-Version", value: "2023-06-01"),
            .init(name: "Host", value: "api.anthropic.com"),
            .init(name: "Content-Length", value: "17"),
        ])
    }

    func testUpstreamHeadersDropClientAcceptEncoding() {
        // URLSession dekomprimiert transparent — auch wenn der Request ein
        // eigenes Accept-Encoding traegt. Der Client-Header darf deshalb NICHT
        // upstream weitergereicht werden, sonst kommt Klartext mit
        // "Content-Encoding: gzip" beim Client an (ZlibError in Claude Code).
        let headers: [ClaudeGPTMixRouter.HTTPHeader] = [
            .init(name: "accept-encoding", value: "gzip, br"),
            .init(name: "Content-Type", value: "application/json"),
        ]

        XCTAssertEqual(
            ClaudeGPTMixRouter.upstreamHeaders(
                from: headers,
                upstream: .anthropic,
                host: "api.anthropic.com",
                bodyLength: 0
            ),
            [
                .init(name: "Content-Type", value: "application/json"),
                .init(name: "Host", value: "api.anthropic.com"),
            ]
        )
    }

    func testResponseHeadersStripContentEncodingAndHopByHop() {
        let headers: [ClaudeGPTMixRouter.HTTPHeader] = [
            .init(name: "Content-Encoding", value: "gzip"),
            .init(name: "Transfer-Encoding", value: "chunked"),
            .init(name: "Content-Type", value: "application/json"),
            .init(name: "anthropic-ratelimit-requests-remaining", value: "99"),
        ]

        XCTAssertEqual(
            ClaudeGPTMixRouter.responseHeaders(headers),
            [
                .init(name: "Content-Type", value: "application/json"),
                .init(name: "anthropic-ratelimit-requests-remaining", value: "99"),
            ]
        )
    }

    func testCodexHeadersStripAllAnthropicCredentialsCaseInsensitively() {
        let headers: [ClaudeGPTMixRouter.HTTPHeader] = [
            .init(name: "AUTHORIZATION", value: "Bearer abo-oauth"),
            .init(name: "x-Api-Key", value: "anthropic-key"),
            .init(name: "anthropic-beta", value: "oauth-2025-04-20"),
            .init(name: "Anthropic-Version", value: "2023-06-01"),
            .init(name: "ANTHROPIC-DANGEROUS-DIRECT-BROWSER-ACCESS", value: "true"),
            .init(name: "Content-Type", value: "application/json"),
        ]

        XCTAssertEqual(
            ClaudeGPTMixRouter.upstreamHeaders(
                from: headers,
                upstream: .codexProxy,
                host: "127.0.0.1:18765",
                bodyLength: 9
            ),
            [
                .init(name: "Content-Type", value: "application/json"),
                .init(name: "Host", value: "127.0.0.1:18765"),
                .init(name: "Content-Length", value: "9"),
            ]
        )
    }

    func testHeaderFilterRemovesTokensNamedByConnectionHeader() {
        let headers: [ClaudeGPTMixRouter.HTTPHeader] = [
            .init(name: "Connection", value: "keep-alive, X-Trace, x-private"),
            .init(name: "X-Trace", value: "entfernen"),
            .init(name: "X-PRIVATE", value: "auch entfernen"),
            .init(name: "Content-Type", value: "application/json"),
        ]

        XCTAssertEqual(
            ClaudeGPTMixRouter.filteredHeaders(headers),
            [.init(name: "Content-Type", value: "application/json")]
        )
    }

    func testRequestHeadParserReadsRequestLineHeadersAndContentLength() throws {
        let result = ClaudeGPTMixRouter.parseRequestHead(Data(
            "POST /v1/messages?beta=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 12\r\nanthropic-version: 2023-06-01".utf8
        ))
        let head = try result.get()

        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.target, "/v1/messages?beta=1")
        XCTAssertEqual(head.version, "HTTP/1.1")
        XCTAssertEqual(head.contentLength, 12)
        XCTAssertEqual(head.headers.last, .init(name: "anthropic-version", value: "2023-06-01"))
    }

    func testRequestHeadParserDefaultsMissingContentLengthToZero() throws {
        let result = ClaudeGPTMixRouter.parseRequestHead(Data(
            "GET /v1/messages/count_tokens HTTP/1.1\r\nHost: localhost".utf8
        ))

        XCTAssertEqual(try result.get().contentLength, 0)
    }

    func testRequestHeadParserRejectsChunkedRequestWith411Signal() {
        let result = ClaudeGPTMixRouter.parseRequestHead(Data(
            "POST /v1/messages HTTP/1.1\r\nTransfer-Encoding: chunked".utf8
        ))

        XCTAssertEqual(result, .failure(.lengthRequired))
    }

    func testRequestHeadParserRejectsInvalidOrConflictingLengths() {
        let invalid = ClaudeGPTMixRouter.parseRequestHead(Data(
            "POST /v1/messages HTTP/1.1\r\nContent-Length: nope".utf8
        ))
        let conflicting = ClaudeGPTMixRouter.parseRequestHead(Data(
            "POST /v1/messages HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3".utf8
        ))

        XCTAssertEqual(invalid, .failure(.badRequest))
        XCTAssertEqual(conflicting, .failure(.badRequest))
    }

    func testLaunchGuardPureDecisionSelectsRouterOrFallbackBuilderMode() {
        XCTAssertEqual(
            ClaudeGPTLaunchGuard.decision(
                for: .ready,
                hasGPTModelStamp: true,
                hasGPTSubagentModel: false
            ),
            ClaudeGPTLaunchDecision(usesRouter: true, presentsGPTFallbackAlert: false)
        )
        XCTAssertEqual(
            ClaudeGPTLaunchGuard.decision(
                for: .unavailable,
                hasGPTModelStamp: true,
                hasGPTSubagentModel: false
            ),
            ClaudeGPTLaunchDecision(usesRouter: false, presentsGPTFallbackAlert: true)
        )
        XCTAssertEqual(
            ClaudeGPTLaunchGuard.decision(
                for: .unavailable,
                hasGPTModelStamp: false,
                hasGPTSubagentModel: false
            ),
            ClaudeGPTLaunchDecision(usesRouter: false, presentsGPTFallbackAlert: false)
        )
        XCTAssertEqual(
            ClaudeGPTLaunchGuard.decision(
                for: .notNeeded,
                hasGPTModelStamp: true,
                hasGPTSubagentModel: true
            ),
            ClaudeGPTLaunchDecision(usesRouter: false, presentsGPTFallbackAlert: false)
        )
        XCTAssertEqual(
            ClaudeGPTLaunchGuard.decision(
                for: .unavailable,
                hasGPTModelStamp: false,
                hasGPTSubagentModel: true
            ),
            ClaudeGPTLaunchDecision(usesRouter: false, presentsGPTFallbackAlert: true)
        )
    }

    func testRouterDispatchesToBothLocalUpstreamsAndStreamsResponses() throws {
        let codexMock = try LocalHTTPMockServer(
            status: 201,
            responseChunks: [Data("data: codex-1\n\n".utf8), Data("data: codex-2\n\n".utf8)]
        )
        let anthropicMock = try LocalHTTPMockServer(
            status: 202,
            responseChunks: [Data("data: claude-1\n\n".utf8), Data("data: claude-2\n\n".utf8)]
        )
        defer {
            codexMock.stop()
            anthropicMock.stop()
        }

        let router = ClaudeGPTMixRouter(
            codexProxyURL: URL(string: "http://127.0.0.1:\(codexMock.port)")!,
            anthropicURL: URL(string: "http://127.0.0.1:\(anthropicMock.port)")!
        )
        try router.start(port: 0).get()
        defer { router.stop() }
        let routerPort = try XCTUnwrap(router.listeningPort)

        let gptBody = Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8)
        let gptResponse = try Self.sendRawRequest(
            port: routerPort,
            body: gptBody,
            authorization: "Bearer codex-client"
        )
        let claudeBody = Data(#"{"model":"claude-fable-5","messages":[]}"#.utf8)
        let claudeResponse = try Self.sendRawRequest(
            port: routerPort,
            body: claudeBody,
            authorization: "Bearer abo-oauth"
        )

        XCTAssertTrue(gptResponse.head.hasPrefix("HTTP/1.1 201"))
        XCTAssertTrue(gptResponse.head.localizedCaseInsensitiveContains("Transfer-Encoding: chunked"))
        XCTAssertEqual(gptResponse.body, Data("data: codex-1\n\ndata: codex-2\n\n".utf8))
        XCTAssertTrue(claudeResponse.head.hasPrefix("HTTP/1.1 202"))
        XCTAssertTrue(claudeResponse.head.localizedCaseInsensitiveContains("Transfer-Encoding: chunked"))
        XCTAssertEqual(claudeResponse.body, Data("data: claude-1\n\ndata: claude-2\n\n".utf8))

        XCTAssertEqual(codexMock.lastRequest?.path, "/v1/messages")
        XCTAssertEqual(codexMock.lastRequest?.jsonModel, "gpt-5.6-sol")
        XCTAssertNil(codexMock.lastRequest?.header(named: "authorization"))
        XCTAssertNil(codexMock.lastRequest?.header(named: "anthropic-beta"))
        XCTAssertEqual(anthropicMock.lastRequest?.path, "/v1/messages")
        XCTAssertEqual(anthropicMock.lastRequest?.jsonModel, "claude-fable-5")
        XCTAssertEqual(anthropicMock.lastRequest?.header(named: "authorization"), "Bearer abo-oauth")
        XCTAssertEqual(
            anthropicMock.lastRequest?.header(named: "anthropic-beta"),
            "oauth-2025-04-20"
        )
        XCTAssertEqual(
            anthropicMock.lastRequest?.header(named: "host"),
            "127.0.0.1:\(anthropicMock.port)"
        )
    }

    func testRouterRejectsNoncanonicalGPTBeforeEitherUpstream() throws {
        let unusedUpstream = try LocalHTTPMockServer(status: 200, responseChunks: [])
        defer { unusedUpstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(unusedUpstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let body = Data(#"{"model":" GPT-5.6-TERRA-FAST[1M] ","messages":[]}"#.utf8)
        var request = Data(
            "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        request.append(body)
        let response = try Self.exchange(
            port: try XCTUnwrap(router.listeningPort),
            request: request
        )
        let text = String(decoding: response, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 400 Bad Request"), text)
        XCTAssertTrue(text.contains("invalid_request_error"), text)
        XCTAssertTrue(text.contains("gpt-5.6-terra-fast"), text)
        XCTAssertNil(unusedUpstream.lastRequest)

        let oldBody = Data(#"{"model":"gpt-5.3-codex-spark","messages":[]}"#.utf8)
        var oldRequest = Data(
            "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer must-not-reach-anthropic\r\nContent-Type: application/json\r\nContent-Length: \(oldBody.count)\r\nConnection: close\r\n\r\n".utf8
        )
        oldRequest.append(oldBody)
        let oldResponse = try Self.exchange(
            port: try XCTUnwrap(router.listeningPort),
            request: oldRequest
        )
        let oldText = String(decoding: oldResponse, as: UTF8.self)
        XCTAssertTrue(oldText.hasPrefix("HTTP/1.1 400 Bad Request"), oldText)
        XCTAssertTrue(oldText.contains("Unsupported GPT model"), oldText)
        XCTAssertNil(unusedUpstream.lastRequest)

        let miniFastBody = Data(#"{"model":"gpt-5.4-mini-fast","messages":[]}"#.utf8)
        var miniFastRequest = Data(
            "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(miniFastBody.count)\r\nConnection: close\r\n\r\n".utf8
        )
        miniFastRequest.append(miniFastBody)
        let miniFastResponse = try Self.exchange(
            port: try XCTUnwrap(router.listeningPort),
            request: miniFastRequest
        )
        let miniFastText = String(decoding: miniFastResponse, as: UTF8.self)
        XCTAssertTrue(miniFastText.hasPrefix("HTTP/1.1 400 Bad Request"), miniFastText)
        XCTAssertTrue(miniFastText.contains("gpt-5.4-mini"), miniFastText)
        XCTAssertNil(unusedUpstream.lastRequest)
    }

    func testRouterRejectsGzipRequestBodyBeforeModelParsingOrAuthRouting() throws {
        let unusedUpstream = try LocalHTTPMockServer(status: 200, responseChunks: [])
        defer { unusedUpstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(unusedUpstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let compressedBody = try Self.gzipCompress(
            Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8)
        )
        var request = Data(
            "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer must-not-fall-through\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: \(compressedBody.count)\r\nConnection: close\r\n\r\n".utf8
        )
        request.append(compressedBody)
        let response = try Self.exchange(
            port: try XCTUnwrap(router.listeningPort),
            request: request
        )
        let text = String(decoding: response, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 415 Unsupported Media Type"), text)
        XCTAssertTrue(text.contains("invalid_request_error"), text)
        XCTAssertNil(unusedUpstream.lastRequest)
    }

    func testRouterPassesThroughRealHTTP4xxWhileCollectingDiagnostics() throws {
        let errorBody = Data(#"{"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Maximum context window exceeded"}}"#.utf8)
        let upstream = try LocalHTTPMockServer(status: 400, responseChunks: [errorBody])
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let response = try Self.sendRawRequest(
            port: try XCTUnwrap(router.listeningPort),
            body: Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8),
            authorization: "Bearer ignored"
        )

        XCTAssertTrue(response.head.hasPrefix("HTTP/1.1 400"), response.head)
        XCTAssertEqual(response.body, errorBody)
    }

    func testRouterRejectsChunkedClientRequestWith411() throws {
        let unusedUpstream = try LocalHTTPMockServer(status: 200, responseChunks: [])
        defer { unusedUpstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(unusedUpstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let response = try Self.exchange(
            port: try XCTUnwrap(router.listeningPort),
            request: Data(
                "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n".utf8
            )
        )

        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 411"))
        XCTAssertNil(unusedUpstream.lastRequest)
    }

    func testRouterSendsExactlyOneResponseForMalformedRequestWithHalfClose() throws {
        let unusedUpstream = try LocalHTTPMockServer(status: 200, responseChunks: [])
        defer { unusedUpstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(unusedUpstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        // Kaputter Request-Head + Half-Close im selben Austausch: die
        // Receive-Schleife darf nach der ersten 400 keine zweite Response
        // auf denselben Socket schreiben.
        let response = try Self.exchange(
            port: try XCTUnwrap(router.listeningPort),
            request: Data("KAPUTT\r\n\r\n".utf8),
            halfCloseAfterSend: true
        )

        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 400"))
        XCTAssertEqual(
            text.components(separatedBy: "HTTP/1.1 400").count - 1,
            1,
            "Genau eine Response pro Socket"
        )
    }

    func testRouterDeliversPlaintextWhenUpstreamCompressesWithGzip() throws {
        // Reproduziert den QA-Befund „ZlibError bei Fable/Subagents": Upstream
        // antwortet gzip-komprimiert; URLSession dekodiert transparent. Der
        // Client muss Klartext OHNE Content-Encoding-Header bekommen — sonst
        // versucht Claude Code, Klartext zu entpacken.
        let plaintext = Data(#"{"id":"msg_1","content":"klartext"}"#.utf8)
        let gzipped = try Self.gzipCompress(plaintext)
        var raw = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: \(gzipped.count)\r\nConnection: close\r\n\r\n".utf8
        )
        raw.append(gzipped)
        let upstream = try LocalHTTPMockServer(status: 200, responseChunks: [], rawResponse: raw)
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let response = try Self.sendRawRequest(
            port: try XCTUnwrap(router.listeningPort),
            body: Data(#"{"model":"claude-fable-5","messages":[]}"#.utf8),
            authorization: "Bearer abo-oauth"
        )

        XCTAssertTrue(response.head.hasPrefix("HTTP/1.1 200"))
        XCTAssertFalse(
            response.head.localizedCaseInsensitiveContains("Content-Encoding"),
            "Content-Encoding darf nach transparenter Dekodierung nicht weitergereicht werden"
        )
        XCTAssertEqual(response.body, plaintext, "Client muss dekodierten Klartext erhalten")
    }

    func testRouterRewritesExactSyntheticOverflowOnceAndCancelsOriginalCompletion() throws {
        let stream = Data((
            "event: message_start\r\n"
                + #"data: {"type":"message_start","message":{"role":"assistant","content":[],"stop_reason":null,"stop_sequence":null}}"#
                + "\r\n\r\nevent: error\r\ndata: "
                + #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long"}}"#
                + "\r\n\r\n"
        ).utf8)
        let chunks = [
            Data(stream.prefix(7)),
            Data(stream.dropFirst(7).prefix(19)),
            Data(stream.dropFirst(26)),
        ]
        let upstream = try LocalHTTPMockServer(status: 200, responseChunks: chunks)
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(
            codexProxyURL: url,
            anthropicURL: url,
            gptContextWindow: 272_000
        )
        try router.start(port: 0).get()
        defer { router.stop() }

        let raw = try Self.exchangeMessage(
            port: try XCTUnwrap(router.listeningPort),
            model: "gpt-5.6-sol"
        )
        let response = try Self.splitResponse(raw)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        let text = String(decoding: raw, as: UTF8.self)

        XCTAssertTrue(response.head.hasPrefix("HTTP/1.1 400 Bad Request"), response.head)
        XCTAssertEqual(object["type"] as? String, "error")
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
        XCTAssertEqual(error["message"] as? String, "prompt is too long: 272001 tokens > 272000")
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 ").count - 1, 1)
        XCTAssertFalse(text.contains("502 Bad Gateway"))
        XCTAssertFalse(text.contains("Transfer-Encoding: chunked"))
    }

    func testRouterPassesSemanticTextThenSameErrorSentenceByteExactly() throws {
        let stream = Data((
            "event: message_start\n"
                + #"data: {"type":"message_start","message":{"role":"assistant","content":[]}}"#
                + "\n\nevent: content_block_start\n"
                + #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
                + "\n\nevent: content_block_delta\n"
                + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Prompt is too long"}}"#
                + "\n\nevent: error\ndata: "
                + #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long"}}"#
                + "\n\n"
        ).utf8)
        let upstream = try LocalHTTPMockServer(
            status: 200,
            responseChunks: [Data(stream.prefix(23)), Data(stream.dropFirst(23))]
        )
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let response = try Self.sendRawRequest(
            port: try XCTUnwrap(router.listeningPort),
            body: Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8),
            authorization: "Bearer ignored"
        )

        XCTAssertTrue(response.head.hasPrefix("HTTP/1.1 200"), response.head)
        XCTAssertEqual(response.body, stream)
    }

    func testProbeGateLeavesNonSSEAndAnthropicResponsesUnchanged() throws {
        let exactError = Data((
            "event: error\ndata: "
                + #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long"}}"#
                + "\n\n"
        ).utf8)

        let nonSSE = try LocalHTTPMockServer(
            status: 200,
            responseChunks: [exactError],
            contentType: "application/json"
        )
        defer { nonSSE.stop() }
        let nonSSEURL = URL(string: "http://127.0.0.1:\(nonSSE.port)")!
        let nonSSERouter = ClaudeGPTMixRouter(codexProxyURL: nonSSEURL, anthropicURL: nonSSEURL)
        try nonSSERouter.start(port: 0).get()
        let nonSSEResponse = try Self.sendRawRequest(
            port: try XCTUnwrap(nonSSERouter.listeningPort),
            body: Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8),
            authorization: "Bearer ignored"
        )
        nonSSERouter.stop()
        XCTAssertTrue(nonSSEResponse.head.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(nonSSEResponse.body, exactError)

        let anthropic = try LocalHTTPMockServer(status: 200, responseChunks: [exactError])
        defer { anthropic.stop() }
        let anthropicURL = URL(string: "http://127.0.0.1:\(anthropic.port)")!
        let anthropicRouter = ClaudeGPTMixRouter(
            codexProxyURL: anthropicURL,
            anthropicURL: anthropicURL
        )
        try anthropicRouter.start(port: 0).get()
        defer { anthropicRouter.stop() }
        let anthropicResponse = try Self.sendRawRequest(
            port: try XCTUnwrap(anthropicRouter.listeningPort),
            body: Data(#"{"model":"claude-fable-5","messages":[]}"#.utf8),
            authorization: "Bearer oauth"
        )
        XCTAssertTrue(anthropicResponse.head.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(anthropicResponse.body, exactError)
    }

    func testProbeCleanEOFWithoutMatchFlushesOriginalPrefixAndTerminator() throws {
        let prefix = Data((
            "event: message_start\n"
                + #"data: {"type":"message_start","message":{"role":"assistant","content":[]}}"#
                + "\n\n"
        ).utf8)
        let upstream = try LocalHTTPMockServer(status: 200, responseChunks: [prefix])
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let response = try Self.sendRawRequest(
            port: try XCTUnwrap(router.listeningPort),
            body: Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8),
            authorization: "Bearer ignored"
        )

        XCTAssertTrue(response.head.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(response.body, prefix)
    }

    func testTransportFailureDuringProbeReturnsSingle502() throws {
        let prefix = Data((
            "event: message_start\n"
                + #"data: {"type":"message_start","message":{"role":"assistant","content":[]}}"#
                + "\n\n"
        ).utf8)
        var truncated = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(prefix.count + 100)\r\nConnection: close\r\n\r\n".utf8
        )
        truncated.append(prefix)
        let upstream = try LocalHTTPMockServer(
            status: 200,
            responseChunks: [],
            rawResponse: truncated
        )
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let raw = try Self.exchangeMessage(
            port: try XCTUnwrap(router.listeningPort),
            model: "gpt-5.6-sol"
        )
        let text = String(decoding: raw, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 502 Bad Gateway"), text)
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 ").count - 1, 1)
        XCTAssertFalse(text.contains("HTTP/1.1 200"))
    }

    func testTransportFailureAfterPassThroughAbortsOriginal200WithoutSecondResponse() throws {
        let delta = Data((
            "event: content_block_delta\n"
                + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"visible"}}"#
                + "\n\n"
        ).utf8)
        let upstream = try LocalHTTPMockServer(
            status: 200,
            responseChunks: [delta],
            chunkDelay: 0.1,
            completion: .malformedChunk
        )
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let raw = try Self.exchangeMessage(
            port: try XCTUnwrap(router.listeningPort),
            model: "gpt-5.6-sol"
        )
        let text = String(decoding: raw, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        XCTAssertTrue(raw.range(of: delta) != nil)
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 ").count - 1, 1)
        XCTAssertFalse(text.contains("502 Bad Gateway"))
        XCTAssertFalse(raw.suffix(5) == Data("0\r\n\r\n".utf8))
    }

    func testProbeTimeoutFailsOpenAndFlushesDelayedErrorExactlyOnce() throws {
        let exactError = Data((
            "event: error\ndata: "
                + #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long"}}"#
                + "\n\n"
        ).utf8)
        let ping = Data(": keepalive\n\n".utf8)
        let upstream = try LocalHTTPMockServer(
            status: 200,
            responseChunks: [ping, exactError],
            firstChunkDelay: 0.01,
            chunkDelay: 1.2
        )
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let raw = try Self.exchangeMessage(
            port: try XCTUnwrap(router.listeningPort),
            model: "gpt-5.6-sol"
        )
        let split = try Self.splitResponse(raw)
        let decoded: Data
        do {
            decoded = try Self.decodeChunkedBody(split.body)
        } catch {
            XCTFail("ungueltiges Chunking nach Timeout: \(String(decoding: raw, as: UTF8.self))")
            return
        }

        var expected = ping
        expected.append(exactError)
        XCTAssertTrue(split.head.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(decoded, expected)
    }

    func testProbeBudgetExhaustionFailsOpen() throws {
        let exactError = Data((
            "event: error\ndata: "
                + #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long"}}"#
                + "\n\n"
        ).utf8)
        var acquired = 0
        while SyntheticOverflowProbeBudget.acquire() { acquired += 1 }
        defer {
            for _ in 0..<acquired { SyntheticOverflowProbeBudget.release() }
        }
        XCTAssertEqual(acquired, SyntheticOverflowProbeBudget.maximumActive)

        let upstream = try LocalHTTPMockServer(status: 200, responseChunks: [exactError])
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let response = try Self.sendRawRequest(
            port: try XCTUnwrap(router.listeningPort),
            body: Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8),
            authorization: "Bearer ignored"
        )

        XCTAssertTrue(response.head.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(response.body, exactError)
    }

    func testProbePrefixCapFlushesEveryByteOnce() throws {
        let largePrefix = Data(repeating: 0x78, count: CodexSyntheticOverflowProbe.maximumPrefixBytes + 31)
        let exactError = Data((
            "\n\nevent: error\ndata: "
                + #"{"type":"error","error":{"type":"api_error","message":"Prompt is too long"}}"#
                + "\n\n"
        ).utf8)
        var original = largePrefix
        original.append(exactError)
        let upstream = try LocalHTTPMockServer(status: 200, responseChunks: [original])
        defer { upstream.stop() }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url)
        try router.start(port: 0).get()
        defer { router.stop() }

        let response = try Self.sendRawRequest(
            port: try XCTUnwrap(router.listeningPort),
            body: Data(#"{"model":"gpt-5.6-sol","messages":[]}"#.utf8),
            authorization: "Bearer ignored"
        )

        XCTAssertTrue(response.head.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(response.body, original)
    }

    private static func gzipCompress(_ data: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(data)
        inputPipe.fileHandleForWriting.closeFile()
        let compressed = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !compressed.isEmpty else {
            throw TestHTTPError.invalidResponse
        }
        return compressed
    }

    private static func exchangeMessage(port: Int, model: String) throws -> Data {
        let body = Data(#"{"model":"\#(model)","messages":[]}"#.utf8)
        var request = Data(
            "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        request.append(body)
        return try exchange(port: port, request: request)
    }

    private static func splitResponse(_ response: Data) throws -> (head: String, body: Data) {
        guard let delimiter = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw TestHTTPError.invalidResponse
        }
        return (
            String(decoding: response[..<delimiter.lowerBound], as: UTF8.self),
            Data(response[delimiter.upperBound...])
        )
    }

    private static func sendRawRequest(
        port: Int,
        body: Data,
        authorization: String
    ) throws -> (head: String, body: Data) {
        var request = Data(
            "POST /v1/messages HTTP/1.1\r\nHost: stale.example\r\nAuthorization: \(authorization)\r\nanthropic-beta: oauth-2025-04-20\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        request.append(body)
        let response = try exchange(port: port, request: request)
        guard let delimiter = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw TestHTTPError.invalidResponse
        }
        let head = String(decoding: response[..<delimiter.lowerBound], as: UTF8.self)
        let encodedBody = Data(response[delimiter.upperBound...])
        return (head, try decodeChunkedBody(encodedBody))
    }

    private static func exchange(
        port: Int,
        request: Data,
        halfCloseAfterSend: Bool = false
    ) throws -> Data {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw TestHTTPError.socketFailed }
        defer { close(fileDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw TestHTTPError.socketFailed
        }
        let didConnect = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didConnect == 0 else { throw TestHTTPError.socketFailed }

        try request.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fileDescriptor, baseAddress.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw TestHTTPError.socketFailed }
                sent += count
            }
        }
        if halfCloseAfterSend {
            shutdown(fileDescriptor, SHUT_WR)
        }

        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.recv(fileDescriptor, &bytes, bytes.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw TestHTTPError.socketFailed }
            response.append(contentsOf: bytes.prefix(count))
        }
        return response
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        var remaining = data
        var body = Data()
        let lineDelimiter = Data("\r\n".utf8)
        while true {
            guard let lineRange = remaining.range(of: lineDelimiter) else {
                throw TestHTTPError.invalidResponse
            }
            let line = String(decoding: remaining[..<lineRange.lowerBound], as: UTF8.self)
            guard let length = Int(line, radix: 16) else { throw TestHTTPError.invalidResponse }
            remaining.removeSubrange(..<lineRange.upperBound)
            if length == 0 { return body }
            guard remaining.count >= length + 2 else { throw TestHTTPError.invalidResponse }
            body.append(remaining.prefix(length))
            remaining.removeSubrange(..<remaining.index(remaining.startIndex, offsetBy: length + 2))
        }
    }
}

private enum TestHTTPError: Error {
    case socketFailed
    case invalidResponse
}

private final class LocalHTTPMockServer {
    enum Completion: Equatable {
        case clean
        case abort
        case malformedChunk
    }

    struct Request {
        var path: String
        var headers: [ClaudeGPTMixRouter.HTTPHeader]
        var body: Data

        var jsonModel: String? { ClaudeGPTMixRouter.model(in: body) }

        func header(named name: String) -> String? {
            headers.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }?.value
        }
    }

    private let status: Int
    private let responseChunks: [Data]
    private let rawResponse: Data?
    private let contentType: String
    private let firstChunkDelay: TimeInterval
    private let chunkDelay: TimeInterval
    private let completion: Completion
    private let queue = DispatchQueue(label: "com.whisperm8.tests.http-mock")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var lastRequestStorage: Request?
    private(set) var port: Int = 0

    var lastRequest: Request? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestStorage
    }

    init(
        status: Int,
        responseChunks: [Data],
        rawResponse: Data? = nil,
        contentType: String = "text/event-stream",
        firstChunkDelay: TimeInterval = 0.01,
        chunkDelay: TimeInterval = 0.01,
        completion: Completion = .clean
    ) throws {
        self.status = status
        self.responseChunks = responseChunks
        self.rawResponse = rawResponse
        self.contentType = contentType
        self.firstChunkDelay = firstChunkDelay
        self.chunkDelay = chunkDelay
        self.completion = completion

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var resolvedPort: Int?
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state {
                resolvedPort = listener?.port.map { Int($0.rawValue) }
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let resolvedPort else {
            listener.cancel()
            throw TestHTTPError.socketFailed
        }
        port = resolvedPort
    }

    func stop() {
        lock.lock()
        let connections = self.connections
        self.connections.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }
            if let request = self.parseRequest(nextBuffer) {
                self.lock.lock()
                self.lastRequestStorage = request
                self.lock.unlock()
                if let rawResponse = self.rawResponse {
                    // Vorgefertigte Antwort byte-genau senden (z. B. echtes
                    // gzip mit Content-Encoding-Header), dann schliessen.
                    connection.send(content: rawResponse, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else {
                    self.sendResponse(connection: connection, chunkIndex: -1)
                }
            } else if error == nil, !isComplete {
                self.receive(connection: connection, buffer: nextBuffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func parseRequest(_ data: Data) -> Request? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter) else { return nil }
        let headData = Data(data[..<range.lowerBound])
        guard case .success(let head) = ClaudeGPTMixRouter.parseRequestHead(headData) else {
            return nil
        }
        let body = Data(data[range.upperBound...])
        guard body.count >= head.contentLength else { return nil }
        return Request(
            path: head.target,
            headers: head.headers,
            body: Data(body.prefix(head.contentLength))
        )
    }

    private func sendResponse(connection: NWConnection, chunkIndex: Int) {
        if chunkIndex >= responseChunks.count {
            switch completion {
            case .abort:
                connection.cancel()
                return
            case .malformedChunk:
                connection.send(
                    content: Data("not-a-chunk-size\r\n".utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            case .clean:
                break
            }
        }

        let content: Data
        let nextIndex: Int
        if chunkIndex == -1 {
            content = Data(
                "HTTP/1.1 \(status) Mock\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8
            )
            nextIndex = 0
        } else if chunkIndex < responseChunks.count {
            let body = responseChunks[chunkIndex]
            var framed = Data("\(String(body.count, radix: 16))\r\n".utf8)
            framed.append(body)
            framed.append(Data("\r\n".utf8))
            content = framed
            nextIndex = chunkIndex + 1
        } else {
            content = Data("0\r\n\r\n".utf8)
            nextIndex = responseChunks.count + 1
        }

        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || nextIndex > self.responseChunks.count {
                connection.cancel()
                return
            }
            let delay = nextIndex == 0 ? self.firstChunkDelay : self.chunkDelay
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.sendResponse(connection: connection, chunkIndex: nextIndex)
            }
        })
    }
}
