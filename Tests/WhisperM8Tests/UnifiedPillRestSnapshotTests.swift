import XCTest
@testable import WhisperM8

/// Ruhebild der Status-Seite für den Übergang ins Diktat
/// (`NotchStatusController.restSnapshot`): was dort steht bzw. nach dem
/// Diktat stehen wird, und wo kein Übergang stattfindet.
@MainActor
final class UnifiedPillRestSnapshotTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var prefs: AppPreferences!

    private let pillScreen = NotchScreenInfo(
        displayID: 2, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 975), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false, uuid: "PILL")
    private let notchScreen = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: 0, width: 1512, height: 944), safeAreaTop: 38,
        auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltIn: true)

    override func setUp() {
        super.setUp()
        suiteName = "unified-rest-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        prefs = AppPreferences(defaults: defaults)
        prefs.isNotchStatusEnabled = true
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(_ inputs: [NotchChatInput] = []) -> NotchStatusController {
        let controller = NotchStatusController(
            statusStore: AgentSessionRuntimeStatusStore(),
            activityStore: AgentSessionActivityStore(),
            workspaceProvider: { .empty },
            appIsActive: { false },
            focusSession: { _ in },
            agentWindowDisplayID: { nil },
            prefs: prefs,
            startDictation: {},
            hub: UnifiedPillHub())
        controller.config = NotchConfig.current(prefs)
        controller.config.isActive = true
        controller.cachedPlacements = [
            NotchPlacement(kind: .notch, screen: notchScreen),
            NotchPlacement(kind: .pill, screen: pillScreen),
        ]
        controller.inputs = inputs
        return controller
    }

    private func input(_ status: AgentSessionRuntimeStatus, id: UUID = UUID()) -> NotchChatInput {
        NotchChatInput(
            id: id, title: "Chat", project: nil, status: status, statusSince: Date(),
            lastTurnAt: nil, lastActivityAt: Date(), activity: nil)
    }

    func testPillScreenGivesTheCountersAndTheCenterOfTheVisiblePill() throws {
        let controller = makeController([input(.working), input(.awaitingInput)])
        let snapshot = try XCTUnwrap(controller.restSnapshot(onDisplay: 2))
        XCTAssertEqual(snapshot.look, .pill(summary: NotchSummary(working: 1, waiting: 1), alert: nil))
        let center = NotchPillPlacement.defaultCenter(pillScreen)
        XCTAssertEqual(try XCTUnwrap(snapshot.center).x, center.x, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(snapshot.center).y, center.y, accuracy: 0.5)
    }

    /// Gezogene Pille: Das Diktat beginnt dort, wo sie steht.
    func testPillCenterFollowsTheRememberedPosition() throws {
        prefs.notchPillPositions = [pillScreen.pillStorageKey: NotchPillPosition(x: 0.25, y: 0.5)]
        let controller = makeController()
        let center = try XCTUnwrap(controller.restSnapshot(onDisplay: 2)?.center)
        XCTAssertEqual(center.x, 400, accuracy: 0.5)
        XCTAssertEqual(center.y, 500, accuracy: 0.5)
    }

    /// Kein Übergang, wo keine ruhende Pille steht: offene Liste, Vollbild,
    /// Status aus, Kill-Switch, fremder Bildschirm.
    func testNoRestLookWhereNoRestingPillStands() {
        let controller = makeController([input(.working)])
        XCTAssertNil(controller.restSnapshot(onDisplay: 99), "fremder Bildschirm")

        controller.expandedKind = .pill
        XCTAssertNil(controller.restSnapshot(onDisplay: 2), "Liste offen")
        controller.expandedKind = nil

        controller.slots[.pill]?.isFullscreenHidden = true
        XCTAssertNil(controller.restSnapshot(onDisplay: 2), "Vollbild")
        controller.slots[.pill]?.isFullscreenHidden = false

        controller.config.unified = false
        XCTAssertNil(controller.restSnapshot(onDisplay: 2), "Kill-Switch")
        controller.config.unified = true

        controller.config.isActive = false
        XCTAssertNil(controller.restSnapshot(onDisplay: 2), "Status aus")
    }

    /// An der Notch nur mit Anzeige; ohne Aktivität zeigt das Diktat das Band selbst.
    func testNotchGivesTheRowOnlyWhenSomethingIsGoingOn() throws {
        XCTAssertNil(makeController().restSnapshot(onDisplay: 1))
        let snapshot = try XCTUnwrap(makeController([input(.working)]).restSnapshot(onDisplay: 1))
        XCTAssertEqual(snapshot.look, .notch(
            summary: NotchSummary(working: 1), alert: nil, bodyWidth: notchScreen.notchWidth))
        XCTAssertNil(snapshot.center)
    }

    /// Ein „braucht dich“ während des Diktats wird danach nachgeholt: Das
    /// Diktat zieht sich gleich in diese breitere Pille zurück.
    func testPendingAlertShapesTheRestLookAfterDictation() throws {
        let id = UUID()
        let controller = makeController([input(.awaitingInput, id: id)])
        let pending = NotchAlert(sessionID: id, title: "Chat", kind: .awaitingInput)
        controller.alertDuringDictation = pending
        let look = try XCTUnwrap(controller.restSnapshot(onDisplay: 2)).look
        XCTAssertEqual(look, .pill(summary: NotchSummary(waiting: 1), alert: pending))

        controller.inputs = [input(.working, id: id)]
        XCTAssertEqual(try XCTUnwrap(controller.restSnapshot(onDisplay: 2)).look,
                       .pill(summary: NotchSummary(working: 1), alert: nil), "Anlass weg: kein Hinweis")
    }

    /// Der Status meldet sein Ruhebild beim Hub an.
    func testControllerRegistersItsRestLookAtTheHub() {
        let hub = UnifiedPillHub()
        let controller = NotchStatusController(
            statusStore: AgentSessionRuntimeStatusStore(), activityStore: AgentSessionActivityStore(),
            workspaceProvider: { .empty }, appIsActive: { false }, focusSession: { _ in },
            agentWindowDisplayID: { nil }, prefs: prefs, startDictation: {}, hub: hub)
        controller.config = NotchConfig.current(prefs)
        controller.config.isActive = true
        controller.cachedPlacements = [NotchPlacement(kind: .pill, screen: pillScreen)]
        XCTAssertNil(hub.restSnapshot(2))
        controller.observeDictation()
        XCTAssertNotNil(hub.restSnapshot(2))
    }
}
