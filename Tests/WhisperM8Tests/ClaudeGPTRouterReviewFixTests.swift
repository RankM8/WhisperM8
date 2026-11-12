import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Befunde aus dem Opus-Review von Paket 3 (12.11.2026), je mit Test.
final class ClaudeGPTRouterReviewFixTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = GPTRouterTestClient.makeRoot()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 1 — gptRouter.startProfile nur im Dienst-Modus, nur Profilpfad

    func testStartProfileOnlyInServiceModeWithBackendAndProfilesOn() {
        typealias Handler = AgentControlRequestHandler
        func decide(_ profile: String?, mode: ClaudeGPTRouterMode = .service, backend: Bool = true,
                    profiles: Bool = true, loggedIn: Bool = true) -> Handler.GPTRouterStartProfileDecision {
            Handler.gptRouterStartProfileDecision(
                profile: profile, mode: mode, backendEnabled: backend, profilesEnabled: profiles,
                isLoggedIn: { _ in loggedIn }
            )
        }
        XCTAssertEqual(decide("work"), .start("work"))
        guard case .refuse = decide("work", mode: .inApp) else { return XCTFail("Labs aus: keine Wirkung") }
        guard case .refuse = decide("work", backend: false) else { return XCTFail("Backend aus") }
        guard case .refuse = decide("work", profiles: false) else { return XCTFail("Profile aus") }
        guard case .refuse = decide("main") else { return XCTFail("main nie auf Zuruf") }
        guard case .refuse = decide("../x") else { return XCTFail("ungültiger Name") }
        guard case .refuse = decide(nil) else { return XCTFail("ohne Profil") }
        guard case .refuse = decide("work", loggedIn: false) else { return XCTFail("nicht angemeldet") }
    }

    func testManagerStartsOnlyProfileInstanceNeverMainForRouterService() {
        var launches: [[String]] = []
        let started = expectation(description: "Profil-Start")
        let manager = ClaudeCodeProxyManager(
            commandResolver: { _ in "/usr/local/bin/claude-code-proxy" },
            managedBinaryResolver: { nil },
            managedInstaller: { throw ClaudeCodeProxyError.binaryMissing },
            reachabilityResolver: { _ in !launches.isEmpty },
            processLauncher: { _, arguments, _ in
                launches.append(arguments)
                started.fulfill()
                return ClaudeCodeProxyProcessHandle(isRunning: { true }, terminate: {})
            },
            commandRunner: { _, _, _ in ClaudeCodeProxyCommandResult(exitCode: 1, stdout: "", stderr: "") },
            deviceLoginLauncher: { _, _, _, _, _ in ClaudeCodeProxyProcessHandle(isRunning: { false }, terminate: {}) },
            routerStarter: { _ in .success(()) },
            routerStopper: {},
            routerPortResolver: { 18_766 },
            agentDefinitionSyncer: {},
            modelListRefresher: { _ in },
            environmentResolver: { [:] },
            sleepResolver: { _ in },
            retryAttempts: 1,
            retryDelay: 0,
            notificationCenter: NotificationCenter()
        )
        manager.profileEnvironmentResolver = { _ in [GPTAccountProfiles.configDirEnvironmentKey: "/tmp/p"] }
        manager.storedAccountIDResolver = { _ in "acct" }
        manager.mainPortResolver = { 18_765 }
        manager.portAvailabilityResolver = { _ in true }
        manager.proxyRegister = ClaudeCodeProxyRegister(fileURL: root.appendingPathComponent("r.json"))

        manager.routerModeResolver = { .inApp }
        manager.profilesEnabledResolver = { true }
        XCTAssertFalse(manager.startProfileInstanceForRouterService(profile: "work"), "Labs aus")
        manager.routerModeResolver = { .service }
        manager.profilesEnabledResolver = { false }
        XCTAssertFalse(manager.startProfileInstanceForRouterService(profile: "work"), "Profile aus: kein Rückfall auf main")
        manager.profilesEnabledResolver = { true }
        XCTAssertFalse(manager.startProfileInstanceForRouterService(profile: "main"))
        XCTAssertTrue(launches.isEmpty)

        XCTAssertTrue(manager.startProfileInstanceForRouterService(profile: "work"))
        wait(for: [started], timeout: 5)
        XCTAssertEqual(launches.count, 1)
        XCTAssertNotEqual(launches.first?.last, "18765", "nie der main-Port")
    }

    // MARK: 2 — dasselbe Programm, fester Ordner, keine Test-Upstreams im Release

    func testPeerCheckAcceptsOwnProgramOverSocketpair() {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        XCTAssertTrue(ClaudeGPTRouterPeerCheck.isSameProgram(pair[0]))
        XCTAssertFalse(ClaudeGPTRouterPeerCheck.isSameProgram(pair[0], requirement: nil), "ohne eigene Anforderung nie")
    }

    func testProductionRootMustBeTheAppsFolder() throws {
        let expected = URL(fileURLWithPath: "/Users/x/Library/Application Support/WhisperM8/gpt-router", isDirectory: true)
        let same = try XCTUnwrap(GPTRouterCommand.parse(["--root", expected.path + "/", "--port", "18766", "--take-over"]))
        XCTAssertTrue(GPTRouterCommand.isAllowedRoot(same, expected: expected))
        let foreign = try XCTUnwrap(GPTRouterCommand.parse(["--root", "/tmp/elsewhere", "--port", "18766", "--take-over"]))
        XCTAssertFalse(GPTRouterCommand.isAllowedRoot(foreign, expected: expected))
        #if DEBUG
        let testing = try XCTUnwrap(GPTRouterCommand.parse(["--root", "/tmp/t", "--port", "1", "--codex-url", "http://127.0.0.1:9", "--anthropic-url", "http://127.0.0.1:9"]))
        XCTAssertTrue(GPTRouterCommand.isAllowedRoot(testing, expected: expected), "Test-Upstreams (nur Debug) dürfen eigene Ordner")
        #else
        XCTAssertNil(GPTRouterCommand.parse(["--root", "/tmp/t", "--port", "1", "--anthropic-url", "http://fremd", "--codex-url", "http://fremd"]))
        #endif
    }

    // MARK: 3 — verwaister Dienst ohne Steuerweg hält den Port

    func testReaperOnlyTargetsOwnRouterServiceOfSameUser() {
        let own = "/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"
        func holder(_ arguments: String, uid: uid_t = getuid(), pid: Int32 = 4242) -> ClaudeGPTRouterServiceReaper.PortHolder {
            .init(pid: pid, uid: uid, arguments: arguments)
        }
        let reap = { (h: ClaudeGPTRouterServiceReaper.PortHolder) in
            ClaudeGPTRouterServiceReaper.isOrphanedRouterService(h, ownExecutable: own)
        }
        XCTAssertTrue(reap(holder("\(own) gpt-router --root /x --port 18766")))
        XCTAssertTrue(reap(holder("/Applications/WhisperM8 Kopie.app/Contents/MacOS/WhisperM8 gpt-router --root /x")), "Pfad mit Leerzeichen")
        XCTAssertFalse(reap(holder(own)), "die App selbst (Router in der App)")
        XCTAssertFalse(reap(holder("\(own) gpt-router-x --root /x")))
        XCTAssertFalse(reap(holder("/usr/bin/python3 gpt-router")), "fremdes Programm")
        XCTAssertFalse(reap(holder("\(own) gpt-router --root /x", uid: getuid() + 1)), "anderer Nutzer")
        XCTAssertFalse(reap(holder("\(own) gpt-router", pid: 1)))
    }

    func testReaperTerminatesThenKillsAndReportsFreePort() {
        var signals: [Int32] = []
        var free = false
        let freed = ClaudeGPTRouterServiceReaper.freePortIfHeldByOrphanedService(
            port: 18_766,
            ownExecutable: "/a/WhisperM8",
            holderResolver: { _ in .init(pid: 4242, uid: getuid(), arguments: "/b/WhisperM8 gpt-router --root /x") },
            signaler: { _, signal in
                signals.append(signal)
                if signal == SIGKILL { free = true }
            },
            isPortFree: { _ in free },
            sleep: { _ in }
        )
        XCTAssertTrue(freed)
        XCTAssertEqual(signals, [SIGTERM, SIGKILL], "hängender Dienst: nach SIGTERM-Frist SIGKILL")

        signals = []
        XCTAssertFalse(ClaudeGPTRouterServiceReaper.freePortIfHeldByOrphanedService(
            port: 18_766,
            ownExecutable: "/a/WhisperM8",
            holderResolver: { _ in .init(pid: 4242, uid: getuid(), arguments: "/usr/sbin/httpd") },
            signaler: { _, signal in signals.append(signal) },
            isPortFree: { _ in false },
            sleep: { _ in }
        ))
        XCTAssertEqual(signals, [], "Fremdes auf dem Port bleibt unberührt")
    }

    /// Echt: Dienst-Prozess ohne `router.sock` hält den Port; die Aufsicht
    /// räumt ihn ab und startet frisch.
    func testSupervisorReapsServiceWithoutControlSocket() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("WhisperM8")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "WhisperM8-Binary fehlt im Build-Ordner")
        let upstream = try SlowStreamUpstream(chunkCount: 2, chunkDelay: 0.01)
        defer { upstream.stop() }
        let url = "http://127.0.0.1:\(upstream.port)"
        var spawned: [Process] = []
        defer { spawned.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) } }
        let spawn: ([String]) throws -> Int32 = { arguments in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments + ["--codex-url", url, "--anthropic-url", url]
            process.environment = ClaudeGPTRouterServiceSupervisor.serviceEnvironment(ProcessInfo.processInfo.environment)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            spawned.append(process)
            return process.processIdentifier
        }
        let port = GPTRouterTestClient.freePort()
        let orphan = try spawn(["gpt-router", "--root", root.path, "--port", String(port)])
        let deadline = Date().addingTimeInterval(10)
        while ClaudeGPTRouterServiceClient.status(root: root)?.pid != orphan, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Steuerweg weg (wie nach dem Aufräumen von /private/tmp).
        try FileManager.default.removeItem(at: ClaudeGPTRouterService.socketURL(root: root))
        XCTAssertFalse(ClaudeCodeProxyManager.isPortFree(port))

        let supervisor = ClaudeGPTRouterServiceSupervisor(
            root: root, build: "x", spawner: spawn, readyTimeout: 10,
            ownExecutable: binary.path,
            portReaper: { ClaudeGPTRouterServiceReaper.freePortIfHeldByOrphanedService(port: $0, ownExecutable: binary.path) }
        )
        try supervisor.ensureRunning(port: port).get()
        XCTAssertNotEqual(supervisor.currentPID, orphan)
        let exitDeadline = Date().addingTimeInterval(5)
        while spawned.first?.isRunning == true, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(spawned.first?.isRunning ?? true, "verwaister Dienst lebt noch")
        XCTAssertEqual(try GPTRouterTestClient.stream(port: port).body, SlowStreamUpstream.expectedBody(chunkCount: 2))
        supervisor.stop()
    }

    // MARK: 4 — spätes ACK: ohne „released“ gibt die neue Generation auf

    func testNewGenerationWithoutReleasedClosesListenerAndFails() throws {
        // Eine „alte Generation“, die den Socket reicht, das ack annimmt, aber
        // nicht freigibt (wie nach abgelaufener Frist).
        XCTAssertTrue(AgentControlServer.prepareOwnedDirectory(at: root))
        let path = ClaudeGPTRouterService.socketURL(root: root).path
        let listenFD = try bindUnixSocket(path)
        defer { close(listenFD) }
        let tcp = try ClaudeGPTRouterSocketListener.bind(port: 0)
        defer { close(tcp) }
        let port = try XCTUnwrap(ClaudeGPTRouterSocketListener.listeningPort(of: tcp))
        let fakeOld = expectation(description: "alte Seite")
        DispatchQueue.global().async {
            defer { fakeOld.fulfill() }
            let client = Darwin.accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            _ = try? ClaudeGPTRouterWire.receive(client)
            try? ClaudeGPTRouterWire.send(client, ["ok": true, "op": "listener", "port": port, "generation": 1], passing: tcp)
            _ = try? ClaudeGPTRouterWire.receive(client) // ack
            // keine Freigabe
        }

        let target = URL(string: "http://127.0.0.1:9")!
        let router = ClaudeGPTMixRouter(codexProxyURL: target, anthropicURL: target, listenerKind: .bsdSockets)
        defer { router.stop() }
        let service = ClaudeGPTRouterService(
            configuration: .init(root: root, port: port, build: "new", takeOver: true),
            router: router
        ) { _ in }
        guard case .failure = service.start() else { return XCTFail("Übernahme ohne released darf nicht gelingen") }
        wait(for: [fakeOld], timeout: 5)
        XCTAssertNil(router.listeningSocketDescriptor, "neue Generation hält den Socket noch")
        XCTAssertNil(router.listeningPort)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "eigener Steuer-Socket nicht aufgeräumt")
    }

    /// Alte Seite: Kommt das ack zu spät, nimmt sie wieder an und antwortet
    /// nicht mit „released“.
    func testOldGenerationRollsBackOnLateAck() throws {
        let target = URL(string: "http://127.0.0.1:9")!
        let router = ClaudeGPTMixRouter(codexProxyURL: target, anthropicURL: target, listenerKind: .bsdSockets)
        defer { router.stop() }
        var configuration = ClaudeGPTRouterService.Configuration(root: root, port: 0, build: "old", takeOver: false)
        configuration.handoverAckTimeout = 0.3
        let service = ClaudeGPTRouterService(configuration: configuration, router: router) { _ in }
        try service.start().get()

        let fd = try ClaudeGPTRouterWire.connect(path: ClaudeGPTRouterService.socketURL(root: root).path)
        defer { close(fd) }
        try ClaudeGPTRouterWire.send(fd, ["op": "handover", "protocol": ClaudeGPTRouterService.protocolVersion, "build": "n", "pid": 1, "instanceRoot": AppInstance.testRoot?.path ?? "", "testUpstreams": false])
        let reply = try ClaudeGPTRouterWire.receive(fd)
        reply.descriptor.map { _ = close($0) }
        Thread.sleep(forTimeInterval: 0.8)
        try? ClaudeGPTRouterWire.send(fd, ["op": "ack"])
        let late = try? ClaudeGPTRouterWire.receive(fd)
        XCTAssertNotEqual(late?.message["op"] as? String, "released")
        XCTAssertEqual(service.currentState, .serving)
        XCTAssertNotNil(router.listeningSocketDescriptor)
    }

    // MARK: 5 — anderer Programmort: kein Übernahmeversuch je Chat-Start

    func testTakeOverPlan() {
        func status(build: String = "old", port: Int = 18_766, executable: String = "/A/WhisperM8") -> ClaudeGPTRouterServiceStatus {
            ClaudeGPTRouterServiceStatus([
                "ok": true, "pid": 10, "build": build, "port": port, "generation": 1,
                "state": "serving", "active": 0, "executable": executable,
            ])!
        }
        let plan = ClaudeGPTRouterServiceSupervisor.takeOverPlan
        XCTAssertEqual(plan(status(build: "new"), 18_766, "/A/WhisperM8", "new"), .keepRunning)
        XCTAssertEqual(plan(status(), 18_766, "/A/WhisperM8", "new"), .takeOver)
        XCTAssertEqual(plan(status(), 18_766, "/B/WhisperM8", "new"), .replace, "anderer Ort: frisch starten")
        XCTAssertEqual(plan(status(), 18_767, "/A/WhisperM8", "new"), .replace, "anderer Port")
        XCTAssertEqual(plan(status(executable: ""), 18_766, "/B/WhisperM8", "new"), .takeOver, "ältere Generation ohne Pfad")
    }

    func testStatusReportsExecutablePath() throws {
        let target = URL(string: "http://127.0.0.1:9")!
        let router = ClaudeGPTMixRouter(codexProxyURL: target, anthropicURL: target, listenerKind: .bsdSockets)
        defer { router.stop() }
        let service = ClaudeGPTRouterService(
            configuration: .init(root: root, port: 0, build: "b", takeOver: false), router: router
        ) { _ in }
        try service.start().get()
        let status = try XCTUnwrap(ClaudeGPTRouterServiceClient.status(root: root))
        XCTAssertEqual(status.executable, ClaudeGPTRouterService.executablePath(of: getpid()))
    }

    // MARK: Nachträge aus dem eigenen Opus-Review

    /// Herkunft im Handshake: Test-Instanz oder Test-Upstreams bekommen den
    /// Socket einer echten Generation nie (und umgekehrt).
    func testHandoverRequiresSameOrigin() {
        var configuration = ClaudeGPTRouterService.Configuration(root: root, port: 0, build: "b", takeOver: false)
        configuration.instanceRoot = ""
        configuration.testUpstreams = false
        let matches = { ClaudeGPTRouterService.handoverOriginMatches($0, configuration: configuration) }
        XCTAssertTrue(matches(["instanceRoot": "", "testUpstreams": false]))
        XCTAssertFalse(matches(["instanceRoot": "/tmp/x", "testUpstreams": false]), "umgebogenes WHISPERM8_INSTANCE_ROOT")
        XCTAssertFalse(matches(["instanceRoot": "", "testUpstreams": true]), "Debug-Build mit fremden Upstreams")
        XCTAssertFalse(matches([:]), "ältere Generation ohne Angaben")
    }

    func testHandoverWithForeignOriginIsRefusedEndToEnd() throws {
        let target = URL(string: "http://127.0.0.1:9")!
        let router = ClaudeGPTMixRouter(codexProxyURL: target, anthropicURL: target, listenerKind: .bsdSockets)
        defer { router.stop() }
        var configuration = ClaudeGPTRouterService.Configuration(root: root, port: 0, build: "b", takeOver: false)
        configuration.instanceRoot = ""
        let service = ClaudeGPTRouterService(configuration: configuration, router: router) { _ in }
        try service.start().get()
        let fd = try ClaudeGPTRouterWire.connect(path: ClaudeGPTRouterService.socketURL(root: root).path)
        defer { close(fd) }
        try ClaudeGPTRouterWire.send(fd, [
            "op": "handover", "protocol": ClaudeGPTRouterService.protocolVersion, "build": "x", "pid": 1,
            "instanceRoot": "/tmp/fremd", "testUpstreams": false,
        ])
        let reply = try ClaudeGPTRouterWire.receive(fd)
        XCTAssertNil(reply.descriptor)
        XCTAssertEqual(reply.message["error"] as? String, "origin")
        XCTAssertEqual(service.currentState, .serving)
    }

    func testTestInstanceOnlyFromTestBundle() {
        XCTAssertTrue(GPTRouterCommand.isAllowedInstance(testUpstreams: false, isTestInstance: false, bundleIdentifier: "com.whisperm8.app"))
        XCTAssertTrue(GPTRouterCommand.isAllowedInstance(testUpstreams: false, isTestInstance: true, bundleIdentifier: AppInstance.testBundleIdentifier))
        XCTAssertFalse(GPTRouterCommand.isAllowedInstance(testUpstreams: false, isTestInstance: true, bundleIdentifier: "com.whisperm8.app"))
        XCTAssertTrue(GPTRouterCommand.isAllowedInstance(testUpstreams: true, isTestInstance: true, bundleIdentifier: nil))
    }

    /// Reaper nur bei totem Steuer-Socket: fehlt die Datei oder lauscht
    /// niemand, ja; ein lebender (auch langsamer) Dienst, nein.
    func testControlSocketDeadOnlyWhenMissingOrRefused() throws {
        XCTAssertTrue(ClaudeGPTRouterServiceClient.controlSocketIsDead(root: root), "Datei fehlt")
        XCTAssertTrue(AgentControlServer.prepareOwnedDirectory(at: root))
        let path = ClaudeGPTRouterService.socketURL(root: root).path
        let listening = try bindUnixSocket(path)
        XCTAssertFalse(ClaudeGPTRouterServiceClient.controlSocketIsDead(root: root), "jemand lauscht")
        close(listening)
        XCTAssertTrue(ClaudeGPTRouterServiceClient.controlSocketIsDead(root: root), "Datei da, niemand lauscht")
    }

    func testReaperRechecksHolderBeforeSigkill() {
        var signals: [Int32] = []
        var calls = 0
        _ = ClaudeGPTRouterServiceReaper.freePortIfHeldByOrphanedService(
            port: 18_766,
            ownExecutable: "/a/WhisperM8",
            holderResolver: { _ in
                calls += 1
                // Nach SIGTERM hält ein anderer Prozess den Port.
                return calls == 1
                    ? .init(pid: 4242, uid: getuid(), arguments: "/a/WhisperM8 gpt-router --root /x")
                    : .init(pid: 5555, uid: getuid(), arguments: "/a/WhisperM8 gpt-router --root /x")
            },
            signaler: { _, signal in signals.append(signal) },
            isPortFree: { _ in false },
            sleep: { _ in }
        )
        XCTAssertEqual(signals, [SIGTERM], "SIGKILL nur an denselben Prozess")
    }

    func testSupervisorDoesNotReapWhenControlSocketAlive() throws {
        let holder = try ClaudeGPTRouterSocketListener.bind(port: 0)
        defer { close(holder) }
        let port = try XCTUnwrap(ClaudeGPTRouterSocketListener.listeningPort(of: holder))
        var reaped = 0
        let supervisor = ClaudeGPTRouterServiceSupervisor(
            root: root, build: "b", spawner: { _ in throw GPTRouterTestError.setup("kein Start") },
            statusResolver: { _ in nil }, readyTimeout: 0.1,
            ownExecutable: "/a/WhisperM8",
            portReaper: { _ in reaped += 1; return true },
            deadControlSocket: { _ in false }
        )
        _ = supervisor.ensureRunning(port: port)
        XCTAssertEqual(reaped, 0, "Status-Timeout ist kein Waise")
    }

    // MARK: Hilfen

    private func bindUnixSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
        guard bound == 0, listen(fd, 4) == 0 else { throw GPTRouterTestError.socket(errno) }
        return fd
    }
}
