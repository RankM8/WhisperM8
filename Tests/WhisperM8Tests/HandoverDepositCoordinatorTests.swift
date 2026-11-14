import Darwin
import Foundation
import SwiftTerm
import XCTest
@testable import WhisperM8

/// Paket 4b: Abgabe gegen einen echten Aufbewahrer-Prozess aus dem gebauten
/// Binary. Die „Chats“ sind `/bin/sh`-Kinder über `forkpty`; der Testprozess
/// spielt alte und neue App.
@MainActor
final class HandoverDepositCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var children: [HandoverPTYChild] = []

    override func setUp() async throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() async throws {
        for child in children { child.kill() }
        // Ein Aufbewahrer, der noch hält, endet mit seinem Ordner nicht von selbst.
        if let client = try? HandoverClient.connect(paths: paths, timeout: 0.3),
           let status = try? client.status() {
            kill(status.pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private var paths: HandoverPaths { HandoverPaths(directory: directory) }

    private func coordinator(secrets: FakeSecretStore,
                             onMainThread: Bool = true,
                             launch: ((URL, [String], String) throws -> Process)? = nil) throws -> HandoverDepositCoordinator {
        var dependencies = HandoverDepositCoordinator.Dependencies(
            paths: paths,
            keeperExecutable: try HandoverTestSupport.keeperBinary(),
            appBinaries: [HandoverTestSupport.ownExecutablePath],
            secretStore: secrets,
            holdSeconds: 60)
        if let launch { dependencies.launch = launch }
        if !onMainThread { dependencies.isMainThread = { false } }
        return HandoverDepositCoordinator(dependencies: dependencies)
    }

    private func spawnSource(detachable: Bool = true) throws -> FakeDepositSource {
        let child = try HandoverPTYChild.ticking(in: directory)
        children.append(child)
        return FakeDepositSource(child: child, detachable: detachable)
    }

    private func items(_ sources: [FakeDepositSource]) -> [HandoverDepositCoordinator.Item] {
        sources.map { source in
            HandoverDepositCoordinator.Item(source: source) { detached in
                source.child.manifest(chatID: detached.sessionID.uuidString)
            }
        }
    }

    func testDepositHandsChatsOverAndNewAppTakesThemWithStoredSecret() throws {
        let secrets = FakeSecretStore()
        let sources = [try spawnSource(), try spawnSource()]
        let outcome = try coordinator(secrets: secrets).deposit(items(sources))

        guard case let .handedOver(runID, keeperPID, _, chats, notHandedOver) = outcome else {
            return XCTFail("erwartet: übergeben, war \(outcome)")
        }
        XCTAssertEqual(Set(chats.map(\.sessionID)), Set(sources.map(\.sessionID)))
        XCTAssertEqual(chats.map(\.pid).sorted(), sources.map(\.child.pid).sorted())
        XCTAssertTrue(notHandedOver.isEmpty)
        // Erst nach COMMIT schließt die App ihre Kopien.
        XCTAssertTrue(sources.allSatisfy { $0.completed && $0.child.master == -1 })
        XCTAssertTrue(sources.allSatisfy { $0.reattached == 0 })

        // Neue App: Geheimnis aus dem Schlüsselbund, dann übernehmen.
        guard case .found(let secret) = secrets.load() else { return XCTFail("Geheimnis fehlt") }
        let take = try HandoverClient.connect(paths: paths, timeout: 5)
        take.timeout = 10
        XCTAssertEqual(try take.helloTake(secret: secret).runID, runID)
        for source in sources {
            let taken = try take.take(chatID: source.sessionID.uuidString)
            XCTAssertFalse(taken.exited)
            if let fd = taken.descriptor { close(fd) }
        }
        try take.done()
        take.close()
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { kill(keeperPID, 0) != 0 }, "Aufbewahrer endet nach DONE")
        for source in sources {
            XCTAssertFalse(source.child.marker.contains("INT"), "kein Ctrl+C bei der Übergabe")
        }
    }

    func testRefusedSecretStoreRollsBackAndChatsKeepRunningInTheApp() throws {
        let secrets = FakeSecretStore()
        secrets.refuseStore = true
        let sources = [try spawnSource(), try spawnSource()]
        var keeper: Process?
        let outcome = try coordinator(secrets: secrets) { executable, arguments, secret in
            let process = try HandoverKeeperLauncher.launch(executable: executable, arguments: arguments, secret: secret)
            keeper = process
            return process
        }.deposit(items(sources))

        guard case .failed = outcome else { return XCTFail("erwartet: gescheitert, war \(outcome)") }
        XCTAssertTrue(sources.allSatisfy { $0.reattached == 1 && !$0.completed })
        XCTAssertTrue(sources.allSatisfy { $0.child.master >= 0 }, "Originale bleiben offen")
        let process = try XCTUnwrap(keeper)
        XCTAssertTrue(HandoverTestSupport.waitForExit(process, timeout: 10), "Aufbewahrer endet ohne Abgabe")
        usleep(200_000)
        for source in sources {
            XCTAssertTrue(source.child.isAlive)
            XCTAssertEqual(source.child.marker, "", "weder Ctrl+C noch SIGHUP")
        }
        XCTAssertEqual(secrets.load(), .missing)
    }

    func testChatThatCannotDetachStaysInTheApp() throws {
        let secrets = FakeSecretStore()
        let movable = try spawnSource()
        let stuck = try spawnSource(detachable: false)
        let outcome = try coordinator(secrets: secrets).deposit(items([movable, stuck]))
        guard case let .handedOver(_, _, _, chats, notHandedOver) = outcome else {
            return XCTFail("erwartet: übergeben, war \(outcome)")
        }
        XCTAssertEqual(chats.map(\.sessionID), [movable.sessionID])
        XCTAssertEqual(notHandedOver, [stuck.sessionID])
        XCTAssertFalse(stuck.completed)
        XCTAssertGreaterThanOrEqual(stuck.child.master, 0)
    }

    func testNothingDetachedEndsKeeperAndReportsFailure() throws {
        let secrets = FakeSecretStore()
        var keeper: Process?
        let outcome = try coordinator(secrets: secrets) { executable, arguments, secret in
            let process = try HandoverKeeperLauncher.launch(executable: executable, arguments: arguments, secret: secret)
            keeper = process
            return process
        }.deposit(items([try spawnSource(detachable: false)]))
        guard case .failed = outcome else { return XCTFail("erwartet: gescheitert, war \(outcome)") }
        XCTAssertTrue(HandoverTestSupport.waitForExit(try XCTUnwrap(keeper), timeout: 10))
        XCTAssertEqual(secrets.load(), .missing)
    }

    func testKeeperThatDoesNotStartLeavesChatsUntouched() throws {
        let source = try spawnSource()
        let outcome = try coordinator(secrets: FakeSecretStore()) { _, _, _ in
            throw HandoverWireError.unexpected("kein Binary")
        }.deposit(items([source]))
        guard case .failed = outcome else { return XCTFail("erwartet: gescheitert, war \(outcome)") }
        XCTAssertEqual(source.detachCalls, 0, "ohne Aufbewahrer wird nichts abgelöst")
    }

    /// Urteil zur Absender-Bindung: Abseits des Main Threads entsteht kein
    /// Socket und nichts wird abgelöst; der heutige Weg greift.
    func testDepositOffTheMainThreadDoesNothing() throws {
        let source = try spawnSource()
        var launched = false
        let outcome = try coordinator(secrets: FakeSecretStore(), onMainThread: false) { _, _, _ in
            launched = true
            throw HandoverWireError.unexpected("nicht erwartet")
        }.deposit(items([source]))
        guard case .failed(let reason) = outcome else { return XCTFail("erwartet: gescheitert, war \(outcome)") }
        XCTAssertTrue(reason.contains("Main Thread"))
        XCTAssertFalse(launched, "kein Aufbewahrer")
        XCTAssertEqual(source.detachCalls, 0, "keine Leitung abgelöst")
        XCTAssertGreaterThanOrEqual(source.child.master, 0)
    }

    func testEmptyListNeedsNoKeeper() throws {
        var launched = false
        let outcome = try coordinator(secrets: FakeSecretStore()) { _, _, _ in
            launched = true
            throw HandoverWireError.unexpected("nicht erwartet")
        }.deposit([])
        XCTAssertEqual(outcome, .nothingToHandOver)
        XCTAssertFalse(launched)
    }
}

// MARK: - Doubles

final class FakeSecretStore: HandoverSecretStoring {
    var stored: String?
    var refuseStore = false

    func store(_ secret: String) -> Bool {
        guard !refuseStore else { return false }
        stored = secret
        return true
    }

    func load() -> HandoverSecretLookup { stored.map { .found($0) } ?? .missing }

    func remove() { stored = nil }
}

/// Ein PTY-Kind als Chat der App: Die „Kopie“ der App ist sein Master.
@MainActor
final class FakeDepositSource: HandoverDepositSource {
    let sessionID = UUID()
    let child: HandoverPTYChild
    let detachable: Bool
    private(set) var detachCalls = 0
    private(set) var reattached = 0
    private(set) var completed = false

    init(child: HandoverPTYChild, detachable: Bool) {
        self.child = child
        self.detachable = detachable
    }

    func detachForHandoverDeposit() -> HandoverDetachedChat? {
        detachCalls += 1
        guard detachable else { return nil }
        return HandoverDetachedChat(
            sessionID: sessionID,
            handle: LocalProcess.HandoverHandle(fileDescriptor: child.master, pid: child.pid),
            image: Array("tick 0\r\n".utf8), cols: 80, rows: 24,
            colors: HandoverTerminalColors(foreground: "#ffffff", background: "#000000"))
    }

    func reattachAfterFailedHandover() -> Bool {
        reattached += 1
        return true
    }

    func completeHandover() {
        completed = true
        child.closeMaster()
    }
}

// MARK: - CLI `app handover`, `--wait-take`

final class HandoverRestartCLITests: XCTestCase {
    private struct Unreachable: Error {}

    /// Uhr und Übernahme zum Durchspielen: Die Übernahme endet nach `takeSteps`
    /// Wartezyklen, der Socket antwortet ab dem `answersFrom`-ten Versuch.
    private final class Scenario {
        var clock = Date(timeIntervalSince1970: 0)
        var takeSteps: Int
        var answersFrom: Int
        var sends = 0
        var notices: [String] = []
        init(takeSteps: Int, answersFrom: Int) { self.takeSteps = takeSteps; self.answersFrom = answersFrom }

        var wait: AppCLICommand.TakeWait {
            AppCLICommand.TakeWait(
                takeInProgress: { self.takeSteps > 0 },
                maxWait: 60, settle: 5,
                sleep: { self.clock = self.clock.addingTimeInterval($0); if self.takeSteps > 0 { self.takeSteps -= 1 } },
                now: { self.clock },
                notice: { self.notices.append($0) })
        }

        func send() throws -> ChatsControlResponse {
            sends += 1
            guard sends >= answersFrom else { throw Unreachable() }
            return .success(requestID: "r", result: .object(["outcome": .string("handedOver")]))
        }
    }

    /// Befund 4 (Dex): Ein zweiter Neustart mitten in der Übernahme wartet,
    /// bis die App übernommen hat und ihr Socket antwortet.
    func testHandoverWaitsForARunningTake() throws {
        let scenario = Scenario(takeSteps: 10, answersFrom: 3)
        let response = try AppCLICommand.sendWaitingForTake(wait: scenario.wait, scenario.send)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(scenario.sends, 3)
        XCTAssertGreaterThanOrEqual(scenario.clock.timeIntervalSince1970, 2, "erst nach der Übernahme")
        XCTAssertEqual(scenario.notices.count, 1, "sagt sichtbar, worauf es wartet")
    }

    /// Ohne laufende Übernahme bleibt „nicht erreichbar“ sofort (Exit 5).
    func testUnreachableWithoutTakeFailsAtOnce() {
        let scenario = Scenario(takeSteps: 0, answersFrom: 99)
        XCTAssertThrowsError(try AppCLICommand.sendWaitingForTake(wait: scenario.wait, scenario.send))
        XCTAssertEqual(scenario.sends, 1)
        XCTAssertTrue(scenario.notices.isEmpty)
    }

    /// Nach einem Absturz liegt take.lock noch da, aber niemand hält sie:
    /// Sie blockiert nichts.
    func testLeftoverTakeLockFileBlocksNothing() throws {
        let directory = try HandoverTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = HandoverPaths(directory: directory)
        guard case .acquired(let fd) = HandoverTakeLock.acquire(paths: paths) else { return XCTFail("Sperre nicht bekommen") }
        XCTAssertEqual(HandoverTakeLock.acquire(paths: paths), .heldByOther, "zweiter Versuch sieht die gehaltene Sperre")
        XCTAssertTrue(HandoverTakeLock.isHeld(paths: paths))
        HandoverTakeLock.release(fd)   // wie das Ende des Prozesses
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.takeLockFileURL.path))
        XCTAssertFalse(HandoverTakeLock.isHeld(paths: paths))
    }

    /// Antwortet der Socket auch nach der Übernahme nicht, gibt die CLI nach
    /// der Nachfrist auf.
    func testGivesUpAfterTheSettlePeriod() {
        let scenario = Scenario(takeSteps: 2, answersFrom: 999)
        XCTAssertThrowsError(try AppCLICommand.sendWaitingForTake(wait: scenario.wait, scenario.send))
        XCTAssertLessThanOrEqual(scenario.clock.timeIntervalSince1970, 0.4 + 5.4)
    }

    /// Vic (Gesamt-Review Teil 1): make dev bleibt bei ausgeschaltetem
    /// Schalter still; andere Gründe und andere Aufrufer melden weiter.
    func testMakeDevStaysSilentWhenTheFeatureIsOff() {
        XCTAssertFalse(AppCLICommand.reportsClassic(reason: "featureDisabled", silentWhenDisabled: true))
        XCTAssertTrue(AppCLICommand.reportsClassic(reason: "featureDisabled", silentWhenDisabled: false))
        XCTAssertTrue(AppCLICommand.reportsClassic(reason: "notARestart", silentWhenDisabled: true))
        XCTAssertEqual(AppCLICommand.exitCode(outcome: "classic", reason: "featureDisabled", result: .object([:]),
                                              quiet: false, silentWhenDisabled: true), 2, "Exit bleibt 2")
    }

    func testOutcomeMapsToExitCodes() {
        let empty = ChatsControlJSON.object([:])
        XCTAssertEqual(AppCLICommand.exitCode(outcome: "handedOver", reason: nil, result: empty, quiet: true), 0)
        XCTAssertEqual(AppCLICommand.exitCode(outcome: "classic", reason: "featureDisabled", result: empty, quiet: true), 2)
        XCTAssertEqual(AppCLICommand.exitCode(outcome: "failed", reason: "busy", result: empty, quiet: true), 4)
        XCTAssertEqual(AppCLICommand.exitCode(outcome: "", reason: nil, result: empty, quiet: true), 4)
    }

    func testResultJSONCarriesRunAndChats() {
        let id = UUID()
        let json = AgentControlRequestHandler.json(.init(kind: .handedOver, reason: nil, runID: "r1", keeperPID: 77,
                                                         handedOver: [id], notHandedOver: []))
        XCTAssertEqual(json["outcome"]?.stringValue, "handedOver")
        XCTAssertEqual(json["runID"]?.stringValue, "r1")
        XCTAssertEqual(json["handedOver"]?.arrayValue?.first?.stringValue, id.uuidString)
        XCTAssertEqual(AgentControlRequestHandler.featureRoute(for: "app.handover"), .handover)
        XCTAssertEqual(ChatsControlProtocol.handlerTimeoutSeconds(for: "app.handover"), 30)
    }

    func testWaitTakeReadsReportOfTheRightRun() throws {
        let directory = try HandoverTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = HandoverPaths(directory: directory)
        XCTAssertEqual(AppCLICommand.waitForTake(runID: "r1", timeout: 0.3, paths: paths), 3, "kein Bericht")

        HandoverTakeReport(runID: "r0", finishedAt: 1, adopted: ["a"], endedInGap: [], fallback: []).write(paths: paths)
        XCTAssertEqual(AppCLICommand.waitForTake(runID: "r1", timeout: 0.3, paths: paths), 3, "fremder Lauf")

        HandoverTakeReport(runID: "r1", finishedAt: 2, adopted: ["a"], endedInGap: ["b"], fallback: []).write(paths: paths)
        XCTAssertEqual(AppCLICommand.waitForTake(runID: "r1", timeout: 0.3, paths: paths), 0)

        HandoverTakeReport(runID: "r1", finishedAt: 3, adopted: ["a"], endedInGap: [], fallback: ["c"]).write(paths: paths)
        XCTAssertEqual(AppCLICommand.waitForTake(runID: "r1", timeout: 0.3, paths: paths), 3, "Rückfall")
    }

    /// Review Paket 4, Befund 5: Aus einem Chat nur über `make dev`.
    func testHandoverFromAChatNeedsMakeDev() {
        typealias H = AgentControlRequestHandler
        XCTAssertFalse(H.refusesHandoverFromChat(sessionID: nil, fromMakeDev: false), "Terminal, Skript")
        XCTAssertFalse(H.refusesHandoverFromChat(sessionID: "", fromMakeDev: false))
        XCTAssertTrue(H.refusesHandoverFromChat(sessionID: UUID().uuidString, fromMakeDev: false), "aus einem Chat")
        XCTAssertFalse(H.refusesHandoverFromChat(sessionID: UUID().uuidString, fromMakeDev: true), "make dev aus einem Chat")
    }

    /// Hinweis von Dex: Der Bericht nutzt den geprüften Ordner des Aufbewahrers,
    /// die Datei hat 0600, ein Symlink als Ordner wird nicht beschrieben.
    func testTakeReportUsesTheCheckedDirectoryAndPrivateFile() throws {
        let base = try HandoverTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let report = HandoverTakeReport(runID: "r", finishedAt: 1, adopted: [], endedInGap: [], fallback: [])

        let open = HandoverPaths(directory: base.appendingPathComponent("weit"))
        try FileManager.default.createDirectory(at: open.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(report.write(paths: open))
        let dirMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: open.directory.path)[.posixPermissions] as? Int)
        XCTAssertEqual(dirMode & 0o777, 0o700, "Ordner auf 0700 gezogen")
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: HandoverTakeReport.fileURL(paths: open).path)[.posixPermissions] as? Int)
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(HandoverTakeReport.read(paths: open), report)

        let target = base.appendingPathComponent("ziel")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(report.write(paths: HandoverPaths(directory: link)), "Symlink als Ordner wird abgelehnt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("last-take.json").path))
    }

    func testMakefileTriesHandoverBeforeKillAndSparesKeeper() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let makefile = try String(contentsOf: repo.appendingPathComponent("Makefile"), encoding: .utf8)
        let finish = try XCTUnwrap(makefile.range(of: "_dev_finish:\n")).upperBound
        let body = makefile[finish...].prefix(80)
        XCTAssertTrue(body.hasPrefix("\t@$(MAKE) _handover\n\t@$(MAKE) kill"), "Übergabe vor kill: \(body)")
        XCTAssertTrue(makefile.contains("app handover --from-make-dev"), "make dev weist sich aus (Befund 5)")
        XCTAssertTrue(makefile.contains("[ \"$$young\" = ja ]"), "ohne Socket nur warten, wenn die App gerade startet (Befund 6)")
        // WM8-98: Scheitern nach der Abgabe meldet einen Satz, keine Leerzeile.
        XCTAssertTrue(makefile.contains("Installieren gescheitert. $(HANDOVER_HINT)"))
        XCTAssertTrue(makefile.contains("Start gescheitert. $(HANDOVER_HINT)"))
        XCTAssertTrue(makefile.contains("[ -n \"$$out\" ] && echo \"$$out\""))
        XCTAssertTrue(AppCLICommand.disabledLine.contains("Labs"), "Satz statt Leerzeile bei ausgeschaltetem Schalter")
        XCTAssertFalse(AppCLICommand.disabledLine.contains("fortgesetzt"),
                       "ohne Schalter merkt die App nichts zum Fortsetzen vor")
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/test-instance.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("--keep-chats"))
        XCTAssertTrue(script.contains("--wait-take"))
        // Dex, Nachlauf: Die Wartemeldung während einer laufenden Übernahme
        // muss durchkommen, auch wenn das Skript die Ausgabe auffängt.
        XCTAssertTrue(script.contains("app handover --json 2> >(tee"), "stderr live durchgereicht")
    }
}

