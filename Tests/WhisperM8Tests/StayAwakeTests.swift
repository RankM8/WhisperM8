import Combine
import Foundation
import XCTest
@testable import WhisperM8

final class StayAwakeTests: XCTestCase {
    private func conditions(
        working: Bool = false, ac: Bool = true, battery: Int? = 80, thermal: ProcessInfo.ThermalState = .nominal
    ) -> StayAwakeConditions {
        StayAwakeConditions(anyChatWorking: working, onACPower: ac, batteryPercent: battery, thermalState: thermal)
    }

    // MARK: Regeln

    func testModeCyclesOffWorkingAlwaysOff() {
        XCTAssertEqual(StayAwakeMode.off.next, .whileWorking)
        XCTAssertEqual(StayAwakeMode.whileWorking.next, .always)
        XCTAssertEqual(StayAwakeMode.always.next, .off)
    }

    func testWhileWorkingNeedsPowerAndWorkOrGrace() {
        let now = Date(timeIntervalSince1970: 10_000)
        func check(_ c: StayAwakeConditions, last: Date? = nil) -> Bool {
            StayAwakePolicy.shouldDisableSleep(mode: .whileWorking, conditions: c, lastWorkingAt: last, now: now)
        }
        XCTAssertTrue(check(conditions(working: true)))
        XCTAssertFalse(check(conditions(working: true, ac: false)))
        XCTAssertFalse(check(conditions(working: false)))
        XCTAssertTrue(check(conditions(working: false), last: now.addingTimeInterval(-60)))
        XCTAssertFalse(check(conditions(working: false), last: now.addingTimeInterval(-StayAwakePolicy.workingGrace)))
        XCTAssertFalse(check(conditions(working: true, thermal: .serious)))
    }

    func testOffNeverAndAlwaysAlwaysDisableSleep() {
        let now = Date()
        XCTAssertFalse(StayAwakePolicy.shouldDisableSleep(mode: .off, conditions: conditions(working: true), lastWorkingAt: now, now: now))
        XCTAssertTrue(StayAwakePolicy.shouldDisableSleep(mode: .always, conditions: conditions(ac: false, battery: 50), lastWorkingAt: nil, now: now))
    }

    func testAlwaysEndsOnHeatLowBatteryAndTimeLimit() {
        let since = Date(timeIntervalSince1970: 0)
        let soon = since.addingTimeInterval(60)
        XCTAssertNil(StayAwakePolicy.endReason(conditions(ac: false, battery: 21), alwaysSince: since, now: soon))
        XCTAssertEqual(StayAwakePolicy.endReason(conditions(ac: false, battery: 20), alwaysSince: since, now: soon), .lowBattery)
        // Am Strom zählt der Akkustand nicht.
        XCTAssertNil(StayAwakePolicy.endReason(conditions(ac: true, battery: 5), alwaysSince: since, now: soon))
        XCTAssertEqual(StayAwakePolicy.endReason(conditions(thermal: .critical), alwaysSince: since, now: soon), .hot)
        XCTAssertEqual(
            StayAwakePolicy.endReason(conditions(), alwaysSince: since, now: since.addingTimeInterval(StayAwakePolicy.alwaysTimeLimit)),
            .timeLimit)
        // Mac ohne Akku: nur Hitze und Zeit.
        XCTAssertNil(StayAwakePolicy.endReason(conditions(ac: false, battery: nil), alwaysSince: since, now: soon))
    }

    // MARK: Freigabe

    func testSudoersRuleAllowsExactlyTheTwoPmsetCalls() throws {
        let line = try XCTUnwrap(SleepDisablePermission.sudoersLine(user: "giulianocosta"))
        XCTAssertEqual(line, "giulianocosta ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1")
        XCTAssertNil(SleepDisablePermission.sudoersLine(user: "a b"))
        XCTAssertNil(SleepDisablePermission.sudoersLine(user: "x'; rm -rf /"))
        XCTAssertNil(SleepDisablePermission.sudoersLine(user: "-root"))
        XCTAssertNil(SleepDisablePermission.sudoersLine(user: ""))
    }

