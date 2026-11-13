import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Paket 4c: Übernahme beim Start gegen einen echten Aufbewahrer-Prozess.
/// Abgabe wie die alte App (Koordinator + Marker), Übernahme wie die neue
/// (Marker lesen, Geheimnis, TAKE, Bericht). App-Objekte sind Closures.
@MainActor
final class HandoverTakeServiceTests: XCTestCase {
    private var directory: URL!
    private var children: [HandoverPTYChild] = []
    private var adoptedDescriptors: [Int32] = []

    override func setUp() async throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() async throws {
        adoptedDescriptors.forEach { close($0) }
        for child in children { child.kill() }
        if let status = HandoverTakeService.status(paths: paths) { kill(status.pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    private var paths: HandoverPaths { HandoverPaths(directory: directory) }
    private var markerURL: URL { directory.appendingPathComponent("running-sessions.json") }

    private func marker(pid: Int32) -> AgentCrashRecoveryMarker {
        AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: pid, isProcessAlive: { _ in false })
    }

    private func spawn() throws -> FakeDepositSource {
        let child = try HandoverPTYChild.ticking(in: directory)
        children.append(child)
        return FakeDepositSource(child: child, detachable: true)
    }

    private func session(for source: FakeDepositSource, kind: AgentSessionKind = .chat) -> AgentChatSession {
        AgentChatSession(id: source.sessionID, provider: .claude, projectID: UUID(), title: "t",
                         status: .running, kind: kind)
    }

    /// Alte App: abgeben und den Marker auf „übergeben“ setzen.
    private func handOver(_ sources: [FakeDepositSource], secrets: HandoverSecretStoring) throws -> String {
        let old = marker(pid: 100)
        _ = old.beginRun()
        let coordinator = HandoverDepositCoordinator(dependencies: .init(
            paths: paths, keeperExecutable: try HandoverTestSupport.keeperBinary(),
            appBinaries: [HandoverTestSupport.ownExecutablePath], secretStore: secrets, holdSeconds: 60))
        let outcome = coordinator.deposit(sources.map { source in
            .init(source: source) { _ in source.child.manifest(chatID: source.sessionID.uuidString) }
        })
        guard case let .handedOver(runID, keeperPID, start, chats, _) = outcome else {
            XCTFail("Abgabe gescheitert: \(outcome)")
            return ""
        }
        old.markHandedOver(.init(keeperPID: keeperPID, keeperStartTime: start, runID: runID,
                                 chats: chats.map { .init(sessionID: $0.sessionID, pid: $0.pid, pidStartTime: $0.pidStartTime) }))
        return runID
    }

    private final class Calls {
        var adopted: [UUID] = []
        var ended: [UUID] = []
        var resumed: [UUID] = []
    }

    private func service(secrets: HandoverSecretStoring, sessions: [AgentChatSession], calls: Calls,
                         adoptSucceeds: Bool = true,
                         isSameProcess: ((Int32, Double?) -> Bool)? = nil,
                         onMainThread: Bool = true) -> HandoverTakeService {
        HandoverTakeService(dependencies: serviceDependencies(
            secrets: secrets, sessions: sessions, calls: calls, adoptSucceeds: adoptSucceeds,
            isSameProcess: isSameProcess, onMainThread: onMainThread))
    }

    private func serviceDependencies(secrets: HandoverSecretStoring, sessions: [AgentChatSession], calls: Calls,
                                     adoptSucceeds: Bool = true,
                                     isSameProcess: ((Int32, Double?) -> Bool)? = nil,
                                     onMainThread: Bool = true) -> HandoverTakeService.Dependencies {
        var dependencies = HandoverTakeService.Dependencies(
            paths: paths, secretStore: secrets, marker: marker(pid: 200),
            sessions: { sessions },
            adopt: { [weak self] taken, session in
                guard adoptSucceeds, let fd = taken.descriptor else { return false }
                self?.adoptedDescriptors.append(fd)
                calls.adopted.append(session.id)
                return true
            },
            showEnded: { _, session in calls.ended.append(session.id) },
            scheduleResume: { calls.resumed.append(contentsOf: $0) },
            gracePeriod: 3)
        dependencies.signalWait = 1
        if let isSameProcess { dependencies.isSameProcess = isSameProcess }
        if !onMainThread { dependencies.isMainThread = { false } }
        return dependencies
    }

    func testNewAppAdoptsAllChatsAndClearsHandoverState() throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn(), try spawn()]
        let runID = try handOver(sources, secrets: secrets)
        let calls = Calls()

        let summary = service(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: calls).takeAtLaunch()

        XCTAssertEqual(Set(summary.adopted), Set(sources.map(\.sessionID)))
        XCTAssertTrue(summary.fallback.isEmpty)
        XCTAssertEqual(Set(calls.adopted), Set(sources.map(\.sessionID)))
        XCTAssertEqual(summary.handled, Set(sources.map(\.sessionID)))
        XCTAssertEqual(secrets.load(), .missing, "Geheimnis nach der Übernahme gelöscht")
        let report = try XCTUnwrap(HandoverTakeReport.read(paths: paths))
        XCTAssertEqual(report.runID, runID)
        XCTAssertTrue(report.isComplete)
        XCTAssertNil(marker(pid: 300).beginRunDetailed().handover, "Marker ohne „übergeben“")
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { HandoverTakeService.status(paths: self.paths) == nil },
                      "Aufbewahrer endet nach DONE")
        for source in sources {
            XCTAssertTrue(source.child.isAlive)
            XCTAssertFalse(source.child.marker.contains("HUP"))
        }
    }

    /// Option A von Abgabe bis Übernahme: Die alte App legt das Geheimnis als
    /// Datei ab, eine neue Instanz der Ablage (wie die neue App) liest es,
    /// übernimmt und löscht es.
    func testFileSecretCarriesTheTakeAcrossInstances() throws {
        let sources = [try spawn(), try spawn()]
        _ = try handOver(sources, secrets: HandoverFileSecretStore(paths: paths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.secretFileURL.path))
        let calls = Calls()
        let summary = service(secrets: HandoverFileSecretStore(paths: paths), sessions: sources.map { session(for: $0) },
                              calls: calls).takeAtLaunch()
        XCTAssertEqual(Set(summary.adopted), Set(sources.map(\.sessionID)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.secretFileURL.path), "nach dem Lesen gelöscht")
    }

    func testChatEndedInGapIsShownAsEnded() throws {
        let secrets = FakeSecretStore()
        let alive = try spawn(), ending = try spawn()
        _ = try handOver([alive, ending], secrets: secrets)
        ending.child.kill(SIGTERM)
        // Der Aufbewahrer vermerkt das Ende über kqueue.
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 5) {
            HandoverTakeService.status(paths: self.paths)?.chats.contains { $0.exited } == true
        })
        let calls = Calls()
        let summary = service(secrets: secrets, sessions: [session(for: alive), session(for: ending)], calls: calls).takeAtLaunch()
        XCTAssertEqual(summary.adopted, [alive.sessionID])
        XCTAssertEqual(summary.endedInGap, [ending.sessionID])
        XCTAssertEqual(calls.ended, [ending.sessionID])
        XCTAssertTrue(calls.resumed.isEmpty, "in der Lücke beendet wird nicht automatisch neu gestartet")
    }

    /// Anders signierter Build: kein Geheimnis. Der Aufbewahrer wird beendet,
    /// die Chats enden mit ihm, erst danach kommt `--resume`.
    func testWithoutSecretKeeperIsEndedAndChatsResumeAfterTheirEnd() async throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: sources.map { session(for: $0) }, calls: calls).takeAtLaunch()

        XCTAssertTrue(summary.adopted.isEmpty)
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertTrue(calls.resumed.isEmpty, "nicht fortsetzen, solange der Prozess lebt")
        let end = Date().addingTimeInterval(15)
        while calls.resumed.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID))
        XCTAssertFalse(sources[0].child.isAlive, "Prozess ist weg, bevor fortgesetzt wird")
        XCTAssertFalse(HandoverTakeReport.read(paths: paths)?.isComplete ?? true)
    }

    func testFailedAdoptionClosesLineAndResumesAfterExit() async throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: secrets)
        let calls = Calls()
        let summary = service(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: calls,
                              adoptSucceeds: false).takeAtLaunch()
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        let end = Date().addingTimeInterval(15)
        while calls.resumed.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID))
        XCTAssertFalse(sources[0].child.isAlive)
    }

    /// Review Paket 1, Befund 3: Passt die Startzeit nicht (PID neu
    /// vergeben), übernimmt die App die Leitung nicht.
    func testReusedPIDIsNotAdopted() throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: secrets)
        let calls = Calls()
        var checks = 0
        let summary = service(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: calls,
                              isSameProcess: { _, _ in checks += 1; return false }).takeAtLaunch()
        XCTAssertTrue(calls.adopted.isEmpty, "keine Übernahme bei fremdem Prozess unter der PID")
        XCTAssertTrue(summary.adopted.isEmpty)
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertGreaterThanOrEqual(checks, 1)
    }

    /// Urteil zur Absender-Bindung, vor 4c: Abseits des Main Threads öffnet
    /// die Übernahme keinen Socket. Der Aufbewahrer wird per Signal beendet
    /// (PID und Startzeit aus dem Marker), die Chats erst nach ihrem Ende
    /// fortgesetzt.
    func testTakeOffTheMainThreadOpensNoSocketAndFallsBack() async throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: secrets)
        let keeper = try XCTUnwrap(HandoverTakeService.status(paths: paths))
        let calls = Calls()
        let summary = service(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: calls,
                              onMainThread: false).takeAtLaunch()
        XCTAssertTrue(summary.adopted.isEmpty)
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertTrue(calls.adopted.isEmpty)
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { kill(keeper.pid, 0) != 0 }, "Aufbewahrer per Signal beendet")
        let end = Date().addingTimeInterval(15)
        while calls.resumed.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID))
        XCTAssertFalse(sources[0].child.isAlive, "fortgesetzt erst nach dem Ende des Prozesses")
    }

    /// Befund kill-mid-take (Dex): Ein Chat, der SIGHUP und SIGTERM übersteht,
    /// bekommt SIGKILL und wird danach fortgesetzt, statt nie zurückzukommen.
    func testOrphanSurvivingSigtermIsKilledAndThenResumed() async throws {
        let source = try stubbornChild()
        let child = source.child
        let sources = [source]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let calls = Calls()
        // Ohne Geheimnis: Der Aufbewahrer wird beendet, der Chat überlebt das.
        let summary = service(secrets: FakeSecretStore(), sessions: sources.map { session(for: $0) },
                              calls: calls).takeAtLaunch()
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        let end = Date().addingTimeInterval(20)
        while calls.resumed.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID), "nach SIGKILL fortgesetzt")
        XCTAssertFalse(child.isAlive, "erst weg, dann fortgesetzt")
    }

    /// Übersteht Ctrl+C (das geordnete Ende des Aufbewahrers), SIGHUP und SIGTERM.
    private func stubbornChild() throws -> FakeDepositSource {
        let child = try HandoverPTYChild.spawn(script: """
        trap '' HUP TERM INT
        : > "$READY"
        while true; do sleep 0.05; done
        """, in: directory)
        children.append(child)
        return FakeDepositSource(child: child, detachable: true)
    }

    /// Vic zu 54a493b4 (1): Ein Terminal-Tab kommt nach dem Rückfall nie
    /// zurück. Sein gegen HUP gesicherter Job bekommt kein SIGKILL.
    func testTerminalTabSurvivingSigtermIsNotKilled() async throws {
        let source = try stubbornChild()
        _ = try handOver([source], secrets: FakeSecretStore())
        var killed: [Int32] = []
        var dependencies = serviceDependencies(secrets: FakeSecretStore(),
                                               sessions: [session(for: source, kind: .terminal)], calls: Calls())
        dependencies.killProcess = { killed.append($0) }
        _ = HandoverTakeService(dependencies: dependencies).takeAtLaunch()
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertTrue(killed.isEmpty, "kein SIGKILL für einen Terminal-Tab")
        XCTAssertTrue(source.child.isAlive)
    }

    /// Vic zu 54a493b4 (2): Ohne bekannte Startzeit kein SIGKILL und kein
    /// Fortsetzen (der Prozess unter der PID könnte ein fremder sein).
    func testUnknownStartTimeMeansNoKillAndNoResume() async throws {
        let source = try stubbornChild()
        _ = try handOver([source], secrets: FakeSecretStore())
        try dropStartTimesFromMarker()
        var killed: [Int32] = []
        let calls = Calls()
        var dependencies = serviceDependencies(secrets: FakeSecretStore(), sessions: [session(for: source)], calls: calls)
        dependencies.killProcess = { killed.append($0) }
        let summary = HandoverTakeService(dependencies: dependencies).takeAtLaunch()
        XCTAssertEqual(summary.fallback, [source.sessionID])
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertTrue(killed.isEmpty, "ohne Startzeit kein SIGKILL")
        XCTAssertTrue(calls.resumed.isEmpty, "und kein Fortsetzen, solange er lebt")
        XCTAssertTrue(source.child.isAlive)
    }

    func testCertainlySameProcessNeedsBothStartTimes() {
        let now = Date()
        let alive: (Int32) -> Bool = { _ in true }
        XCTAssertTrue(HandoverPlanning.isCertainlySameProcess(pid: 42, expectedStartTime: now.timeIntervalSince1970,
                                                              isAlive: alive, startTime: { _ in now }))
        XCTAssertFalse(HandoverPlanning.isCertainlySameProcess(pid: 42, expectedStartTime: nil,
                                                               isAlive: alive, startTime: { _ in now }))
        XCTAssertFalse(HandoverPlanning.isCertainlySameProcess(pid: 42, expectedStartTime: now.timeIntervalSince1970,
                                                               isAlive: alive, startTime: { _ in nil }))
        XCTAssertFalse(HandoverPlanning.isCertainlySameProcess(pid: 42, expectedStartTime: now.timeIntervalSince1970 - 5,
                                                               isAlive: alive, startTime: { _ in now }))
        // Die nachsichtige Variante bleibt für SIGTERM, wie gewollt.
        XCTAssertTrue(HandoverPlanning.isSameProcess(pid: 42, expectedStartTime: nil, isAlive: alive, startTime: { _ in now }))
    }

    /// Marker wie von einer App, die keine Startzeit lesen konnte.
    private func dropStartTimesFromMarker() throws {
        let data = try Data(contentsOf: markerURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var handover = try XCTUnwrap(json["handover"] as? [String: Any])
        let chats = try XCTUnwrap(handover["chats"] as? [[String: Any]])
        handover["chats"] = chats.map { chat -> [String: Any] in
            var chat = chat
            chat.removeValue(forKey: "pidStartTime")
            return chat
        }
        json["handover"] = handover
        try JSONSerialization.data(withJSONObject: json).write(to: markerURL)
    }

    /// Befund 2 (Dex): Lehnt der Aufbewahrer das Geheimnis ab, beendet die
    /// App auch ihn, nicht nur die Chats. Sonst hielte er bis zur Frist und
    /// jede weitere Übergabe scheiterte mit keeperStillHolding.
    func testRejectedSecretEndsTheKeeperToo() async throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let keeper = try XCTUnwrap(HandoverTakeService.status(paths: paths))
        let wrong = FakeSecretStore()
        wrong.stored = HandoverSecret.make()
        let calls = Calls()
        let summary = service(secrets: wrong, sessions: sources.map { session(for: $0) }, calls: calls).takeAtLaunch()
        XCTAssertTrue(summary.adopted.isEmpty)
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { kill(keeper.pid, 0) != 0 }, "Aufbewahrer beendet")
        let end = Date().addingTimeInterval(15)
        while calls.resumed.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID))
        XCTAssertFalse(sources[0].child.isAlive)
    }

    /// Befund 6 (Dex): Ist die Verbindung tot, gehen die übrigen Chats sofort
    /// in den Rückfall, ohne je die Pause vor TAKE abzuwarten.
    func testDeadConnectionSendsTheRestToFallbackWithoutWaiting() throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn(), try spawn(), try spawn(), try spawn()]
        _ = try handOver(sources, secrets: secrets)
        let keeper = try XCTUnwrap(HandoverTakeService.status(paths: paths))
        let calls = Calls()
        var dependencies = serviceDependencies(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: calls)
        let adopt = dependencies.adopt
        dependencies.adopt = { taken, session in
            kill(keeper.pid, SIGKILL)
            _ = HandoverTestSupport.waitUntil(timeout: 5) { kill(keeper.pid, 0) != 0 }
            return adopt(taken, session)
        }
        dependencies.takeDelay = { 3 }
        let started = Date()
        let summary = HandoverTakeService(dependencies: dependencies).takeAtLaunch()
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(summary.adopted.count, 1)
        XCTAssertEqual(summary.fallback.count, 3)
        // Vorher: viermal 3 s (12 s). Jetzt: vor dem ersten und dem
        // gescheiterten zweiten TAKE (6 s); reichlich Luft für Last.
        XCTAssertLessThan(seconds, 9.5, "wartete \(seconds) s")
        // Dex, Befund 5: Socket und socket-path des toten Aufbewahrers sind
        // schon nach dieser Übernahme weg, nicht erst beim nächsten Start.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.preferredSocketURL.path), "keeper.sock entfernt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.discoveryFileURL.path), "socket-path entfernt")
    }

    /// Befund 4 (Dex): Während der Übernahme hält die App take.lock; danach nicht mehr.
    func testTakeHoldsTheTakeLockWhileTaking() throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: secrets)
        var heldDuringTake = false
        var dependencies = serviceDependencies(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: Calls())
        let adopt = dependencies.adopt
        dependencies.adopt = { [paths] taken, session in
            heldDuringTake = HandoverTakeLock.isHeld(paths: paths)
            return adopt(taken, session)
        }
        _ = HandoverTakeService(dependencies: dependencies).takeAtLaunch()
        XCTAssertTrue(heldDuringTake)
        XCTAssertFalse(HandoverTakeLock.isHeld(paths: paths))
    }

    func testNormalStartTakesNoLock() {
        _ = service(secrets: FakeSecretStore(), sessions: [], calls: Calls()).takeAtLaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.takeLockFileURL.path))
    }

    /// Befund kill-mid-take (Dex): Nach SIGKILL des Aufbewahrers blieb sein
    /// Socket liegen. Mit dem veralteten Discovery-Eintrag verschwindet er.
    func testStaleSocketOfAKilledKeeperIsRemoved() throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let status = try XCTUnwrap(HandoverTakeService.status(paths: paths))
        kill(status.pid, SIGKILL)
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { kill(status.pid, 0) != 0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketURL.path), "SIGKILL lässt den Socket liegen")
        XCTAssertFalse(HandoverKeeperLock.liveDiscovery(paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.discoveryFileURL.path))
    }

    /// Kein Socket, sondern eine gewöhnliche Datei am selben Ort: bleibt stehen.
    func testStaleSocketCleanupLeavesOtherFilesAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("not-a-socket")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        HandoverKeeperLock.removeStaleSocket(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTerminalTabIsEndedButNotResumed() async throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: [session(for: sources[0], kind: .terminal)],
                              calls: calls).takeAtLaunch()
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 15) { !sources[0].child.isAlive })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(calls.resumed.isEmpty)
    }

    /// Review Paket 4 (Startbremse): Ohne Marker „übergeben“ und ohne
    /// Discovery-Eintrag eines Aufbewahrers darf der Start nichts kosten, also
    /// keinen Verbindungsversuch mit Frist auf dem Main Thread.
    func testNormalStartCostsNoSocketWait() {
        let calls = Calls()
        let started = Date()
        _ = service(secrets: FakeSecretStore(), sessions: [], calls: calls).takeAtLaunch()
        let millis = Date().timeIntervalSince(started) * 1000
        print("handover_take_ohne_aufbewahrer_ms=\(Int(millis))")
        XCTAssertLessThan(millis, 50, "Start ohne Übergabe wartete \(Int(millis)) ms")
    }

    /// Vic zu e393fb03: Nach Absturz oder SIGKILL des Aufbewahrers bleibt sein
    /// Discovery-Eintrag liegen. Ohne lebende Sperre wird er entfernt, und der
    /// Start kostet keine Wartezeit.
    func testStaleDiscoveryIsRemovedWithoutWaiting() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "/private/tmp/gibt-es-nicht/keeper.sock\n".write(to: paths.discoveryFileURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: paths.lockFileURL.path, contents: nil)
        let started = Date()
        _ = service(secrets: FakeSecretStore(), sessions: [], calls: Calls()).takeAtLaunch()
        XCTAssertLessThan(Date().timeIntervalSince(started) * 1000, 50)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.discoveryFileURL.path), "veralteter Eintrag entfernt")
    }

    func testLiveKeeperLockKeepsTheDiscoveryEntry() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "x\n".write(to: paths.discoveryFileURL, atomically: true, encoding: .utf8)
        let fd = open(paths.lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "wie der Aufbewahrer")
        XCTAssertTrue(HandoverKeeperLock.isHeld(paths: paths))
        XCTAssertTrue(HandoverKeeperLock.liveDiscovery(paths: paths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.discoveryFileURL.path))
        flock(fd, LOCK_UN)
        XCTAssertFalse(HandoverKeeperLock.isHeld(paths: paths))
    }

    func testNormalStartWithoutHandoverDoesNothing() {
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: [], calls: calls).takeAtLaunch()
        XCTAssertNil(summary.previous.handover)
        XCTAssertTrue(summary.handled.isEmpty)
        XCTAssertNil(HandoverTakeReport.read(paths: paths))
    }

    /// Abgegeben, aber der Aufbewahrer ist inzwischen weg (abgestürzt): Die
    /// Chats bekamen SIGHUP; die neue App setzt sie fort.
    func testKeeperGoneMeansResume() throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let status = try XCTUnwrap(HandoverTakeService.status(paths: paths))
        kill(status.pid, SIGKILL)
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { !sources[0].child.isAlive })
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: sources.map { session(for: $0) }, calls: calls).takeAtLaunch()
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID), "tot: sofort fortsetzen")
    }
}
