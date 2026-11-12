import AppKit
import XCTest
@testable import WhisperM8

/// Vereinte Pille, Steuerung: Einstellungen und Kill-Switch, Klick auf den
/// Kern, Raute, Tastatur in der Liste, nachgeholter Hinweis, und dass das
/// Diktat sich beim Hub ab- und anmeldet. Ohne Fenster (Spies, eigener Hub).
@MainActor
final class UnifiedPillControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var prefs: AppPreferences!

    override func setUp() {
        super.setUp()
        suiteName = "unified-pill-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        prefs = AppPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(
        hub: UnifiedPillHub? = nil,
        startDictation: @escaping @MainActor () -> Void = {},
        focus: @escaping @MainActor (UUID) -> Void = { _ in }
    ) -> NotchStatusController {
        let controller = NotchStatusController(
            statusStore: AgentSessionRuntimeStatusStore(),
            activityStore: AgentSessionActivityStore(),
            workspaceProvider: { .empty },
            appIsActive: { false },
            focusSession: focus,
            agentWindowDisplayID: { nil },
            prefs: prefs,
            startDictation: startDictation,
            hub: hub ?? UnifiedPillHub())
        controller.config = NotchConfig.current(prefs)
        return controller
    }

    // MARK: Einstellungen

    func testUnifiedPillIsOnByDefaultAndDropsTheScreenChoice() {
        prefs.notchStatusScreenRaw = NotchScreenChoice.main.rawValue
        let config = NotchConfig.current(prefs)
        XCTAssertTrue(prefs.isUnifiedPillEnabled)
        XCTAssertTrue(config.unified)
        XCTAssertEqual(config.screenChoice, .auto)
    }

    /// Kill-Switch aus: alles wie vorher, auch die Bildschirmwahl.
    func testKillSwitchRestoresTheSeparatePills() {
        defaults.set(false, forKey: PreferenceKeys.unifiedPillEnabled)
        prefs.notchStatusScreenRaw = NotchScreenChoice.main.rawValue
        let config = NotchConfig.current(prefs)
        XCTAssertFalse(config.unified)
        XCTAssertEqual(config.screenChoice, .main)
    }

    func testHubFollowsTheKillSwitch() {
        let hub = UnifiedPillHub()
        var enabled = true
        hub.isEnabled = { enabled }
        XCTAssertTrue(hub.isEnabled())
        enabled = false
        XCTAssertFalse(hub.isEnabled())
    }

    // MARK: Klick auf den Kern

    func testClickOnTheRestingCoreStartsDictation() {
        var started = 0
        let controller = makeController(startDictation: { started += 1 })
        controller.startDictationFromPill(.pill)
        XCTAssertEqual(started, 1)
        XCTAssertGreaterThan(controller.slots[.pill]!.lastCoreClickAt, Date().addingTimeInterval(-1))
    }

    // MARK: Raute

    func testBadgeGoesToTheHubOnlyWhenUnified() {
        let hub = UnifiedPillHub()
        let controller = makeController(hub: hub)
        controller.publishBadge(NotchSummary(working: 2, waiting: 1))
        XCTAssertEqual(hub.badge, DictationStatusBadge(waiting: 1, errored: 0))
        controller.publishBadge(NotchSummary(working: 2))
        XCTAssertNil(hub.badge)

        controller.config.unified = false
        controller.publishBadge(NotchSummary(waiting: 3))
        XCTAssertNil(hub.badge)
    }

    func testDictationOnAScreenHidesTheStatusThereOnly() {
        let hub = UnifiedPillHub()
        let controller = makeController(hub: hub)
        let screen = NotchScreenInfo(
            displayID: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 775), safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)
        var other = screen
        other.displayID = 8
        XCTAssertFalse(controller.isDictationShown(on: screen))
        hub.dictationDidShow(onDisplay: 7)
        XCTAssertTrue(controller.isDictationShown(on: screen))
        XCTAssertFalse(controller.isDictationShown(on: other))
        controller.config.unified = false
        XCTAssertFalse(controller.isDictationShown(on: screen))
        hub.dictationDidHide()
        XCTAssertNil(hub.dictationDisplayID)
    }

    // MARK: Hinweis nach dem Diktat

    func testAlertDuringDictationIsReplayedWhileTheChatStillWaits() {
        let controller = makeController()
        let id = UUID()
        controller.inputs = [NotchChatInput(
            id: id, title: "Jarvis", project: nil, status: .awaitingInput, statusSince: nil,
            lastTurnAt: nil, lastActivityAt: Date(), activity: nil)]
        controller.alertDuringDictation = NotchAlert(sessionID: id, title: "Jarvis", kind: .awaitingInput)
        controller.replayAlertAfterDictation()
        XCTAssertEqual(controller.alert?.sessionID, id)
        XCTAssertNil(controller.alertDuringDictation)
    }

    func testAlertIsDroppedWhenTheChatWorksAgain() {
        let controller = makeController()
        let id = UUID()
        controller.inputs = [NotchChatInput(
            id: id, title: "Jarvis", project: nil, status: .working, statusSince: nil,
            lastTurnAt: nil, lastActivityAt: Date(), activity: nil)]
        controller.alertDuringDictation = NotchAlert(sessionID: id, title: "Jarvis", kind: .awaitingInput)
        controller.replayAlertAfterDictation()
        XCTAssertNil(controller.alert)
    }

    // MARK: Tastatur

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    func testArrowKeysMoveTheSelectionAndReturnOpensTheChat() {
        var focused: UUID?
        let controller = makeController(focus: { focused = $0 })
        let ids = [UUID(), UUID(), UUID()]
        // Ohne Fenster: Zeichnen bleibt aus, die Zeilen setzt der Test.
        controller.config.isActive = false
        controller.expandedKind = .pill
        controller.listRowIDs = ids

        XCTAssertTrue(controller.handleListKey(key(125)))
        XCTAssertEqual(controller.keyboardSelection, ids[0])
        XCTAssertTrue(controller.handleListKey(key(125)))
        XCTAssertEqual(controller.keyboardSelection, ids[1])
        XCTAssertTrue(controller.handleListKey(key(126)))
        XCTAssertEqual(controller.keyboardSelection, ids[0])
        XCTAssertTrue(controller.handleListKey(key(126)))
        XCTAssertEqual(controller.keyboardSelection, ids[0], "bleibt oben stehen")
        XCTAssertFalse(controller.handleListKey(key(0)), "andere Tasten gehen weiter")

        XCTAssertTrue(controller.handleListKey(key(36)))
        XCTAssertEqual(focused, ids[0])
        XCTAssertFalse(controller.isExpanded)
    }

    func testKeysDoNothingWithoutAnOpenList() {
        let controller = makeController()
        controller.listRowIDs = [UUID()]
        XCTAssertFalse(controller.handleListKey(key(125)))
    }

    // MARK: Diktat-Seite

    /// Ohne Fenster (Testprozess) bleibt die Diktat-Pille klassisch, und
    /// `hide` meldet das Diktat immer beim Hub ab.
    func testOverlayWithoutWindowStaysClassicAndSignsOffAtTheHub() {
        let overlay = OverlayController(presentsWindow: false)
        XCTAssertEqual(overlay.presentation, .classic)
        UnifiedPillHub.shared.dictationDidShow(onDisplay: 42)
        overlay.hide()
        XCTAssertNil(UnifiedPillHub.shared.dictationDisplayID)
        XCTAssertNil(overlay.statusBadge)
        XCTAssertFalse(overlay.isPresented)
    }

    func testPresentationFlags() {
        XCTAssertFalse(OverlayPresentation.classic.isUnified)
        XCTAssertTrue(OverlayPresentation.pill.isUnified)
        XCTAssertTrue(OverlayPresentation.notch(width: 185, height: 32).isNotch)
        XCTAssertFalse(OverlayPresentation.pill.isNotch)
    }

    // MARK: Liste der Ausgabemodi, vorderes Fenster

    func testModeListOpensBelowAPillInTheUpperHalf() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let pill = NSRect(x: 400, y: 500, width: 200, height: 40)
        let size = NSSize(width: 160, height: 120)
        let above = OutputModeListPlacement.frame(listSize: size, pillFrame: pill, visibleFrame: screen)
        XCTAssertGreaterThan(above.minY, pill.minY, "ohne Vorgabe wie bisher über der Pille, wenn Platz ist")
        let below = OutputModeListPlacement.frame(
            listSize: size, pillFrame: pill, visibleFrame: screen, opensDownward: true)
        XCTAssertEqual(below.maxY, pill.minY - OutputModeListPlacement.gap)
    }

    func testFrontWindowIsTheFirstNormalWindowOfTheApp() {
        func window(pid: Int32, layer: Int, x: CGFloat, alpha: Double = 1) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: layer,
                kCGWindowAlpha as String: alpha,
                kCGWindowBounds as String: CGRect(x: x, y: 100, width: 800, height: 600).dictionaryRepresentation,
            ]
        }
        let list = [
            window(pid: 9, layer: 0, x: 0),       // fremde App
            window(pid: 5, layer: 25, x: 10),     // Statusmenü
            window(pid: 5, layer: 0, x: 20, alpha: 0),
            window(pid: 5, layer: 0, x: 2000),    // gesucht
            window(pid: 5, layer: 0, x: 30),
        ]
        let frame = FrontWindowLocator.frontWindowFrame(in: list, pid: 5, primaryHeight: 1000)
        XCTAssertEqual(frame, CGRect(x: 2000, y: 300, width: 800, height: 600))
        XCTAssertNil(FrontWindowLocator.frontWindowFrame(in: list, pid: 77, primaryHeight: 1000))
    }
}