    func testInstallScriptChecksWithVisudoBeforeInstalling() throws {
        let script = try XCTUnwrap(SleepDisablePermission.installScript(user: "giulianocosta"))
        let visudo = try XCTUnwrap(script.range(of: "/usr/sbin/visudo -cf"))
        let install = try XCTUnwrap(script.range(of: "/usr/bin/install -m 0440 -o root -g wheel"))
        XCTAssertLessThan(visudo.lowerBound, install.lowerBound)
        XCTAssertTrue(script.contains(SleepDisablePermission.sudoersPath))
        XCTAssertNil(SleepDisablePermission.installScript(user: "bad user"))
        try assertShellSyntax(script)
        try assertShellSyntax(SleepDisablePermission.removeScript)
        try assertShellSyntax(SleepDisablePermission.watchdogScript)
    }

    /// Die Regel aus dem Skript ist für `visudo` gültig (ohne root, nur Prüfung).
    func testGeneratedSudoersLinePassesVisudo() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-sudoers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try (SleepDisablePermission.sudoersLine(user: "giulianocosta")! + "\n").write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-cf", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testAppleScriptEscapesQuotesAndBackslashes() {
        let script = SleepDisablePermission.adminAppleScript(shell: #"printf '%s\n' "$tmp""#, prompt: #"Sag "ja""#)
        XCTAssertEqual(
            script,
            #"do shell script "printf '%s\\n' \"$tmp\"" with prompt "Sag \"ja\"" with administrator privileges"#)
    }

    func testParseSleepDisabledFromPmset() {
        let output = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"
        XCTAssertEqual(SleepDisablePermission.parseSleepDisabled(output), true)
        XCTAssertEqual(SleepDisablePermission.parseSleepDisabled(" SleepDisabled\t\t0\n"), false)
        XCTAssertNil(SleepDisablePermission.parseSleepDisabled("Currently in use:\n sleep 1\n"))
    }

    private func assertShellSyntax(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Syntaxfehler in:\n\(script)", file: file, line: line)
    }

    // MARK: Controller

    @MainActor
    func testFirstClickAsksForPermissionThenHoldsAwakeWhileWorking() throws {
        let system = FakeStayAwakeSystem(installed: false)
        let (controller, prefs, working) = makeController(system)
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .missing }

        controller.cycle()
        waitUntil { controller.mode == .whileWorking }
        XCTAssertEqual(system.installCalls, 1)
        XCTAssertTrue(prefs.stayAwakeWhileWorking)

        working.send(true)
        waitUntil { system.lastSet == true }
        waitUntil { controller.isHoldingAwake }
        XCTAssertEqual(system.watchdogStarts, 1)
    }

