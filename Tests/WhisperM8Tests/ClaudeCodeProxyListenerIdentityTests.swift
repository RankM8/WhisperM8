import Darwin
import XCTest
@testable import WhisperM8

/// LR-GPT-002: Ein Listener, der /healthz nachahmt, ist kein Proxy.
final class ClaudeCodeProxyListenerIdentityTests: XCTestCase {
    func testVerdictAcceptsOnlyProxyProgramName() {
        XCTAssertEqual(ClaudeCodeProxyListenerIdentity.verdict(forListenerPath: "/x/bin/claude-code-proxy"), .trusted)
        XCTAssertEqual(ClaudeCodeProxyListenerIdentity.verdict(forListenerPath: "/usr/bin/python3"), .foreignProgram("python3"))
        XCTAssertEqual(ClaudeCodeProxyListenerIdentity.verdict(forListenerPath: nil), .noVisibleListener)
    }

    /// Echter Fake-Listener (dieser Testprozess) antwortet auf /healthz wie der Proxy.
    func testHealthMimickingListenerIsNotReachableAsProxy() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThan(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 8), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))

        DispatchQueue(label: "fake-health").async {
            for _ in 0..<4 {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                var buf = [UInt8](repeating: 0, count: 1024)
                _ = read(client, &buf, buf.count)
                let body = "{\"ok\":true}"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }

        XCTAssertTrue(ClaudeCodeProxyManager.isReachable(port: port), "Health-Probe allein wird nachgeahmt")
        XCTAssertFalse(ClaudeCodeProxyListenerIdentity.isTrustedListener(port: port))
        XCTAssertTrue(ClaudeCodeProxyListenerIdentity.isForeignListener(port: port))
        XCTAssertFalse(ClaudeCodeProxyManager.isTrustedReachable(port: port))
    }

    func testPortWithoutListenerIsNeitherTrustedNorForeign() {
        let port = 1  // niemand lauscht (privilegiert)
        XCTAssertFalse(ClaudeCodeProxyListenerIdentity.isTrustedListener(port: port))
        XCTAssertFalse(ClaudeCodeProxyListenerIdentity.isForeignListener(port: port))
    }
}
