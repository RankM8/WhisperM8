import Foundation
import XCTest
@testable import WhisperM8

/// HID-Leser des Xbox-Controllers ohne Hardware (Plan
/// `controller-xbox-paddles.md`, Schritt 6): Bündeln der Berichte, Tabellen,
/// Debug-Schritt `hid:` und die Anbindung an den Manager.
final class XboxHIDReportBuilderTests: XCTestCase {
    private var builder = XboxHIDReportBuilder()

    override func setUp() {
        super.setUp()
        builder = XboxHIDReportBuilder()
    }

    func testValuesWithTheSameTimestampFormOneReport() {
        XCTAssertNil(builder.add(page: XboxHID.pageConsumer, usage: XboxHID.usagePaddles, value: 4, timestamp: 10))
        XCTAssertNil(builder.add(page: XboxHID.pageButton, usage: 0x01, value: 1, timestamp: 10))
        let report = builder.flush()
        XCTAssertEqual(report?.paddleMask, 4)
        XCTAssertEqual(report?.buttons, [.init(button: .cross, pressed: true)])
    }

    func testANewTimestampFinishesThePreviousReport() {
        _ = builder.add(page: XboxHID.pageButton, usage: 0x02, value: 1, timestamp: 1)
        let finished = builder.add(page: XboxHID.pageButton, usage: 0x02, value: 0, timestamp: 2)
        XCTAssertEqual(finished?.buttons, [.init(button: .circle, pressed: true)])
        XCTAssertEqual(builder.flush()?.buttons, [.init(button: .circle, pressed: false)])
    }

    func testUnchangedAndUnknownValuesAreDropped() {
        _ = builder.add(page: XboxHID.pageButton, usage: 0x05, value: 1, timestamp: 1)
        _ = builder.flush()
        XCTAssertNil(builder.add(page: XboxHID.pageButton, usage: 0x05, value: 1, timestamp: 2))
        XCTAssertNil(builder.add(page: XboxHID.pageButton, usage: 0x1F, value: 1, timestamp: 2))
        XCTAssertNil(builder.flush(), "kein Wechsel, unbekannte Usage")
    }

    func testHomeButton() {
        _ = builder.add(page: XboxHID.pageButton, usage: XboxHIDButtons.homeUsage, value: 1, timestamp: 1)
        XCTAssertEqual(builder.flush()?.homeButton, true)
    }

    func testMeasuredFaceButtonUsages() {
        XCTAssertEqual(XboxHIDButtons.table[0x01], .cross)
        XCTAssertEqual(XboxHIDButtons.table[0x02], .circle)
        XCTAssertEqual(XboxHIDButtons.table[0x04], .square)
        XCTAssertEqual(XboxHIDButtons.table[0x05], .triangle)
        XCTAssertNil(XboxHIDButtons.table[XboxHIDButtons.homeUsage], "Xbox-Knopf läuft getrennt")
        XCTAssertFalse(XboxHIDButtons.table.values.contains { $0.isPaddle || $0.isTrigger })
    }

    /// Nur Gamepad-Usages, nie Tastatur (6) oder Maus (2).
    func testMatchingOnlyGamepads() {
        XCTAssertEqual(Set(XboxHID.gamepadUsages), [0x04, 0x05, 0x08])
    }

    /// Elite über Bluetooth LE (gemessen): GamePad, Pointer, Consumer und
    /// Tastatur. Mit Tastatur-Paar nur bei erteilter Eingabeüberwachung öffnen.
    func testKeyboardPairNeedsListenAccess() {
        let elite: [(page: UInt32, usage: UInt32)] = [(0x01, 0x05), (0x01, 0x01), (0x0C, 0x01), (0x01, 0x06)]
        XCTAssertFalse(XboxHID.mayOpen(usagePairs: elite, listenAccessGranted: false))
        XCTAssertTrue(XboxHID.mayOpen(usagePairs: elite, listenAccessGranted: true))
        XCTAssertFalse(XboxHID.mayOpen(usagePairs: [(0x01, 0x05), (0x01, 0x07)], listenAccessGranted: false), "Ziffernblock")
        XCTAssertTrue(XboxHID.mayOpen(usagePairs: [(0x01, 0x05), (0x0C, 0x01)], listenAccessGranted: false))
        XCTAssertTrue(XboxHID.mayOpen(usagePairs: [], listenAccessGranted: false))
    }

    func testMeasuredShoulderAndMenuUsages() {
        XCTAssertEqual(XboxHIDButtons.table[0x07], .l1)
        XCTAssertEqual(XboxHIDButtons.table[0x08], .r1)
        XCTAssertEqual(XboxHIDButtons.table[0x0B], .create)
        XCTAssertEqual(XboxHIDButtons.table[0x0C], .options)
        XCTAssertEqual(XboxHIDButtons.table[0x0E], .l3)
        XCTAssertEqual(XboxHIDButtons.table[0x0F], .r3)
    }

