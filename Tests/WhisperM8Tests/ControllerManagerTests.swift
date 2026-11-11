import Foundation
import GameController
import XCTest
@testable import WhisperM8

/// Quelle ohne Hardware: Tests speisen Roh-Ereignisse über `onEvent` ein.
private final class FakeControllerSource: ControllerInputSource, @unchecked Sendable {
    var onEvent: (@Sendable (ControllerInputEvent) -> Void)?
    var onReset: (@Sendable () -> Void)?
    var onDeviceChange: (@MainActor (ControllerDeviceInfo?) -> Void)?

    var isStarted = false
    var backgroundAvailable = true
    var backgroundRequests: [Bool] = []
    var lights: [ControllerLightColor] = []
    var haptics: [ControllerHapticPattern] = []

    func start(queue: DispatchQueue) { isStarted = true }
    func stop() { isStarted = false }
    func setBackgroundMonitoring(_ enabled: Bool) -> Bool {
        backgroundRequests.append(enabled)
        return enabled && backgroundAvailable
    }
    func setLight(_ color: ControllerLightColor?) { if let color { lights.append(color) } }
    func play(_ pattern: ControllerHapticPattern) { haptics.append(pattern) }
}

@MainActor
private final class SpyPerformer: ControllerActionPerforming {
    var current = ControllerAppSnapshot(chat: ControllerChatState(status: .idle, profile: .claude))
    private(set) var performed: [ControllerAction] = []

    func snapshot() -> ControllerAppSnapshot { current }
    func perform(_ action: ControllerAction, in context: ControllerContext) { performed.append(action) }
}

