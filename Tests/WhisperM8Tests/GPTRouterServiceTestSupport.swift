import Darwin
import Foundation
import Network
import XCTest
@testable import WhisperM8

/// Upstream für Router-Dienst-Tests: antwortet jedem Request mit einem
/// SSE-Strom aus `chunkCount` Stücken im Abstand `chunkDelay`. Mehrere
/// Verbindungen gleichzeitig.
final class SlowStreamUpstream {
    let chunkCount: Int
    let chunkDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.whisperm8.tests.slow-upstream")
    private var listener: NWListener?
    private(set) var port = 0
    private let lock = NSLock()
    private var requestCount = 0

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    init(chunkCount: Int, chunkDelay: TimeInterval) throws {
        self.chunkCount = chunkCount
        self.chunkDelay = chunkDelay
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var resolved: Int?
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state {
                resolved = listener?.port.map { Int($0.rawValue) }
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let resolved else {
            listener.cancel()
            throw GPTRouterTestError.setup("upstream")
        }
        self.listener = listener
        port = resolved
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static func expectedBody(chunkCount: Int) -> Data {
        Data((0..<chunkCount).map { "data: chunk-\($0)\n\n" }.joined().utf8)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }
            if let range = next.range(of: Data("\r\n\r\n".utf8)),
               case .success(let head) = ClaudeGPTMixRouter.parseRequestHead(Data(next[..<range.lowerBound])),
               next.count - range.upperBound >= head.contentLength {
                self.lock.lock()
                self.requestCount += 1
                self.lock.unlock()
                let headData = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: headData, completion: .contentProcessed { _ in
                    self.sendChunk(connection, index: 0)
                })
            } else if error == nil, !done {
                self.receive(connection, buffer: next)
            } else {
                connection.cancel()
            }
        }
    }

    private func sendChunk(_ connection: NWConnection, index: Int) {
        guard index < chunkCount else {
            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let body = Data("data: chunk-\(index)\n\n".utf8)
        var framed = Data("\(String(body.count, radix: 16))\r\n".utf8)
        framed.append(body)
        framed.append(Data("\r\n".utf8))
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.queue.asyncAfter(deadline: .now() + self.chunkDelay) {
                self.sendChunk(connection, index: index + 1)
            }
        })
    }
}

enum GPTRouterTestError: Error {
    case setup(String)
    case socket(Int32)
    case response(String)
}

enum GPTRouterTestClient {
    /// Ein Claude-Request über den Router; liefert Statuszeile und den
    /// entpackten Körper. Blockiert bis zum Ende der Antwort.
    static func stream(port: Int, model: String = "claude-fable-5", timeout: TimeInterval = 30) throws -> (status: String, body: Data) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GPTRouterTestError.socket(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        ClaudeGPTRouterWire.setTimeout(fd, timeout)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw GPTRouterTestError.socket(errno) }
        let body = Data("{\"model\":\"\(model)\",\"messages\":[]}".utf8)
        var request = Data("POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { throw GPTRouterTestError.socket(errno) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw GPTRouterTestError.socket(errno) }
            response.append(contentsOf: buffer.prefix(count))
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw GPTRouterTestError.response("kein Kopf (\(response.count) Bytes)")
        }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        let status = head.components(separatedBy: "\r\n").first ?? ""
        return (status, try decodeChunked(Data(response[split.upperBound...])))
    }

    static func decodeChunked(_ data: Data) throws -> Data {
        var remaining = data
        var body = Data()
        while true {
            guard let line = remaining.range(of: Data("\r\n".utf8)),
                  let length = Int(String(decoding: remaining[..<line.lowerBound], as: UTF8.self), radix: 16) else {
                throw GPTRouterTestError.response("Chunk-Kopf fehlt (Strom abgerissen?)")
            }
            remaining.removeSubrange(..<line.upperBound)
            if length == 0 { return body }
            guard remaining.count >= length + 2 else { throw GPTRouterTestError.response("Chunk unvollständig") }
            body.append(remaining.prefix(length))
            remaining.removeSubrange(..<remaining.index(remaining.startIndex, offsetBy: length + 2))
        }
    }

    /// Kurzer Ordner unter /tmp (Unix-Socket-Pfade sind auf 104 Byte begrenzt).
    static func makeRoot() -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/wm8gr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Freier Port (bind auf 0, wieder schließen).
    static func freePort() -> Int {
        guard let fd = try? ClaudeGPTRouterSocketListener.bind(port: 0) else { return 0 }
        defer { close(fd) }
        return ClaudeGPTRouterSocketListener.listeningPort(of: fd) ?? 0
    }
}
