import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Leerlauf-Frist des Router-Dienstes (30 min, hier verkürzt) und `stop()`
/// ohne Warten auf dem Main Thread.
final class ClaudeGPTRouterIdleTests: XCTestCase {
    private var root: URL!
    private var upstream: SlowStreamUpstream!
    private var routers: [ClaudeGPTMixRouter] = []
    /// Wie `GPTRouterCommand.service` im echten Prozess: Der Dienst muss
    /// gehalten werden, seine Quellen hängen schwach an ihm.
    private var services: [ClaudeGPTRouterService] = []

    override func setUpWithError() throws {
        root = GPTRouterTestClient.makeRoot()
        upstream = try SlowStreamUpstream(chunkCount: 25, chunkDelay: 0.04)
    }

    override func tearDown() {
        routers.forEach { $0.stop() }
        services.removeAll()
        upstream.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func startService(idleLimit: TimeInterval) throws -> (ClaudeGPTRouterService, DispatchSemaphore) {
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url, listenerKind: .bsdSockets)
        routers.append(router)
        var configuration = ClaudeGPTRouterService.Configuration(root: root, port: 0, build: "b", takeOver: false)
        configuration.idleLimit = idleLimit
        configuration.idleCheckInterval = 0.05
        configuration.drainPollInterval = 0.02
        let exited = DispatchSemaphore(value: 0)
        let service = ClaudeGPTRouterService(configuration: configuration, router: router) { _ in exited.signal() }
        try service.start().get()
        services.append(service)
        return (service, exited)
    }

    func testIdleRuleNeedsNoAppNoRequestAndElapsedLimit() {
        let now = Date()
        let expired = ClaudeGPTRouterService.isIdleExpired
        XCTAssertTrue(expired(0, 0, now.addingTimeInterval(-1_800), now, 1_800))
        XCTAssertFalse(expired(0, 0, now.addingTimeInterval(-1_799), now, 1_800))
        XCTAssertFalse(expired(1, 0, now.addingTimeInterval(-9_999), now, 1_800), "App verbunden")
        XCTAssertFalse(expired(0, 1, now.addingTimeInterval(-9_999), now, 1_800), "Anfrage läuft")
        XCTAssertEqual(ClaudeGPTRouterService.Configuration(root: root, port: 0, build: "b", takeOver: false).idleLimit, 1_800)
    }

