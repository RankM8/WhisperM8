import AppKit
import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// App-Seite des Router-Dienstes: Weiche zwischen den Varianten, Proxy-Register,
/// `willTerminate` mit und ohne Übergabe, Waisen-Guard. Mit Labs-Schalter aus
/// (`.inApp`) muss alles wie bisher laufen.
final class ClaudeGPTRouterHostTests: XCTestCase {
    private var root: URL!
    private var registerURL: URL!
    private var helpers: [Process] = []

    override func setUp() {
        root = GPTRouterTestClient.makeRoot()
        registerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gpt-proxies-\(UUID().uuidString).json")
    }

    override func tearDown() {
        for helper in helpers where helper.isRunning {
            helper.terminate()
            _ = waitForExit(helper)
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: registerURL)
    }

    // MARK: Modus und Weiche

    func testModeFollowsLabsSwitchAndDefaultsToInApp() {
        XCTAssertEqual(ClaudeGPTRouterMode.resolve(restartKeepsChatsEnabled: false), .inApp)
        XCTAssertEqual(ClaudeGPTRouterMode.resolve(restartKeepsChatsEnabled: true), .service)
        let defaults = UserDefaults(suiteName: "router-mode-\(UUID().uuidString)")!
        XCTAssertFalse(AppPreferences(defaults: defaults).isRestartKeepsChatsEnabled, "ab Werk aus")
    }

    func testInAppHostCallsExactlyTheInAppRouterAndNeverSpawns() throws {
        var started: [Int] = []
        var stopped = 0
        var spawned = 0
        let supervisor = ClaudeGPTRouterServiceSupervisor(root: root, build: "b", spawner: { _ in spawned += 1; return 0 })
        var reaped = 0
        let host = ClaudeGPTRouterHost(
            mode: .inApp,
            inAppStart: { started.append($0); return .success(()) },
            inAppStop: { stopped += 1 },
            supervisor: supervisor,
            // Nie lsof/ps gegen den echten Port der laufenden App.
            portReaper: { _ in reaped += 1; return false },
            deadControlSocket: { _ in true }
        )
        let port = GPTRouterTestClient.freePort()
        try host.start(port: port).get()
        try host.start(port: port).get()
        host.stop()
        XCTAssertEqual(started, [port, port])
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(spawned, 0)
        XCTAssertLessThanOrEqual(reaped, 1, "höchstens einmal je Lauf und nur bei belegtem Port")
    }

    /// Schalter wieder aus, Dienst aus einem früheren Lauf hält den Port: Er
    /// gibt ihn frei, bevor der Router der App bindet.
    func testInAppHostRetiresLeftoverServiceBeforeBinding() throws {
        let service = try startInProcessService(build: "old")
        let port = try XCTUnwrap(service.router.listeningPort)
        var portWasFree = false
        let host = ClaudeGPTRouterHost(
            mode: .inApp,
            inAppStart: { port in
                portWasFree = ClaudeCodeProxyManager.isPortFree(port)
                return .success(())
            },
            inAppStop: {},
            supervisor: ClaudeGPTRouterServiceSupervisor(root: root, build: "new", spawner: { _ in 0 })
        )
        try host.start(port: port).get()
        XCTAssertTrue(portWasFree)
        XCTAssertNil(ClaudeGPTRouterServiceClient.status(root: root))
    }

    func testServiceHostStartsServiceOnceAndReusesItWithSameBuild() throws {
        var spawns: [[String]] = []
        var service: ClaudeGPTRouterService?
        let supervisor = ClaudeGPTRouterServiceSupervisor(
            root: root,
            build: "same",
            spawner: { [unowned self] arguments in
                spawns.append(arguments)
                service = try self.startInProcessService(build: "same", port: Int(arguments[4]) ?? 0)
                return getpid()
            },
            readyTimeout: 3
        )
        let host = ClaudeGPTRouterHost(mode: .service, inAppStart: { _ in
            XCTFail("Router der App darf im Dienst-Modus nicht starten")
            return .success(())
        }, inAppStop: {}, supervisor: supervisor)
        let port = GPTRouterTestClient.freePort()
        try host.start(port: port).get()
        try host.start(port: port).get()
        XCTAssertEqual(spawns, [["gpt-router", "--root", root.path, "--port", String(port)]])
        XCTAssertEqual(service?.router.listeningPort, port)
        service?.router.stop()
    }

    // MARK: willTerminate

