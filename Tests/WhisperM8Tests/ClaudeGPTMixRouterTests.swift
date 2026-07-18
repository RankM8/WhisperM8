import Darwin
import Foundation
import Network
import XCTest
@testable import WhisperM8

final class ClaudeGPTMixRouterTests: XCTestCase {
    func testDispatchRoutesOnlyGPTPrefixToCodexProxy() {
        XCTAssertEqual(
            ClaudeGPTMixRouter.upstream(for: Data(#"{"model":"gpt-5.6-sol"}"#.utf8)),
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

    init(status: Int, responseChunks: [Data], rawResponse: Data? = nil) throws {
        self.status = status
        self.responseChunks = responseChunks
        self.rawResponse = rawResponse

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
        let content: Data
        let nextIndex: Int
        if chunkIndex == -1 {
            content = Data(
                "HTTP/1.1 \(status) Mock\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8
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
            self.queue.asyncAfter(deadline: .now() + 0.01) {
                self.sendResponse(connection: connection, chunkIndex: nextIndex)
            }
        })
    }
}