    @MainActor
    func testCancelledPasswordDialogKeepsMacSleeping() {
        let system = FakeStayAwakeSystem(installed: false, installSucceeds: false)
        let (controller, prefs, working) = makeController(system)
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .missing }
        controller.cycle()
        waitUntil { !controller.isAwaitingPermission && system.installCalls == 1 }
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(prefs.stayAwakeWhileWorking)
        XCTAssertFalse(system.setCalls.contains(true))
    }

    @MainActor
    func testAlwaysEndsOnLowBatteryAndFallsBackToWhileWorking() {
        let system = FakeStayAwakeSystem(installed: true)
        let (controller, prefs, working) = makeController(system)
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .ready }
        controller.cycle()
        controller.cycle()
        XCTAssertEqual(controller.mode, .always)
        waitUntil { system.lastSet == true }

        system.power = (false, 15)
        controller.refreshPower()
        waitUntil { controller.mode == .whileWorking }
        XCTAssertEqual(controller.lastEndReason, .lowBattery)
        XCTAssertTrue(prefs.stayAwakeWhileWorking)
        // Auf Akku und ohne Arbeit: Ruhezustand wieder an.
        waitUntil { system.lastSet == false }

        // Bei 15 % Akku lässt sich „Immer“ nicht halten: fällt sofort zurück.
        controller.cycle()
        XCTAssertEqual(controller.mode, .whileWorking)
        system.power = (true, 15)
        controller.refreshPower()
        waitUntil { controller.conditions.onACPower }
        controller.cycle()
        XCTAssertEqual(controller.mode, .always)
        controller.cycle()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(prefs.stayAwakeWhileWorking)
    }

    /// Review Insel-Paket, Befund 7: War die Seitenleiste nie zu sehen, lief
    /// `start()` nie. Der Controller holt das nach und prüft still — ohne
    /// Dialog, und erst danach entscheidet er.
    @MainActor
    func testControllerResolvesThePermissionSilentlyWithoutTheSidebar() {
        let system = FakeStayAwakeSystem(installed: true)
        let (controller, _, working) = makeController(system)
        XCTAssertEqual(controller.permission, .unknown)
        var answered = false
        controller.whenPermissionKnown(workingPublisher: working.eraseToAnyPublisher()) {
            answered = true
            XCTAssertEqual(controller.permission, .ready)
            XCTAssertFalse(controller.nextStepNeedsPermission)
        }
        XCTAssertFalse(answered, "erst nach der Prüfung")
        waitUntil { answered }
        XCTAssertEqual(system.installCalls, 0, "nie ein Dialog")

        var again = false
        controller.whenPermissionKnown(workingPublisher: working.eraseToAnyPublisher()) { again = true }
        XCTAssertTrue(again, "bekannt: sofort")
    }

    @MainActor
    func testStaleMarkerFromCrashIsResetOnStart() throws {
        let system = FakeStayAwakeSystem(installed: true)
        let (controller, _, working) = makeController(system)
        try Data().write(to: marker)
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .ready }
        XCTAssertEqual(system.setCalls.first, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: Test-Instanz und Eingriffe von außen (WM8-122)

    /// Die Test-Instanz fasst den Ruhezustand nie an: kein sudo, kein pmset,
    /// keine Wache, kein Dialog, weder beim Start noch bei Arbeit, Klick oder
    /// Beenden. Vorher schaltete ihr erstes `evaluate()` mit `pmset -a
    /// disablesleep 0` den Ruhezustand des ganzen Macs wieder ein.
    @MainActor
    func testTestInstanceNeverTouchesSleep() {
        let system = FakeStayAwakeSystem(installed: true)
        let prefs = AppPreferences(defaults: UserDefaults(suiteName: suiteName)!)
        prefs.stayAwakeWhileWorking = true
        let controller = StayAwakeController(system: system, preferences: prefs, marker: marker, isAvailable: false)
        XCTAssertEqual(controller.mode, .off, "gemerkte Stufe gilt hier nicht")
        let working = PassthroughSubject<Bool, Never>()
        var answered = false
        controller.whenPermissionKnown(workingPublisher: working.eraseToAnyPublisher()) { answered = true }
        XCTAssertTrue(answered, "Controller bekommt sofort eine Antwort")
        working.send(true)
        controller.cycle()
        controller.setWhileWorking(true)
        controller.removePermission()
        controller.refreshPower()
        controller.evaluate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(system.setCalls.isEmpty, "nie pmset")
        XCTAssertEqual(system.permissionChecks, 0, "nie sudo")
        XCTAssertEqual(system.installCalls, 0, "nie ein Admin-Dialog")
        XCTAssertEqual(system.watchdogStarts, 0, "keine Wache")
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(controller.permission, .missing)
        XCTAssertTrue(controller.nextStepNeedsPermission, "Controller-Weg öffnet keinen Dialog")
        XCTAssertTrue(prefs.stayAwakeWhileWorking, "die Einstellung bleibt unberührt")
    }

    /// Schaltet ein anderer Prozess den Ruhezustand wieder ein, merkt die
    /// Haupt-App es beim nächsten Takt und schaltet ihn wieder aus.
    @MainActor
    func testExternalResetIsNoticedAndUndone() {
        let system = FakeStayAwakeSystem(installed: true)
        let (controller, prefs, working) = makeController(system)
        prefs.stayAwakeWhileWorking = true
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .ready }
        controller.setWhileWorking(true)
        working.send(true)
        waitUntil { controller.isHoldingAwake }
        XCTAssertEqual(system.setCalls.filter { $0 }.count, 1)

        system.resetFromOutside()
        controller.refreshPower()
        waitUntil { controller.lastExternalResetAt != nil }
        waitUntil { system.setCalls.filter { $0 }.count == 2 }
        waitUntil { controller.isHoldingAwake }
        XCTAssertEqual(system.lastSet, true)
    }

    /// Ohne Abschalten nichts nachsehen; nicht ablesbar heißt: nichts tun.
    func testOnlyAReadableResetCounts() {
        XCTAssertTrue(StayAwakePolicy.wasResetFromOutside(applied: true, actual: false))
        XCTAssertFalse(StayAwakePolicy.wasResetFromOutside(applied: true, actual: nil))
        XCTAssertFalse(StayAwakePolicy.wasResetFromOutside(applied: true, actual: true))
        XCTAssertFalse(StayAwakePolicy.wasResetFromOutside(applied: false, actual: false))
        XCTAssertFalse(StayAwakePolicy.wasResetFromOutside(applied: nil, actual: false))
    }

    @MainActor
    func testWhileNotHoldingNothingIsReadBack() {
        let system = FakeStayAwakeSystem(installed: true)
        let (controller, _, working) = makeController(system)
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .ready }
        // Das Abschalten beim Start liest einmal zurück (`apply`); erst danach zählen.
        waitUntil { system.setCalls.count == 1 && system.sleepReads == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let before = system.sleepReads
        controller.refreshPower()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(system.sleepReads, before, "kein pmset -g, solange der Mac nicht wach gehalten wird")
    }

    func testHelpNamesTheExternalReset() {
        let text = SidebarStayAwakeButton.helpText(
            mode: .whileWorking, isHolding: true, alwaysSince: nil, lastEnd: nil, externalResetAt: Date())
        let plain = SidebarStayAwakeButton.helpText(mode: .whileWorking, isHolding: true, alwaysSince: nil, lastEnd: nil)
        XCTAssertGreaterThan(text.components(separatedBy: "\n").count, plain.components(separatedBy: "\n").count)
        XCTAssertFalse(SidebarStayAwakeButton.unavailableText.isEmpty)
    }

    // MARK: Hilfen

    private var marker: URL!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        marker = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-stay-awake-\(UUID().uuidString)")
        suiteName = "stay-awake-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: marker)
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    private func makeController(_ system: FakeStayAwakeSystem) -> (StayAwakeController, AppPreferences, PassthroughSubject<Bool, Never>) {
        let prefs = AppPreferences(defaults: UserDefaults(suiteName: suiteName)!)
        let controller = StayAwakeController(system: system, preferences: prefs, marker: marker)
        return (controller, prefs, PassthroughSubject<Bool, Never>())
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "Bedingung nicht erreicht", file: file, line: line)
    }
}

