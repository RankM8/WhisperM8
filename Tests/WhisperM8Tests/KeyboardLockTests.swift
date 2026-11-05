import CoreGraphics
import XCTest
@testable import WhisperM8

final class KeyboardLockPolicyTests: XCTestCase {
    /// Uptime des Sperrbeginns; das Lebenszeichen ist dann frisch.
    private let start: TimeInterval = 1_000

    func testKeyDownIsAlwaysSwallowed() {
        var policy = KeyboardLockPolicy(startedAt: start)
        XCTAssertEqual(policy.decide(.keyDown(keyCode: 0), at: start), .swallow)
        XCTAssertEqual(policy.decide(.keyDown(keyCode: 53), at: start), .swallow)
    }

    func testKeyUpOfKeyPressedDuringLockIsSwallowed() {
        var policy = KeyboardLockPolicy(startedAt: start)
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12), at: start), .swallow)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55), at: start), .swallow)
    }

    func testReleaseOfKeyHeldBeforeLockPassesExactlyOnce() {
        var policy = KeyboardLockPolicy(keysDownAtLock: [12, 55], startedAt: start)
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12), at: start), .pass)
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12), at: start), .swallow)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55), at: start), .pass)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55), at: start), .swallow)
        XCTAssertTrue(policy.releasesToPass.isEmpty)
    }

    /// K3: Die Feststelltaste zählt nie als „beim Sperren gehalten“ — sonst
    /// ginge ihr erstes Drücken während der Sperre durch.
    func testCapsLockIsNeverTreatedAsHeldAtLock() {
        var policy = KeyboardLockPolicy(keysDownAtLock: [57, 12], startedAt: start)
        XCTAssertEqual(policy.releasesToPass, [12])
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 57), at: start), .swallow)
    }

    func testOnlyMediaKeySystemEventsAreSwallowed() {
        var policy = KeyboardLockPolicy(startedAt: start)
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 8), at: start), .swallow)
        // Untertyp 7 sind Maustasten — die müssen durch.
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 7), at: start), .pass)
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 0), at: start), .pass)
    }

    func testDisabledTapIsReenabledAndOtherEventsPass() {
        var policy = KeyboardLockPolicy(startedAt: start)
        XCTAssertEqual(policy.decide(.tapDisabled, at: start), .reenableTap)
        XCTAssertEqual(policy.decide(.other, at: start), .pass)
        // Auch bei ausbleibendem Lebenszeichen wieder einschalten.
        XCTAssertEqual(policy.decide(.tapDisabled, at: start + 60), .reenableTap)
    }

    // MARK: Lebenszeichen (K1)

    func testHeartbeatFreshnessBoundary() {
        var policy = KeyboardLockPolicy(startedAt: start)
        XCTAssertTrue(policy.isHeartbeatFresh(at: start + KeyboardLockPolicy.heartbeatTimeout))
        XCTAssertFalse(policy.isHeartbeatFresh(at: start + KeyboardLockPolicy.heartbeatTimeout + 0.01))
        policy.heartbeat(at: start + 4)
        XCTAssertTrue(policy.isHeartbeatFresh(at: start + 9))
        // Ein älterer Stempel setzt das Lebenszeichen nicht zurück.
        policy.heartbeat(at: start + 1)
        XCTAssertEqual(policy.lastHeartbeat, start + 4)
    }

    /// Kurzes Stocken (unter der Grenze): weiter alles gesperrt.
    func testShortStallKeepsSwallowing() {
        var policy = KeyboardLockPolicy(startedAt: start)
        XCTAssertEqual(policy.decide(.keyDown(keyCode: 36), at: start + 4.5), .swallow)
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 8), at: start + 4.5), .swallow)
    }

    /// Echter Hänger: alles geht durch, und das Loslassen einer in dieser
    /// Zeit gedrückten Taste kommt auch nach der Erholung noch durch.
    func testStaleHeartbeatPassesEverythingAndKeepsReleasesBalanced() {
        var policy = KeyboardLockPolicy(startedAt: start)
        let hung = start + 6
        XCTAssertEqual(policy.decide(.keyDown(keyCode: 13), at: hung), .pass)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55), at: hung), .pass)
        XCTAssertEqual(policy.decide(.systemDefined(subtype: 8), at: hung), .pass)

        policy.heartbeat(at: start + 7)
        let back = start + 7
        XCTAssertEqual(policy.decide(.keyDown(keyCode: 0), at: back), .swallow)
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 13), at: back), .pass)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55), at: back), .pass)
        XCTAssertEqual(policy.decide(.flagsChanged(keyCode: 55), at: back), .swallow)
        XCTAssertTrue(policy.releasesToPass.isEmpty)
    }

    func testReleaseDuringStallClearsPendingRelease() {
        var policy = KeyboardLockPolicy(keysDownAtLock: [12], startedAt: start)
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12), at: start + 10), .pass)
        policy.heartbeat(at: start + 11)
        XCTAssertEqual(policy.decide(.keyUp(keyCode: 12), at: start + 11), .swallow)
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
        var handler: KeyboardEventTapHandler?

        func install(handler: @escaping KeyboardEventTapHandler) -> Bool {
            guard allowInstall else { return false }
            installs += 1
            self.handler = handler
            return true
        }

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

    /// K1: Ohne `tick()` (Main Thread hängt) sperrt die Tastatur nur bis
    /// zur Grenze; danach geht alles durch, bis das Lebenszeichen zurück ist.
    func testHungMainThreadReleasesKeyboardUntilHeartbeatReturns() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        uptime += 4
        XCTAssertEqual(tap.handler?(.keyDown(keyCode: 36), []), .swallow, "kurzes Stocken sperrt weiter")
        uptime += 2
        XCTAssertEqual(tap.handler?(.keyDown(keyCode: 36), []), .pass, "Hänger gibt frei")

        controller.tick()
        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(tap.handler?(.keyDown(keyCode: 0), []), .swallow)
        // Return wurde im Hänger gedrückt, sein Loslassen muss durch.
        XCTAssertEqual(tap.handler?(.keyUp(keyCode: 36), []), .pass)
    }

    func testRegularTicksKeepTheLockTight() {
        let tap = FakeTap(), panel = FakePanel()
        let controller = makeController(tap: tap, panel: panel)
        controller.lock()

        for _ in 0..<30 {
            advance(1)
            controller.tick()
            XCTAssertEqual(tap.handler?(.keyDown(keyCode: 0), []), .swallow)
        }
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
