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

    init(installed: Bool, installSucceeds: Bool = true) {
        _installed = installed
        self.installSucceeds = installSucceeds
    }

    var installCalls: Int { lock.withLock { _installCalls } }
    var setCalls: [Bool] { lock.withLock { _setCalls } }
    var lastSet: Bool? { setCalls.last }
    var watchdogStarts: Int { lock.withLock { _watchdogStarts } }
    var power: (Bool, Int?) {
        get { lock.withLock { _power } }
        set { lock.withLock { _power = newValue } }
    }

    func isPermissionInstalled() -> Bool { lock.withLock { _installed } }
    func installPermission(prompt: String) -> Bool {
        lock.withLock {
            _installCalls += 1
            if installSucceeds { _installed = true }
            return installSucceeds
        }
    }
    func removePermission(prompt: String) -> Bool { lock.withLock { _installed = false; return true } }
    func setSleepDisabled(_ disabled: Bool) -> Bool { lock.withLock { _setCalls.append(disabled); return true } }
    func isSleepDisabled() -> Bool? { lastSet }
    func startWatchdog(appPID: Int32, marker: URL) { lock.withLock { _watchdogStarts += 1 } }
    func powerState() -> (onACPower: Bool, batteryPercent: Int?) {
        let p = power
        return (p.0, p.1)
    }
}
