import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// SO_NOSIGPIPE muss am lauschenden Socket stehen: Setzt man es erst nach
/// `accept` und hat die Gegenseite da schon geschlossen, scheitert der Aufruf
/// (EINVAL) — die Antwort des Dienstes löste SIGPIPE aus. Im echten Dienst
/// fängt `SigpipeGuard` das ab, ein Testprozess oder ein anderer Aufrufer
/// stürbe daran (gefunden 13.11.2026 beim Herunterfahren ohne Warten).
final class ClaudeGPTRouterSigpipeTests: XCTestCase {
    nonisolated(unsafe) private static var received = 0

    func testRouterListenerCarriesNoSigPipeForAcceptedConnections() throws {
        let fd = try ClaudeGPTRouterSocketListener.bind(port: 0)
        defer { close(fd) }
        XCTAssertEqual(Self.noSigPipe(fd), 1)
    }

    func testShutdownWithoutWaitingRaisesNoSigpipe() throws {
        var previous = sigaction()
        var counting = sigaction()
        counting.__sigaction_u.__sa_handler = { _ in ClaudeGPTRouterSigpipeTests.received += 1 }
        sigaction(SIGPIPE, &counting, &previous)
        defer { sigaction(SIGPIPE, &previous, nil) }
        Self.received = 0

        for _ in 0..<10 {
            let root = GPTRouterTestClient.makeRoot()
            defer { GPTRouterTestClient.removeRoot(root) }
            let target = URL(string: "http://127.0.0.1:9")!
            let router = ClaudeGPTMixRouter(codexProxyURL: target, anthropicURL: target, listenerKind: .bsdSockets)
            defer { router.stop() }
            var configuration = ClaudeGPTRouterService.Configuration(root: root, port: 0, build: "b", takeOver: false)
            configuration.drainPollInterval = 0.02
            let exited = DispatchSemaphore(value: 0)
            let service = ClaudeGPTRouterService(configuration: configuration, router: router) { _ in exited.signal() }
            try service.start().get()
            // Schließt sofort nach dem Senden — die Antwort trifft eine tote Gegenseite.
            ClaudeGPTRouterServiceClient.requestShutdownWithoutWaiting(root: root)
            XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
            withExtendedLifetime(service) {}
        }
        XCTAssertEqual(Self.received, 0, "SIGPIPE beim Antworten an eine geschlossene Verbindung")
    }

    private static func noSigPipe(_ fd: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length)
        return value
    }
}