    // MARK: - Debug-Schritt

    func testDebugScriptHIDStep() throws {
        let steps = try ControllerDebugScript.parse("hid:4+cross,down:cross,up:cross,hid:0-cross")
        XCTAssertEqual(steps.first, .hid(ControllerHIDReport(paddleMask: 4, buttons: [.init(button: .cross, pressed: true)])))
        XCTAssertEqual(steps.last, .hid(ControllerHIDReport(paddleMask: 0, buttons: [.init(button: .cross, pressed: false)])))
        XCTAssertEqual(ControllerDebugScript.parseHID("+home"), ControllerHIDReport(homeButton: true))
        XCTAssertNil(ControllerDebugScript.parseHID("99"))
        XCTAssertNil(ControllerDebugScript.parseHID("4+banana"))
        XCTAssertThrowsError(try ControllerDebugScript.parse("hid:4"), "Maske muss am Ende wieder 0 sein")
        XCTAssertThrowsError(try ControllerDebugScript.parse("hid:+home"), "Xbox-Knopf muss losgelassen werden")
    }
}

/// HID-Quelle ohne Hardware.
private final class FakeHIDSource: ControllerHIDSourcing, @unchecked Sendable {
    var onReport: (@Sendable (ControllerHIDReport) -> Void)?
    var onPaddlesAvailable: (@Sendable (Bool) -> Void)?
    var onStateChange: (@MainActor (ControllerPaddleSupport) -> Void)?
    var started = 0
    var stopped = 0
    func start(queue: DispatchQueue) { started += 1 }
    func stop() { stopped += 1 }
}

private final class SilentSource: ControllerInputSource, @unchecked Sendable {
    var onEvent: (@Sendable (ControllerInputEvent, ControllerFamily) -> Void)?
    var onReset: (@Sendable () -> Void)?
    var onDeviceChange: (@MainActor (ControllerDeviceInfo?) -> Void)?
    func start(queue: DispatchQueue) {}
    func stop() {}
    func setBackgroundMonitoring(_ enabled: Bool) -> Bool { enabled }
    func setLight(_ color: ControllerLightColor?) {}
    func play(_ pattern: ControllerHapticPattern) {}
}

@MainActor
final class ControllerManagerHIDTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "controller-hid-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(true, forKey: PreferenceKeys.controllerEnabled)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeManager(_ hid: FakeHIDSource) -> ControllerManager {
        let defaults = defaults!
        return ControllerManager(source: SilentSource(), hidSource: hid, preferences: { AppPreferences(defaults: defaults) })
    }

    func testHIDRunsWithTheControllerAndReportsItsState() async {
        let hid = FakeHIDSource()
        let manager = makeManager(hid)
        manager.applyPreferences()
        XCTAssertEqual(hid.started, 1)
        hid.onStateChange?(.readable)
        XCTAssertEqual(manager.status.paddles, .readable)
        defaults.set(false, forKey: PreferenceKeys.controllerEnabled)
        manager.applyPreferences()
        XCTAssertEqual(hid.stopped, 1)
        XCTAssertEqual(manager.status.paddles, ControllerPaddleSupport.none)
    }

    func testKillSwitchKeepsHIDClosed() {
        defaults.set(false, forKey: PreferenceKeys.controllerPaddleHIDEnabled)
        let hid = FakeHIDSource()
        let manager = makeManager(hid)
        manager.applyPreferences()
        XCTAssertEqual(hid.started, 0)
        XCTAssertEqual(manager.status.paddles, .disabled)
    }

    func testPaddleBindingsAreCachedAndRefreshed() {
        let manager = makeManager(FakeHIDSource())
        XCTAssertEqual(manager.paddleBindings, .standard)
        defaults.set("pause", forKey: PreferenceKeys.controllerPaddleUpperRight)
        XCTAssertEqual(manager.paddleBindings, .standard, "kein Lesen je Geste")
        manager.applyPreferences()
        XCTAssertEqual(manager.paddleBindings[.upperRight], .pause)
    }

    func testTraitsFollowTheHomeButton() {
        let status = ControllerStatus()
        status.device = ControllerDeviceInfo(name: "Xbox", category: "Xbox One", batteryLevel: nil,
                                             hasLight: false, hasHaptics: true, family: .xbox)
        XCTAssertFalse(status.traits.hasTouchpad)
        status.paddles = .noPaddles
        XCTAssertTrue(status.traits.hasTouchpad, "Xbox-Knopf öffnet den Verlauf")
        status.paddles = .notReadable(reason: "not permitted")
        XCTAssertFalse(status.traits.hasTouchpad)
        status.device = nil
        XCTAssertEqual(status.traits, .standard)
    }
}