// MARK: - Terminal-Controller

/// Ablösen am echten Controller (SwiftTerm-View ohne Fenster, `/bin/sh`-Kind).
@MainActor
final class HandoverTerminalControllerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func spin(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { spin(0.02) }
        return condition()
    }

    private func screenText(_ controller: AgentTerminalController) -> String {
        String(decoding: controller.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func startTicking() throws -> (AgentTerminalController, URL) {
        let script = directory.appendingPathComponent("tick.sh")
        let marker = directory.appendingPathComponent("marker")
        try """
        trap 'echo INT >> "\(marker.path)"' INT
        trap 'echo HUP >> "\(marker.path)"; exit 129' HUP
        i=0; while [ $i -lt 100000 ]; do i=$((i+1)); echo "tick $i"; sleep 0.03; done
        """.write(to: script, atomically: true, encoding: .utf8)
        let controller = AgentTerminalController(
            sessionID: UUID(),
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: [script.path],
                                        workingDirectory: directory.path, keyboardProfile: .claudeCodeChat),
            onLaunched: {}, onTerminated: { _ in })
        controller.start()
        return (controller, marker)
    }

    func testDetachKeepsProcessAliveAndReattachResumesOutput() throws {
        let (controller, marker) = try startTicking()
        let pid = try XCTUnwrap(controller.processID)
        defer { kill(pid, SIGKILL) }
        XCTAssertTrue(spin(until: 5) { screenText(controller).contains("tick 3") })

        let detached = try XCTUnwrap(controller.detachForHandover())
        XCTAssertEqual(detached.handle.pid, pid)
        XCTAssertEqual(detached.sessionID, controller.sessionID)
        XCTAssertTrue(String(decoding: detached.image, as: UTF8.self).contains("tick"), "Bild enthält die Ausgabe")
        XCTAssertNotNil(detached.colors)
        XCTAssertNil(controller.detachForHandover(), "kein zweites Ablösen")

        // Während abgelöst ist, liest niemand: der Bildschirm bleibt stehen.
        let frozen = screenText(controller)
        spin(0.2)
        XCTAssertEqual(screenText(controller), frozen)
        XCTAssertEqual(kill(pid, 0), 0, "Prozess lebt ohne Leser weiter")

        XCTAssertTrue(controller.reattachAfterFailedHandover())
        XCTAssertTrue(spin(until: 5) { screenText(controller) != frozen }, "nach dem Zurückholen geht die Ausgabe weiter")
        XCTAssertEqual((try? String(contentsOf: marker, encoding: .utf8)) ?? "", "", "weder Ctrl+C noch SIGHUP")
    }

    /// Ende eines übernommenen Chats: dieselbe Ende-Meldung wie bei gestarteten
    /// Chats (Store, Status), danach der Teil, den eine Ansicht angehängt hat.
    func testAdoptedChatReportsItsEndThroughTheRegistryAndAnAttachedView() throws {
        let (original, _) = try startTicking()
        let pid = try XCTUnwrap(original.processID)
        XCTAssertTrue(spin(until: 5) { screenText(original).contains("tick 2") })
        let detached = try XCTUnwrap(original.detachForHandover())

        var log: [String] = []
        let termination = AgentChatTermination(
            markClosed: { _ in log.append("store") },
            notifyStatus: { _, _ in log.append("status") })
        let registry = AgentTerminalRegistry(sleep: { _ in }, termination: termination)
        var manifest = HandoverManifest(chatID: original.sessionID.uuidString, kind: "terminal", pid: pid,
                                        pidStartTime: ProcessStartTime.of(pid: pid)?.timeIntervalSince1970,
                                        cols: detached.cols, rows: detached.rows, sendsInterruptOnStop: false)
        manifest.controlToken = "tok"
        let adopted = try XCTUnwrap(registry.adoptController(
            sessionID: original.sessionID, command: original.command,
            // Wie über den Aufbewahrer: die neue Seite bekommt eine eigene Kopie.
            setUp: { $0.adoptHandedOver(descriptor: dup(detached.handle.fileDescriptor), manifest: manifest,
                                        image: detached.image) }))
        original.completeHandover()   // schließt nur die Kopie der alten Seite
        XCTAssertTrue(adopted.isAdopted)
        XCTAssertTrue(adopted.isRunning)
        XCTAssertEqual(registry.activeSessionIDs, [original.sessionID])
        XCTAssertTrue(spin(until: 5) { screenText(adopted).contains("tick") }, "Bild und neue Ausgabe kommen an")

        adopted.viewTerminationHandler = { _ in log.append("view") }
        kill(pid, SIGKILL)
        XCTAssertTrue(spin(until: 10) { log.contains("view") })
        XCTAssertEqual(log, ["store", "status", "view"])
        XCTAssertFalse(adopted.isRunning)
        XCTAssertTrue(registry.activeSessionIDs.isEmpty)
    }

    /// Review Paket 4, Befund 8: Der übernommene Chat startet mit der Größe aus
    /// dem Manifest; sobald die Ansicht ihre echte Größe bekommt, erfährt der
    /// Prozess sie (TIOCSWINSZ, also SIGWINCH). Ohne Ansicht bleibt die alte.
    func testAdoptedChatGetsTheRealSizeOnceTheViewIsLaidOut() throws {
        let (original, _) = try startTicking()
        let pid = try XCTUnwrap(original.processID)
        defer { kill(pid, SIGKILL) }
        XCTAssertTrue(spin(until: 5) { screenText(original).contains("tick 2") })
        let detached = try XCTUnwrap(original.detachForHandover())
        let probe = dup(detached.handle.fileDescriptor)
        defer { close(probe) }
        func childSize() -> (Int, Int) {
            var size = winsize()
            _ = ioctl(probe, TIOCGWINSZ, &size)
            return (Int(size.ws_col), Int(size.ws_row))
        }
        let before = childSize()
        XCTAssertEqual(before.0, detached.cols)
        XCTAssertEqual(before.1, detached.rows)

        let registry = AgentTerminalRegistry(
            sleep: { _ in }, termination: AgentChatTermination(markClosed: { _ in }, notifyStatus: { _, _ in }))
        let manifest = HandoverManifest(chatID: original.sessionID.uuidString, kind: "terminal", pid: pid,
                                        pidStartTime: ProcessStartTime.of(pid: pid)?.timeIntervalSince1970,
                                        cols: detached.cols, rows: detached.rows, sendsInterruptOnStop: false)
        let adopted = try XCTUnwrap(registry.adoptController(
            sessionID: original.sessionID, command: original.command,
            setUp: { $0.adoptHandedOver(descriptor: dup(detached.handle.fileDescriptor), manifest: manifest,
                                        image: detached.image) }))
        original.completeHandover()
        let core = adopted.terminal.getTerminal()
        XCTAssertEqual(core.cols, detached.cols, "zuerst die Größe aus dem Manifest")
        spin(0.3)
        XCTAssertTrue(childSize() == before, "ohne Ansicht keine neue Größe")

        // Die Ansicht legt sich an: deutlich größer als das alte Fenster.
        adopted.terminal.setFrameSize(NSSize(width: 2400, height: 1400))
        XCTAssertNotEqual(core.cols, detached.cols)
        XCTAssertTrue(spin(until: 3) { childSize() == (core.cols, core.rows) },
                      "Prozess kennt die echte Größe: \(childSize()) statt \((core.cols, core.rows))")
        XCTAssertTrue(adopted.isRunning)
    }

    /// Vic (Gesamt-Review Teil 1): Abseits des Main Threads fällt der
    /// Controller zurück, statt abzustürzen; der Chat läuft unverändert weiter.
    func testWrongThreadFallsBackInsteadOfCrashing() throws {
        let (controller, marker) = try startTicking()
        let pid = try XCTUnwrap(controller.processID)
        defer { kill(pid, SIGKILL) }
        XCTAssertTrue(spin(until: 5) { screenText(controller).contains("tick 2") })
        AgentTerminalController.isMainThreadCheck = { false }
        defer { AgentTerminalController.isMainThreadCheck = { Thread.isMainThread } }
        XCTAssertNil(controller.detachForHandover(), "kein Ablösen abseits des Main Threads")
        XCTAssertTrue(controller.isRunning)
        let manifest = HandoverManifest(chatID: "x", kind: "terminal", pid: pid, cols: 80, rows: 24,
                                        sendsInterruptOnStop: false)
        XCTAssertFalse(controller.adoptHandedOver(descriptor: -1, manifest: manifest, image: []))
        XCTAssertEqual(kill(pid, 0), 0, "Prozess lebt weiter")
        XCTAssertEqual((try? String(contentsOf: marker, encoding: .utf8)) ?? "", "", "weder Ctrl+C noch SIGHUP")
    }

    /// Review Paket 4, Befund 2: Nach der Abgabe startet die Registry nichts mehr.
    func testRegistryRefusesStartsAfterHandover() throws {
        let registry = AgentTerminalRegistry(sleep: { _ in }, termination: .inert)
        registry.refuseNewStarts()
        let id = UUID()
        var launched = false
        let controller = registry.startController(
            sessionID: id,
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", "sleep 30"],
                                        workingDirectory: NSTemporaryDirectory(), keyboardProfile: .plainShell),
            onLaunched: { launched = true }, onTerminated: { _ in })
        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(launched)
        XCTAssertNil(registry.controller(for: id), "nicht eingetragen")
        XCTAssertNil(registry.adoptController(sessionID: id, command: controller.command, setUp: { _ in true }))
        XCTAssertTrue(registry.activeSessionIDs.isEmpty)
    }

    /// Review Paket 4, Befund 3: Ohne Übergabe merkt das folgende SIGTERM die
    /// Chats zum Fortsetzen vor, aber nur kurz nach der Anfrage.
    func testResumeOnSignalQuitOnlyShortlyAfterARefusedRestart() {
        let service = HandoverRestartService()
        var clock = Date(timeIntervalSince1970: 1_000)
        service.now = { clock }
        XCTAssertFalse(service.resumesOnSignalQuit())
        service.noteResumeOnSignalQuit()
        XCTAssertTrue(service.resumesOnSignalQuit())
        clock = clock.addingTimeInterval(61)
        XCTAssertFalse(service.resumesOnSignalQuit(), "ein späteres, unabhängiges Beenden erbt nichts")
    }

    func testCompletedHandoverIsNotRunningAndGetsNoInterruptOnQuit() throws {
        let (controller, marker) = try startTicking()
        let pid = try XCTUnwrap(controller.processID)
        XCTAssertTrue(spin(until: 5) { screenText(controller).contains("tick 2") })
        let detached = try XCTUnwrap(controller.detachForHandover())
        // Der Aufbewahrer hält eine eigene Kopie; hier spielt das der Test.
        let keeperCopy = dup(detached.handle.fileDescriptor)
        controller.completeHandover()

        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.isHandedOver)
        XCTAssertNil(controller.handoverHandle)
        controller.sendInterruptForAppQuit()
        spin(0.2)
        XCTAssertEqual(kill(pid, 0), 0)
        XCTAssertEqual((try? String(contentsOf: marker, encoding: .utf8)) ?? "", "", "kein Ctrl+C an übergebene Chats")

        close(keeperCopy)
        kill(pid, SIGKILL)
    }
}