    func testInAppModeIgnoresHandoverRequestAndStopsLikeToday() {
        let center = NotificationCenter()
        var terminated = 0
        var routerStops = 0
        let manager = makeManager(center: center, routerStopper: { routerStops += 1 }) { _, _, _ in
            ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: { terminated += 1 }, pid: 4242)
        }
        manager.routerModeResolver = { .inApp }
        manager.handoverRequestedResolver = { true }
        _ = manager.ensureRunning(port: 18_765)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(terminated, 1)
        XCTAssertEqual(routerStops, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registerURL.path), "ohne Labs kein Register")
    }

    func testServiceModeHandoverKeepsProxyAndRouterAndWritesRegister() throws {
        let center = NotificationCenter()
        let sleeper = try spawnSleeper()
        var terminated = 0
        var routerStops = 0
        let manager = makeManager(center: center, routerStopper: { routerStops += 1 }) { executable, _, _ in
            ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: { terminated += 1 }, pid: sleeper.processIdentifier, executablePath: executable)
        }
        manager.routerModeResolver = { .service }
        manager.handoverRequestedResolver = { true }
        _ = manager.ensureRunning(port: 18_765)
        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(terminated, 0, "Bei Übergabe läuft der Proxy weiter")
        XCTAssertEqual(routerStops, 0, "Bei Übergabe läuft der Router-Dienst weiter")
        let file = try XCTUnwrap(ClaudeCodeProxyRegister(fileURL: registerURL).read())
        XCTAssertEqual(file.proxies.map(\.profile), ["main"])
        XCTAssertEqual(file.proxies.first?.pid, sleeper.processIdentifier)
        XCTAssertEqual(file.proxies.first?.port, 18_765)
        XCTAssertEqual(file.proxies.first?.binary, "/usr/local/bin/claude-code-proxy")
        let attributes = try FileManager.default.attributesOfItem(atPath: registerURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testServiceModeRealQuitStopsProxyAndRouterService() {
        let center = NotificationCenter()
        var terminated = 0
        var routerStops = 0
        // Proxy extern: heute bliebe der Router stehen, der Dienst muss trotzdem enden.
        let manager = makeManager(center: center, reachable: true, routerStopper: { routerStops += 1 }) { _, _, _ in
            ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: { terminated += 1 })
        }
        manager.routerModeResolver = { .service }
        manager.handoverRequestedResolver = { false }
        _ = manager.ensureRunning(port: 18_765)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(routerStops, 1)
        XCTAssertEqual(terminated, 0, "externer Proxy bleibt wie heute")
    }

    // MARK: Register übernehmen

    func testServiceModeAdoptsLiveRegisteredProxiesInsteadOfStartingNew() throws {
        let mainProxy = try spawnSleeper()
        let profileProxy = try spawnSleeper()
        try writeRegister([
            entry("main", mainProxy, port: 18_765),
            entry("work", profileProxy, port: 18_775),
        ], promoted: ["old"])
        var launches = 0
        let manager = makeManager(center: NotificationCenter(), reachable: true) { _, _, _ in
            launches += 1
            return ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: {})
        }
        manager.routerModeResolver = { .service }

        XCTAssertEqual(manager.adoptedProxyPIDs(), [mainProxy.processIdentifier, profileProxy.processIdentifier])
        XCTAssertEqual(manager.port(forProfile: "work"), 18_775)
        XCTAssertTrue(GPTPromotedProfiles.shared.wasPromoted("old"))
        GPTPromotedProfiles.shared.clear("old")
        _ = manager.ensureRunning(port: 18_765)
        XCTAssertEqual(launches, 0)

        // Übernommen heißt „selbst gestartet“: „Proxy stoppen“ beendet ihn.
        manager.stopIfSelfStarted()
        XCTAssertTrue(waitForExit(mainProxy))
        XCTAssertEqual(mainProxy.terminationReason, .uncaughtSignal)
        XCTAssertTrue(waitForExit(profileProxy))
        XCTAssertEqual(profileProxy.terminationReason, .uncaughtSignal, "Profil-Instanz gehört mit dazu")
    }

    func testRegisterIgnoresReusedPIDAndDeadProcess() throws {
        let alive = try spawnSleeper()
        var reused = entry("main", alive, port: 18_765)
        reused.startTime -= 3_600
        XCTAssertFalse(ClaudeCodeProxyRegister.isAlive(reused), "PID wiederverwendet: andere Startzeit")
        XCTAssertTrue(ClaudeCodeProxyRegister.isAlive(entry("main", alive, port: 18_765)))
        let dead = ClaudeCodeProxyRegisterFile.Entry(profile: "main", pid: 999_999, startTime: 1, port: 1, binary: "")
        XCTAssertFalse(ClaudeCodeProxyRegister.isAlive(dead))

        try writeRegister([reused], promoted: [])
        let manager = makeManager(center: NotificationCenter(), reachable: true) { _, _, _ in
            ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: {})
        }
        manager.routerModeResolver = { .service }
        XCTAssertEqual(manager.adoptedProxyPIDs(), [])
    }

    func testInAppModeNeverReadsRegister() throws {
        let sleeper = try spawnSleeper()
        try writeRegister([entry("main", sleeper, port: 18_765)], promoted: [])
        let manager = makeManager(center: NotificationCenter(), reachable: true) { _, _, _ in
            ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: {})
        }
        manager.routerModeResolver = { .inApp }
        XCTAssertEqual(manager.adoptedProxyPIDs(), [])
    }

    func testOrphanGuardNeverReplacesAdoptedProxy() {
        var terminated: [Int32] = []
        let listener = ClaudeCodeProxyOrphanGuard.ListenerProcess(
            pid: 4242, parentPID: 1, executablePath: "/old/claude-code-proxy", startedAt: nil
        )
        XCTAssertFalse(ClaudeCodeProxyOrphanGuard.replaceIfOutdated(
            port: 18_765,
            resolvedBinaryPath: "/new/claude-code-proxy",
            protectedPIDs: [4242],
            listenerResolver: { _ in listener },
            terminator: { terminated.append($0) },
            isReachable: { _ in false },
            sleep: { _ in }
        ))
        XCTAssertEqual(terminated, [])
        // Ohne Schutz (Labs aus) wie bisher ersetzt.
        XCTAssertTrue(ClaudeCodeProxyOrphanGuard.replaceIfOutdated(
            port: 18_765,
            resolvedBinaryPath: "/new/claude-code-proxy",
            listenerResolver: { _ in listener },
            terminator: { terminated.append($0) },
            isReachable: { _ in false },
            sleep: { _ in }
        ))
        XCTAssertEqual(terminated, [4242])
    }

    // MARK: Hilfen

    @discardableResult
    private func startInProcessService(build: String, port: Int = 0) throws -> ClaudeGPTRouterService {
        let url = URL(string: "http://127.0.0.1:9")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url, listenerKind: .bsdSockets)
        var configuration = ClaudeGPTRouterService.Configuration(root: root, port: port, build: build, takeOver: false)
        configuration.drainPollInterval = 0.02
        let service = ClaudeGPTRouterService(configuration: configuration, router: router) { _ in }
        try service.start().get()
        addTeardownBlock { router.stop() }
        return service
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }

    private func spawnSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        helpers.append(process)
        // Startzeit erst lesbar, wenn der Prozess wirklich läuft.
        for _ in 0..<50 where ProcessStartTime.of(pid: process.processIdentifier) == nil {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return process
    }

    private func entry(_ profile: String, _ process: Process, port: Int) -> ClaudeCodeProxyRegisterFile.Entry {
        ClaudeCodeProxyRegisterFile.Entry(
            profile: profile,
            pid: process.processIdentifier,
            startTime: ProcessStartTime.of(pid: process.processIdentifier)?.timeIntervalSince1970 ?? 0,
            port: port,
            binary: "/bin/sleep"
        )
    }

    private func writeRegister(_ entries: [ClaudeCodeProxyRegisterFile.Entry], promoted: [String]) throws {
        ClaudeCodeProxyRegister(fileURL: registerURL).write(
            ClaudeCodeProxyRegisterFile(updatedAt: Date().timeIntervalSince1970, proxies: entries, promotedProfiles: promoted)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: registerURL.path))
    }

    private func makeManager(
        center: NotificationCenter,
        reachable: Bool = false,
        routerStopper: @escaping () -> Void = {},
        launcher: @escaping ClaudeCodeProxyManager.ProcessLauncher
    ) -> ClaudeCodeProxyManager {
        var launched = false
        let manager = ClaudeCodeProxyManager(
            commandResolver: { _ in "/usr/local/bin/claude-code-proxy" },
            managedBinaryResolver: { nil },
            managedInstaller: { throw ClaudeCodeProxyError.binaryMissing },
            // Nach dem Start erreichbar, vorher nur, wenn `reachable`.
            reachabilityResolver: { _ in reachable || launched },
            processLauncher: { executable, arguments, environment in
                launched = true
                return try launcher(executable, arguments, environment)
            },
            commandRunner: { _, _, _ in ClaudeCodeProxyCommandResult(exitCode: 1, stdout: "", stderr: "") },
            deviceLoginLauncher: { _, _, _, _, _ in ClaudeCodeProxyProcessHandle(isRunning: { false }, terminate: {}) },
            routerStarter: { _ in .success(()) },
            routerStopper: routerStopper,
            routerPortResolver: { 18_766 },
            agentDefinitionSyncer: {},
            modelListRefresher: { _ in },
            environmentResolver: { [:] },
            sleepResolver: { _ in },
            retryAttempts: 1,
            retryDelay: 0,
            notificationCenter: center
        )
        manager.profileEnvironmentResolver = { _ in [:] }
        manager.storedAccountIDResolver = { _ in nil }
        manager.profilesEnabledResolver = { true }
        manager.transcriptionsAPIEnabledResolver = { true }
        manager.mainPortResolver = { 18_765 }
        manager.proxyRegister = ClaudeCodeProxyRegister(fileURL: registerURL)
        return manager
    }
}