/// Manager der Controller-Steuerung: Ein/Aus über die Schalter, Auflösen und
/// Ausführen von Gesten, Trockenlauf, Pause und Hintergrund-Zustand.
@MainActor
final class ControllerManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var source: FakeControllerSource!
    private var performer: SpyPerformer!
    private var manager: ControllerManager!

    private static let device = ControllerDeviceInfo(
        name: "DualSense Wireless Controller", category: "DualSense",
        batteryLevel: nil, hasLight: true, hasHaptics: true)

    override func setUp() async throws {
        suiteName = "controller-manager-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        source = FakeControllerSource()
        performer = SpyPerformer()
        let defaults = defaults!
        manager = ControllerManager(source: source, preferences: { AppPreferences(defaults: defaults) })
        manager.performer = performer
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func enable(background: Bool = false) {
        defaults.set(true, forKey: PreferenceKeys.controllerEnabled)
        defaults.set(background, forKey: PreferenceKeys.controllerBackgroundEnabled)
        manager.applyPreferences()
    }

    /// Schickt Roh-Ereignisse durch die Kette und wartet, bis `count`
    /// Auflösungen auf dem Main Thread angekommen sind.
    private func send(_ events: [ControllerInputEvent], expecting count: Int) async -> [ControllerResolution] {
        manager.clearRecentResolutions()
        let done = expectation(description: "Gesten aufgelöst")
        var seen = 0
        manager.onResolution = { _ in
            seen += 1
            if seen == count { done.fulfill() }
        }
        events.forEach { source.onEvent?($0) }
        await fulfillment(of: [done], timeout: 2)
        manager.onResolution = nil
        return manager.recentResolutions
    }

    // MARK: - Ein und Aus

    func testDoesNotStartWhileSwitchIsOff() {
        manager.applyPreferences()
        XCTAssertFalse(source.isStarted)
        XCTAssertFalse(manager.status.isRunning)
    }

    func testStartsAndStopsWithUserSwitch() {
        enable()
        XCTAssertTrue(source.isStarted)
        XCTAssertTrue(manager.status.isRunning)

        defaults.set(false, forKey: PreferenceKeys.controllerEnabled)
        manager.applyPreferences()
        XCTAssertFalse(source.isStarted)
        XCTAssertFalse(manager.status.isRunning)
    }

    /// Die Notbremse gewinnt gegen den Nutzer-Schalter.
    func testKillSwitchKeepsItOff() {
        defaults.set(false, forKey: PreferenceKeys.controllerFeatureEnabled)
        enable()
        XCTAssertFalse(source.isStarted)
    }

    // MARK: - Gesten

    func testPressResolvesAndExecutes() async {
        enable()
        let resolutions = await send([.button(.cross, pressed: true)], expecting: 1)
        XCTAssertEqual(resolutions.first?.action, .chatKey(.enter))
        XCTAssertEqual(resolutions.first?.executed, true)
        XCTAssertEqual(performer.performed, [.chatKey(.enter)])
        XCTAssertEqual(manager.status.lastButton, .cross)
    }

    func testDryRunResolvesWithoutExecuting() async {
        enable()
        manager.isDryRun = true
        let resolutions = await send([.button(.triangle, pressed: true)], expecting: 1)
        XCTAssertEqual(resolutions.first?.action, .nextWaitingChat)
        XCTAssertEqual(resolutions.first?.executed, false)
        XCTAssertEqual(performer.performed, [])
    }

    /// R2 löst erst ab halbem Hub aus — ein aufliegender Finger nicht.
    func testTriggerNeedsHalfTravel() async {
        enable()
        source.onEvent?(.trigger(.r2, value: 0.02))
        let resolutions = await send([.trigger(.r2, value: 0.8)], expecting: 1)
        XCTAssertEqual(resolutions.map(\.action), [.dictationToggle])
    }

    func testPausedIgnoresEverythingButTheChord() async {
        enable()
        manager.togglePause()
        XCTAssertTrue(manager.status.isPaused)
        let resolutions = await send([.button(.cross, pressed: true)], expecting: 1)
        XCTAssertEqual(resolutions.first?.context, .paused)
        XCTAssertNil(resolutions.first?.action)
        XCTAssertEqual(performer.performed, [])
    }

    func testSystemPauseAndUserPauseAreIndependent() {
        enable()
        manager.setSystemPaused(true)
        XCTAssertTrue(manager.isPaused)
        manager.togglePause()
        manager.setSystemPaused(false)
        XCTAssertTrue(manager.isPaused, "Die Pause des Nutzers bleibt, wenn das System freigibt")
        manager.togglePause()
        XCTAssertFalse(manager.isPaused)
    }

    // MARK: - Hintergrund

    func testBackgroundStaysOffWithoutSwitch() {
        enable(background: false)
        source.onDeviceChange?(Self.device)
        XCTAssertEqual(manager.status.background, .off)
        XCTAssertEqual(source.backgroundRequests.last, false)
    }

    func testBackgroundWaitsUntilFirstEventArrives() {
        enable(background: true)
        XCTAssertTrue(source.backgroundRequests.isEmpty, "Erst nach dem ersten Verbinden setzen")
        source.onDeviceChange?(Self.device)
        XCTAssertEqual(source.backgroundRequests.last, true)
        XCTAssertEqual(manager.status.background, .waiting)
    }

    /// Das System behält den Schalter nicht (wie unter macOS 15.4).
    func testBackgroundUnavailableWhenSystemRefuses() {
        source.backgroundAvailable = false
        enable(background: true)
        source.onDeviceChange?(Self.device)
        XCTAssertEqual(manager.status.background, .unavailable)
    }

    func testBackgroundBecomesReceivedAfterInactiveEvent() async {
        enable(background: true)
        source.onDeviceChange?(Self.device)
        manager.counters.setAppActive(false)
        _ = await send([.button(.triangle, pressed: true)], expecting: 1)
        XCTAssertEqual(manager.status.background, .received)
        XCTAssertEqual(manager.counters.snapshot.counts[.triangle]?.downInactive, 1)
    }

    // MARK: - Debug-Kanal

    /// Ein Trockenlauf führt auch nachlaufende Gesten nicht aus, und ein
    /// zweiter Lauf wartet nicht still, sondern wird abgewiesen.
    func testDebugRunIsDryUntilDrainedAndExclusive() async {
        enable()
        var secondRan: Bool?
        let ran = await manager.runDebug(dryRun: true, override: ControllerDebugOverride()) {
            manager.inject(.button(.circle, pressed: true))
            try? await Task.sleep(for: .milliseconds(500))
            secondRan = await manager.runDebug(dryRun: false, override: ControllerDebugOverride()) {}
            manager.inject(.button(.circle, pressed: false))
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(secondRan, false)
        XCTAssertEqual(performer.performed, [], "nichts ausgeführt")
        XCTAssertFalse(manager.isDryRun, "danach wieder echt")
        XCTAssertFalse(manager.recentResolutions.isEmpty, "aufgelöst wurde trotzdem")
    }

    // MARK: - Rückmeldung am Gerät

    func testFeedbackRespectsSwitchesAndPause() {
        enable()
        manager.play(.rejected)
        manager.setLight(ControllerLightColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(source.haptics, [.rejected])
        XCTAssertEqual(source.lights.count, 1)

        defaults.set(false, forKey: PreferenceKeys.controllerHapticsEnabled)
        defaults.set(false, forKey: PreferenceKeys.controllerLightEnabled)
        manager.play(.rejected)
        manager.setLight(ControllerLightColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(source.haptics.count, 1)
        XCTAssertEqual(source.lights.count, 1)

        defaults.set(true, forKey: PreferenceKeys.controllerHapticsEnabled)
        manager.togglePause()
        manager.play(.rejected)
        XCTAssertEqual(source.haptics.count, 1, "In der Pause schweigt der Controller")
    }
}

/// Verdrahtung des GameController-Frameworks, geprüft an einem virtuellen
/// Controller: `setValue` löst die echten Handler auf der eigenen Queue aus.
final class GameControllerInputSourceTests: XCTestCase {
    func testVirtualGamepadDeliversMappedEvents() throws {
        let virtual = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(virtual.extendedGamepad)
        let source = GameControllerInputSource()
        let queue = DispatchQueue(label: "controller-source-test")

        let lock = NSLock()
        var events: [ControllerInputEvent] = []
        let received = expectation(description: "Ereignisse")
        received.expectedFulfillmentCount = 4
        source.onEvent = { event in
            lock.lock(); events.append(event); lock.unlock()
            received.fulfill()
        }
        source.start(queue: queue)
        defer { source.stop() }
        // Der virtuelle Controller taucht nicht in `controllers()` auf — von Hand verdrahten.
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: virtual)

        pad.buttonA.setValue(1)
        pad.rightTrigger.setValue(0.75)
        pad.dpad.up.setValue(1)
        pad.buttonOptions?.setValue(1)

        wait(for: [received], timeout: 2)
        lock.lock(); let seen = events; lock.unlock()
        XCTAssertTrue(seen.contains(.button(.cross, pressed: true)))
        XCTAssertTrue(seen.contains(.trigger(.r2, value: 0.75)))
        XCTAssertTrue(seen.contains(.button(.dpadUp, pressed: true)))
        XCTAssertTrue(seen.contains(.button(.create, pressed: true)), "Create ist die „Options“-Taste des Frameworks")
    }

    func testHapticPatternsAreShortAndNeverEmpty() {
        for pattern in ControllerHapticPattern.allCases {
            let events = GameControllerInputSource.events(for: pattern)
            XCTAssertFalse(events.isEmpty)
            let end = events.map { $0.relativeTime + $0.duration }.max() ?? 0
            XCTAssertLessThan(end, 0.4, "\(pattern) dauert zu lang")
        }
    }
}
