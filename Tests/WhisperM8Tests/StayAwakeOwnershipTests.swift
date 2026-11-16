import Combine
import Foundation
import XCTest
@testable import WhisperM8

/// Merker mit Besitzer (WM8-122): Zwei Produktiv-Apps teilen sich den Merker
/// (Neustart mit Übergabe, `make run`). Nur der Besitzer räumt auf, oder wer
/// sieht, dass der Besitzer tot ist.
final class StayAwakeOwnershipTests: XCTestCase {
    private let oldApp = StayAwakeMarker(pid: 41_111, startMicros: 1_000)
    private let newApp = StayAwakeMarker(pid: 42_222, startMicros: 2_000)
    private var marker: URL!
    private var suites: [String] = []

    override func setUp() {
        super.setUp()
        marker = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-stay-awake-owner-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: marker)
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        super.tearDown()
    }

    // MARK: Regeln

    func testMarkerRoundTripAndOldEmptyMarkers() {
        XCTAssertEqual(StayAwakeMarker.parse(newApp.fileContents), newApp)
        XCTAssertEqual(StayAwakeMarker.parse("42222\n"), StayAwakeMarker(pid: 42_222, startMicros: nil))
        XCTAssertNil(StayAwakeMarker.parse(""), "Merker älterer Fassungen waren leer")
        XCTAssertNil(StayAwakeMarker.parse("kein Merker"))
    }

    func testOnlyOwnerOrDeadOwnerMayRelease() {
        let alive: (StayAwakeMarker) -> Bool = { $0 == self.oldApp }
        XCTAssertTrue(StayAwakeMarker.mayRelease(marker: nil, markerExists: false, own: newApp, isAlive: alive))
        XCTAssertTrue(StayAwakeMarker.mayRelease(marker: nil, markerExists: true, own: newApp, isAlive: alive), "unlesbar: alter Absturz")
        XCTAssertTrue(StayAwakeMarker.mayRelease(marker: newApp, markerExists: true, own: newApp, isAlive: alive))
        XCTAssertFalse(StayAwakeMarker.mayRelease(marker: oldApp, markerExists: true, own: newApp, isAlive: alive))
        XCTAssertTrue(StayAwakeMarker.mayRelease(marker: oldApp, markerExists: true, own: newApp, isAlive: { _ in false }))
    }

    // MARK: Zwei Apps

    /// Übergabe: Die neue App hält den Mac wach, danach beendet sich die alte.
    /// Der Mac bleibt wach, der Merker der neuen bleibt stehen.
    @MainActor
    func testOldAppQuittingAfterTheNewOneTookOverKeepsTheMacAwake() {
        let system = OwnershipFakeSystem()
        system.alive = [oldApp, newApp]
        let (old, oldWorking) = makeController(system, owner: oldApp)
        holdAwake(old, oldWorking, system)
        XCTAssertEqual(markerOwner(), oldApp)

        let before = system.setCalls
        let (new, newWorking) = makeController(system, owner: newApp)
        new.start(workingPublisher: newWorking.eraseToAnyPublisher())
        waitUntil { new.permission == .ready }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(system.setCalls, before, "die neue setzt beim Start nichts zurück, solange die alte lebt")
        XCTAssertEqual(markerOwner(), oldApp)

        new.setWhileWorking(true)
        newWorking.send(true)
        waitUntil { markerOwner() == self.newApp }

        old.releaseForTermination()
        XCTAssertEqual(system.setCalls.last, true, "die alte schaltet den Ruhezustand nicht wieder ein")
        XCTAssertEqual(markerOwner(), newApp)
    }

    /// Eine zweite App ohne Test-Variable (etwa `make run`) startet, während
    /// die erste den Mac wach hält: Sie fasst nichts an.
    @MainActor
    func testSecondAppTouchesNothingWhileTheFirstLives() {
        let system = OwnershipFakeSystem()
        system.alive = [oldApp]
        try? Data(oldApp.fileContents.utf8).write(to: marker)
        let (second, working) = makeController(system, owner: newApp)
        second.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { second.permission == .ready }
        second.evaluate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(system.setCalls.isEmpty, "kein disablesleep 0")
        XCTAssertEqual(markerOwner(), oldApp)
        XCTAssertFalse(second.isHoldingAwake)
    }

    /// Ist der Besitzer tot, räumt der Start wie bisher auf.
    @MainActor
    func testDeadOwnersMarkerIsResetOnStart() {
        let system = OwnershipFakeSystem()
        try? Data(oldApp.fileContents.utf8).write(to: marker)
        let (controller, working) = makeController(system, owner: newApp)
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .ready }
        waitUntil { !FileManager.default.fileExists(atPath: self.marker.path) }
        XCTAssertEqual(system.setCalls.first, false)
    }

    // MARK: Wache

    /// Das echte Skript, nur mit harmlosem Befehl statt `sudo pmset`: Es
    /// setzt zurück, wenn im Merker noch seine App steht, sonst nicht.
    func testWatchdogOnlyResetsItsOwnMarker() throws {
        let deadPID = try finishedProcessPID()
        let resetFile = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: resetFile) }
        let script = SleepDisablePermission.watchdogScript(resetCommand: "/usr/bin/touch \"\(resetFile.path)\"")

        // Marker gehört inzwischen einer anderen App.
        try Data(newApp.fileContents.utf8).write(to: marker)
        try runWatchdog(script, appPID: deadPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resetFile.path), "fremder Besitzer: nichts zurücksetzen")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Marker der eigenen App.
        try Data("\(deadPID)\n".utf8).write(to: marker)
        try runWatchdog(script, appPID: deadPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resetFile.path), "eigener Merker: zurücksetzen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: Hilfen

    @MainActor
    private func makeController(_ system: OwnershipFakeSystem, owner: StayAwakeMarker)
        -> (StayAwakeController, PassthroughSubject<Bool, Never>) {
        let suite = "stay-awake-owner-\(UUID().uuidString)"
        suites.append(suite)
        let prefs = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
        let controller = StayAwakeController(system: system, preferences: prefs, marker: marker,
                                             isAvailable: true, owner: owner)
        return (controller, PassthroughSubject<Bool, Never>())
    }

    @MainActor
    private func holdAwake(_ controller: StayAwakeController, _ working: PassthroughSubject<Bool, Never>,
                           _ system: OwnershipFakeSystem) {
        controller.start(workingPublisher: working.eraseToAnyPublisher())
        waitUntil { controller.permission == .ready }
        controller.setWhileWorking(true)
        working.send(true)
        waitUntil { system.setCalls.last == true && controller.isHoldingAwake }
    }

    private func markerOwner() -> StayAwakeMarker? {
        (try? String(contentsOf: marker, encoding: .utf8)).flatMap(StayAwakeMarker.parse)
    }

    private func finishedProcessPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func runWatchdog(_ script: String, appPID: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "whisperm8-wach", String(appPID), marker.path]
        try process.run()
        process.waitUntilExit()
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "Bedingung nicht erreicht", file: file, line: line)
    }
}

/// System ohne echte Aufrufe; ein Rechner, zwei Apps.
private final class OwnershipFakeSystem: StayAwakeSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _setCalls: [Bool] = []
    private var _alive: [StayAwakeMarker] = []

    var setCalls: [Bool] { lock.withLock { _setCalls } }
    var alive: [StayAwakeMarker] {
        get { lock.withLock { _alive } }
        set { lock.withLock { _alive = newValue } }
    }

    func isPermissionInstalled() -> Bool { true }
    func installPermission(prompt: String) -> Bool { true }
    func removePermission(prompt: String) -> Bool { true }
    func setSleepDisabled(_ disabled: Bool) -> Bool { lock.withLock { _setCalls.append(disabled); return true } }
    func isSleepDisabled() -> Bool? { lock.withLock { _setCalls.last } }
    func startWatchdog(appPID: Int32, marker: URL) {}
    func powerState() -> (onACPower: Bool, batteryPercent: Int?) { (true, 80) }
    func isAlive(_ owner: StayAwakeMarker) -> Bool { lock.withLock { _alive.contains(owner) } }
}