    func testServiceWithoutAppEndsAfterIdleLimitAndFreesPort() throws {
        let (service, exited) = try startService(idleLimit: 0.3)
        let port = try XCTUnwrap(service.router.listeningPort)
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success, "Dienst endet nach der Frist nicht")
        XCTAssertTrue(ClaudeCodeProxyManager.isPortFree(port))
        XCTAssertNil(ClaudeGPTRouterServiceClient.status(root: root))
    }

    func testConnectedAppKeepsServiceAliveUntilItDisconnects() throws {
        let (_, exited) = try startService(idleLimit: 0.3)
        let attachment = try XCTUnwrap(ClaudeGPTRouterServiceClient.attach(root: root))
        XCTAssertEqual(ClaudeGPTRouterServiceClient.status(root: root)?.attached, 1)
        XCTAssertEqual(exited.wait(timeout: .now() + 1.2), .timedOut, "beendet trotz verbundener App")
        close(attachment) // App endet: der Kernel schließt die Verbindung genauso
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
    }

    func testRunningRequestKeepsServiceAlive() throws {
        let (service, exited) = try startService(idleLimit: 0.3)
        let port = try XCTUnwrap(service.router.listeningPort)
        let done = expectation(description: "Strom")
        var result: Result<(status: String, body: Data), Error>?
        DispatchQueue.global().async {
            result = Result { try GPTRouterTestClient.stream(port: port) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try XCTUnwrap(result).get().body, SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount),
                       "Strom (1 s) länger als die Frist (0,3 s) muss vollständig ankommen")
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success, "danach endet der Dienst")
    }

    /// Die Aufsicht der App hält die Verbindung; `stop()` kehrt sofort zurück.
    func testSupervisorAttachesAndStopsWithoutWaiting() throws {
        var service: ClaudeGPTRouterService?
        var exited: DispatchSemaphore?
        let supervisor = ClaudeGPTRouterServiceSupervisor(
            root: root, build: "b",
            spawner: { [unowned self] _ in
                (service, exited) = try self.startService(idleLimit: 0.3)
                return getpid()
            },
            readyTimeout: 3
        )
        // Port 0: Der Dienst wählt einen freien Port; die Aufsicht wartet nur
        // auf „serving“ der gestarteten PID.
        try supervisor.ensureRunning(port: 0).get()
        XCTAssertNotNil(service)
        XCTAssertEqual(ClaudeGPTRouterServiceClient.status(root: root)?.attached, 1)
        XCTAssertEqual(exited?.wait(timeout: .now() + 1), .timedOut, "verbundene App hält den Dienst")

        let started = Date()
        supervisor.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "stop() blockiert")
        XCTAssertEqual(exited?.wait(timeout: .now() + 5), .success, "Dienst endet nach stop() nicht")
    }

    // MARK: Befunde aus dem eigenen Review

    /// Ein Neustart nach Absturz darf ein gleichzeitiges stop() nicht
    /// verschlucken: Nach stop() startet der interne Weg nichts mehr.
    func testRestartAfterCrashRespectsStop() throws {
        var spawns = 0
        let supervisor = ClaudeGPTRouterServiceSupervisor(
            root: root, build: "b",
            spawner: { [unowned self] _ in
                spawns += 1
                _ = try self.startService(idleLimit: 30)
                return getpid()
            },
            readyTimeout: 3
        )
        try supervisor.ensureRunning(port: 0).get()
        XCTAssertEqual(spawns, 1)
        supervisor.stop()
        XCTAssertNil(supervisor.restartIfStillWanted(port: 0), "Neustart trotz stop()")
        XCTAssertEqual(spawns, 1)
    }

    /// Start direkt nach stop(): Der Dienst hat sein shutdown schon und läuft
    /// aus — nicht behalten (sonst Lücke bis zum Neustart), sondern ersetzen.
    func testStartRightAfterStopReplacesDrainingService() throws {
        var spawns = 0
        let supervisor = ClaudeGPTRouterServiceSupervisor(
            root: root, build: "b",
            spawner: { [unowned self] _ in
                spawns += 1
                _ = try self.startService(idleLimit: 30)
                return getpid()
            },
            readyTimeout: 3
        )
        try supervisor.ensureRunning(port: 0).get()
        supervisor.stop()
        try supervisor.ensureRunning(port: 0).get()
        XCTAssertEqual(spawns, 2, "auslaufender Dienst wurde behalten")
        supervisor.stop()
    }

    /// Kurze Anfragen zwischen zwei Prüfungen der Uhr zählen trotzdem.
    func testShortRequestsResetIdleClock() throws {
        let quick = try SlowStreamUpstream(chunkCount: 1, chunkDelay: 0.01)
        defer { quick.stop() }
        let url = URL(string: "http://127.0.0.1:\(quick.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url, listenerKind: .bsdSockets)
        routers.append(router)
        var configuration = ClaudeGPTRouterService.Configuration(root: root, port: 0, build: "b", takeOver: false)
        configuration.idleLimit = 0.6
        configuration.idleCheckInterval = 0.25
        let exited = DispatchSemaphore(value: 0)
        let service = ClaudeGPTRouterService(configuration: configuration, router: router) { _ in exited.signal() }
        try service.start().get()
        services.append(service)
        let port = try XCTUnwrap(router.listeningPort)
        for _ in 0..<6 {
            _ = try GPTRouterTestClient.stream(port: port)
            XCTAssertEqual(exited.wait(timeout: .now() + 0.3), .timedOut, "beendet trotz laufender kurzer Anfragen")
        }
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success, "danach endet der Dienst")
    }

    func testAttachmentsAreLimited() throws {
        _ = try startService(idleLimit: 30)
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0..<ClaudeGPTRouterService.maximumAttachments {
            held.append(try XCTUnwrap(ClaudeGPTRouterServiceClient.attach(root: root)))
        }
        XCTAssertNil(ClaudeGPTRouterServiceClient.attach(root: root), "mehr attach als Plätze")
        close(held.removeLast())
        let deadline = Date().addingTimeInterval(3)
        var again: Int32?
        while again == nil, Date() < deadline {
            again = ClaudeGPTRouterServiceClient.attach(root: root)
            if again == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        held.append(try XCTUnwrap(again, "Platz wird nach dem Schließen nicht frei"))
    }

    /// Hängt der Dienst (nimmt an, antwortet nie), darf `stop()` den Main
    /// Thread trotzdem nicht aufhalten.
    func testStopDoesNotWaitForHangingService() throws {
        XCTAssertTrue(AgentControlServer.prepareOwnedDirectory(at: root))
        let path = ClaudeGPTRouterService.socketURL(root: root).path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
                bytes.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: bytes.count) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 8), 0) // nimmt nie an, antwortet nie

        let supervisor = ClaudeGPTRouterServiceSupervisor(root: root, build: "b", spawner: { _ in 0 })
        let started = Date()
        supervisor.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "stop() wartet auf einen hängenden Dienst")
    }
}
