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
        XCTAssertEqual(KeyboardLockPolicy.extendedDuration(allowed: 120, elapsed: 30), 180)
        // Abgelaufene Zeit über der Frist (Tick verpasst): ab jetzt eine Minute.
        XCTAssertEqual(KeyboardLockPolicy.extendedDuration(allowed: 120, elapsed: 130), 190)
        XCTAssertEqual(KeyboardLockPolicy.extendedDuration(allowed: 570, elapsed: 0), 600)
        XCTAssertTrue(KeyboardLockPolicy.canExtend(allowed: 570))
        XCTAssertFalse(KeyboardLockPolicy.canExtend(allowed: 600))
    }

    func testTapDeliversEventUnlessSwallowed() {
        XCTAssertTrue(LiveKeyboardEventTap.delivers(.pass))
        XCTAssertTrue(LiveKeyboardEventTap.delivers(.reenableTap))
        XCTAssertFalse(LiveKeyboardEventTap.delivers(.swallow))
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
    private var uptime: TimeInterval = 500
    private var secureInput = false
    private var screenLocked = false
    private let workspaceCenter = NotificationCenter()
    private let distributedCenter = NotificationCenter()
    private let appCenter = NotificationCenter()

    private func makeController(tap: FakeTap, panel: FakePanel, keysDown: Set<Int64> = []) -> KeyboardLockController {
        let sources = KeyboardLockController.NotificationSources(
            workspace: workspaceCenter, distributed: distributedCenter, app: appCenter
        )
        return KeyboardLockController(
            tap: tap,
            panel: panel,
            now: { [unowned self] in self.clock },
            uptime: { [unowned self] in self.uptime },
            secureInputProbe: { [unowned self] in self.secureInput },
            capsLockProbe: { false },
            keysDownProbe: { keysDown },
            screenLockedProbe: { [unowned self] in self.screenLocked },
            notificationSources: { sources }
        )
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        uptime += seconds
    }

    private func assertFullyUnlocked(
        _ controller: KeyboardLockController, tap: FakeTap, panel: FakePanel,
        reason: KeyboardUnlockReason, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(controller.isLocked, file: file, line: line)
        XCTAssertEqual(tap.uninstalls, 1, file: file, line: line)
        XCTAssertEqual(panel.hidden, 1, file: file, line: line)
        XCTAssertEqual(controller.lastUnlockReason, reason, file: file, line: line)
        XCTAssertNil(controller.deadline, file: file, line: line)
    }

    func testLockInstallsTapShowsPanelAndSwallowsKeys() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)

        XCTAssertEqual(controller.lock(), .locked)
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.deadline, clock.addingTimeInterval(120))
        XCTAssertEqual(controller.remaining, 120)
        XCTAssertTrue(controller.canExtend)
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

        assertFullyUnlocked(controller, tap: tap, panel: panel, reason: .user)
        // Doppeltes Entsperren bleibt folgenlos.
        controller.unlock(reason: .timeout)
        XCTAssertEqual(tap.uninstalls, 1)
        XCTAssertEqual(controller.lastUnlockReason, .user)
    }

    func testTickUnlocksAfterDeadline() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        advance(119)
        controller.tick()
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(tap.uninstalls, 0)

        advance(1)
        controller.tick()
        assertFullyUnlocked(controller, tap: tap, panel: panel, reason: .timeout)
    }

    func testDeadlineFollowsUptimeNotWallClock() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        // Wanduhr springt eine Stunde vor, Uptime nur 10 s.
        clock = clock.addingTimeInterval(3_600)
        uptime += 10
        controller.tick()
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(controller.remaining, 110)
        // Anzeige folgt der neuen Wanduhr.
        XCTAssertEqual(controller.deadline, clock.addingTimeInterval(110))

        // Wanduhr springt zurück: die Frist läuft trotzdem nach Uptime ab.
        clock = clock.addingTimeInterval(-7_200)
        uptime += 110
        controller.tick()
        assertFullyUnlocked(controller, tap: tap, panel: panel, reason: .timeout)
    }

    func testExtendPushesDeadlineUpToCap() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        controller.extend()
        XCTAssertEqual(controller.remaining, 180)
        advance(150)
        controller.tick()
        XCTAssertTrue(controller.isLocked)

        for _ in 0..<20 { controller.extend() }
        XCTAssertEqual(controller.remaining, 600 - 150)
        XCTAssertFalse(controller.canExtend)
    }

    func testTickUnlocksWhenScreenIsLockedWithoutNotification() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        screenLocked = true
        controller.tick()

        assertFullyUnlocked(controller, tap: tap, panel: panel, reason: .screenLocked)
    }

    func testEachSystemSignalUnlocks() {
        let cases: [(KeyPath<KeyboardLockControllerTests, NotificationCenter>, Notification.Name, KeyboardUnlockReason)] = [
            (\.workspaceCenter, NSWorkspace.willSleepNotification, .systemSleep),
            (\.workspaceCenter, NSWorkspace.screensDidSleepNotification, .screensSlept),
            (\.workspaceCenter, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (\.distributedCenter, KeyboardLockController.screenLockedNotification, .screenLocked),
            (\.appCenter, NSApplication.willTerminateNotification, .appTerminating),
        ]
        for (centerPath, name, reason) in cases {
            let tap = FakeTap(), panel = FakePanel()
            let controller = makeController(tap: tap, panel: panel)
            controller.lock()

            self[keyPath: centerPath].post(name: name, object: nil)

            assertFullyUnlocked(controller, tap: tap, panel: panel, reason: reason)
        }
    }

    func testSignalsAreIgnoredAfterUnlock() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()
        controller.unlock(reason: .user)

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertEqual(controller.lastUnlockReason, .user)
        XCTAssertEqual(tap.uninstalls, 1)
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

    func testDisabledTapIsReenabledWhileLockedAndPassesOnceUnlocked() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()
        let handler = tap.handler

        XCTAssertEqual(handler?(.tapDisabled, []), .reenableTap)
        controller.unlock(reason: .user)
        XCTAssertEqual(handler?(.tapDisabled, []), .pass)
        XCTAssertEqual(handler?(.keyDown(keyCode: 0), []), .pass)
    }
}