private final class FakeStayAwakeSystem: StayAwakeSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _installed: Bool
    private let installSucceeds: Bool
    private var _installCalls = 0
    private var _setCalls: [Bool] = []
    private var _watchdogStarts = 0
    private var _power: (Bool, Int?) = (true, 80)
    private var _externalOverride: Bool?
    private var _permissionChecks = 0
    private var _sleepReads = 0

    init(installed: Bool, installSucceeds: Bool = true) {
        _installed = installed
        self.installSucceeds = installSucceeds
    }

    var installCalls: Int { lock.withLock { _installCalls } }
    var setCalls: [Bool] { lock.withLock { _setCalls } }
    var lastSet: Bool? { setCalls.last }
    var watchdogStarts: Int { lock.withLock { _watchdogStarts } }
    var permissionChecks: Int { lock.withLock { _permissionChecks } }
    var sleepReads: Int { lock.withLock { _sleepReads } }
    /// Ein anderer Prozess schaltet den Ruhezustand wieder ein.
    func resetFromOutside() { lock.withLock { _externalOverride = false } }
    var power: (Bool, Int?) {
        get { lock.withLock { _power } }
        set { lock.withLock { _power = newValue } }
    }

    func isPermissionInstalled() -> Bool { lock.withLock { _permissionChecks += 1; return _installed } }
    func installPermission(prompt: String) -> Bool {
        lock.withLock {
            _installCalls += 1
            if installSucceeds { _installed = true }
            return installSucceeds
        }
    }
    func removePermission(prompt: String) -> Bool { lock.withLock { _installed = false; return true } }
    func setSleepDisabled(_ disabled: Bool) -> Bool {
        lock.withLock { _setCalls.append(disabled); _externalOverride = nil; return true }
    }
    func isSleepDisabled() -> Bool? {
        lock.withLock {
            _sleepReads += 1
            return _externalOverride ?? _setCalls.last
        }
    }
    func startWatchdog(appPID: Int32, marker: URL) { lock.withLock { _watchdogStarts += 1 } }
    func powerState() -> (onACPower: Bool, batteryPercent: Int?) {
        let p = power
        return (p.0, p.1)
    }
}
