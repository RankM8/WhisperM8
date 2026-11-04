import CoreGraphics
import XCTest
@testable import WhisperM8

final class KeyboardLockPolicyTests: XCTestCase {
    func testKeyDownIsAlwaysSwallowed() {
        var policy = KeyboardLockPolicy()
        XCTAssertEqual(policy.decide(.keyDown(keyCode: 0)), .swallow)
        XCTAssertEqual(policy.decide(.keyDown(keyCode: 53)), .swallow)
    }

    func testKeyUpOfKeyPressedDuringLockIsSwallowed() {
        var policy = KeyboardLockPolicy()
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12)), .swallow)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55)), .swallow)
    }

    func testReleaseOfKeyHeldBeforeLockPassesExactlyOnce() {
        var policy = KeyboardLockPolicy(keysDownAtLock: [12, 55])
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12)), .pass)
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12)), .swallow)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55)), .pass)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55)), .swallow)
        XCTAssertTrue(policy.keysDownAtLock.isEmpty)
    }

    func testOnlyMediaKeySystemEventsAreSwallowed() {
        var policy = KeyboardLockPolicy()
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 8)), .swallow)
        // Untertyp 7 sind Maustasten — die müssen durch.
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 7)), .pass)
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 0)), .pass)
    }

    func testDisabledTapIsReenabledAndOtherEventsPass() {
        var policy = KeyboardLockPolicy()
        XCTAssertEqual(policy.decide(.tapDisabled), .reenableTap)
        XCTAssertEqual(policy.decide(.other), .pass)
    }

    func testExtensionAddsOneMinuteAndIsCappedAtTenMinutes() {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = start.addingTimeInterval(120)
        XCTAssertEqual(
            KeyboardLockPolicy.extendedDeadline(current: deadline, lockedAt: start, now: start.addingTimeInterval(30)),
            start.addingTimeInterval(180)
        )
        let nearCap = start.addingTimeInterval(570)
        XCTAssertEqual(
            KeyboardLockPolicy.extendedDeadline(current: nearCap, lockedAt: start, now: start),
            start.addingTimeInterval(600)
        )
        XCTAssertTrue(KeyboardLockPolicy.canExtend(current: nearCap, lockedAt: start))
        XCTAssertFalse(KeyboardLockPolicy.canExtend(current: start.addingTimeInterval(600), lockedAt: start))
    }
}

@MainActor
final class KeyboardLockControllerTests: XCTestCase {
    private final class FakeTap: KeyboardEventTapping {
        var allowInstall = true
        var installs = 0
        var uninstalls = 0
        var reenables = 0
        var handler: (@MainActor (KeyboardLockPolicy.Event, CGEventFlags) -> KeyboardLockPolicy.Decision)?

        func install(handler: @escaping @MainActor (KeyboardLockPolicy.Event, CGEventFlags) -> KeyboardLockPolicy.Decision) -> Bool {
            guard allowInstall else { return false }
            installs += 1
            self.handler = handler
            return true
        }

        func reenable() { reenables += 1 }

        func uninstall() {
            uninstalls += 1
            handler = nil
        }
    }

    private final class FakePanel: KeyboardLockPanelPresenting {
        var shown = 0
        var hidden = 0
        func show(controller: KeyboardLockController) { shown += 1 }
        func hide() { hidden += 1 }
    }

    private var clock = Date(timeIntervalSince1970: 10_000)
    private var secureInput = false

    private func makeController(tap: FakeTap, panel: FakePanel, keysDown: Set<Int64> = []) -> KeyboardLockController {
        KeyboardLockController(
            tap: tap,
            panel: panel,
            now: { [unowned self] in self.clock },
            secureInputProbe: { [unowned self] in self.secureInput },
            capsLockProbe: { false },
            keysDownProbe: { keysDown }
        )
    }

    func testLockInstallsTapShowsPanelAndSwallowsKeys() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)

        XCTAssertEqual(controller.lock(), .locked)
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.deadline, clock.addingTimeInterval(120))
        XCTAssertEqual(panel.shown, 1)
        XCTAssertEqual(tap.handler?(.keyDown(keyCode: 0), []), .swallow)
        XCTAssertEqual(controller.lock(), .alreadyLocked)
        XCTAssertEqual(tap.installs, 1)
    }

    func testMissingPermissionLeavesKeyboardUnlocked() {
        let tap = FakeTap(), panel = FakePanel()
        tap.allowInstall = false
        let controller = makeController(tap: tap, panel: panel)

        XCTAssertEqual(controller.lock(), .missingPermission)
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(panel.shown, 0)
    }

    func testUserUnlockRemovesTapAndHidesPanel() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        controller.unlock(reason: .user)

        XCTAssertFalse(controller.isLocked)
        XCTAssertNil(controller.deadline)
        XCTAssertEqual(tap.uninstalls, 1)
        XCTAssertEqual(panel.hidden, 1)
        XCTAssertEqual(controller.lastUnlockReason, .user)
        // Doppeltes Entsperren bleibt folgenlos.
        controller.unlock(reason: .timeout)
        XCTAssertEqual(tap.uninstalls, 1)
        XCTAssertEqual(controller.lastUnlockReason, .user)
    }

    func testTickUnlocksAfterDeadline() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        clock = clock.addingTimeInterval(119)
        controller.tick()
        XCTAssertTrue(controller.isLocked)

        clock = clock.addingTimeInterval(1)
        controller.tick()
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(controller.lastUnlockReason, .timeout)
    }

    func testExtendPushesDeadline() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        let start = clock
        controller.lock()

        controller.extend()

        XCTAssertEqual(controller.deadline, start.addingTimeInterval(180))
        clock = start.addingTimeInterval(150)
        controller.tick()
        XCTAssertTrue(controller.isLocked)
    }

    func testTickTracksSecureInput() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()
        XCTAssertFalse(controller.secureInputActive)

        secureInput = true
        controller.tick()

        XCTAssertTrue(controller.secureInputActive)
    }

    func testCapsLockStateFollowsFlagsChanged() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        XCTAssertEqual(tap.handler?(.flagsChanged(keyCode: 57), .maskAlphaShift), .swallow)
        XCTAssertTrue(controller.capsLockOn)
        _ = tap.handler?(.flagsChanged(keyCode: 57), [])
        XCTAssertFalse(controller.capsLockOn)
    }

    func testKeysHeldAtLockAreReleasedNormally() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel, keysDown: [58])
        controller.lock()

        XCTAssertEqual(tap.handler?(.flagsChanged(keyCode: 58), []), .pass)
        XCTAssertEqual(tap.handler?(.flagsChanged(keyCode: 58), []), .swallow)
    }

    func testHandlerPassesEverythingOnceUnlocked() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()
        let handler = tap.handler
        controller.unlock(reason: .user)

        XCTAssertEqual(handler?(.keyDown(keyCode: 0), []), .pass)
    }
}
