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

    private let screen7 = NotchScreenInfo(
        displayID: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 775), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false)

    func testDictationOnAScreenHidesTheStatusThereOnly() {
        let hub = UnifiedPillHub()
        let controller = makeController(hub: hub)
        controller.observeDictation()
        var other = screen7
        other.displayID = 8
        XCTAssertFalse(controller.isDictationShown(on: screen7))
        hub.dictationDidShow(onDisplay: 7)
        XCTAssertTrue(controller.isDictationShown(on: screen7))
        XCTAssertFalse(controller.isDictationShown(on: other))
        controller.config.unified = false
        XCTAssertFalse(controller.isDictationShown(on: screen7))
        controller.config.unified = true
        hub.dictationDidHide()
        XCTAssertFalse(controller.isDictationShown(on: screen7), "nach dem Diktat steht die Anzeige wieder")
    }

    /// Review-Befund: `@Published` meldet im willSet. Wer im Beobachter den
    /// Hub liest, sieht noch den alten Wert — deshalb übernimmt der
    /// Controller den gemeldeten Wert (`dictationChanged(to:)`), bevor er
    /// neu zeichnet. Hier ist die Falle festgehalten; die Reihenfolge der
    /// Beobachter untereinander garantiert Combine nicht.
    func testHubStillHoldsTheOldValueInsideItsObservers() {
        let hub = UnifiedPillHub()
        var hubInsideSink: [UInt32?] = []
        let probe = hub.$dictationDisplayID.dropFirst().sink { _ in hubInsideSink.append(hub.dictationDisplayID) }
        hub.dictationDidShow(onDisplay: 7)
        hub.dictationDidHide()
        probe.cancel()
        XCTAssertEqual(hubInsideSink, [nil, 7])
    }

    /// Beim Wechsel zählt der neue Wert schon beim Neuzeichnen.
    func testDictationChangeTakesTheValueBeforeRendering() {
        let controller = makeController()
        controller.dictationChanged(to: 7)
        XCTAssertTrue(controller.isDictationShown(on: screen7))
        controller.dictationChanged(to: nil)
        XCTAssertFalse(controller.isDictationShown(on: screen7))
    }

    /// Ein Hinweis während des Diktats wird gemerkt und danach nachgeholt.
    func testAlertDuringDictationIsRememberedAndReplayedOnEnd() {
        let controller = makeController()
        let id = UUID()
        controller.inputs = [NotchChatInput(
            id: id, title: "Jarvis", project: nil, status: .awaitingInput, statusSince: nil,
            lastTurnAt: nil, lastActivityAt: Date(), activity: nil)]
        controller.dictationChanged(to: 7)
        controller.alertDuringDictation = NotchAlert(sessionID: id, title: "Jarvis", kind: .awaitingInput)
        controller.dictationChanged(to: nil)
        XCTAssertEqual(controller.alert?.sessionID, id)
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

    /// Oben unter der Menüleiste ragt der Schattenrand des Diktat-Fensters in
    /// die Leiste. AppKit schöbe das Fenster sonst darunter, und die Pille
    /// spränge beim Start des Diktats nach unten (Standardlage 18 pt, ganz
    /// oben 24 pt).
    func testUnifiedPillPanelStaysOverTheRestingPillUnderTheMenuBar() {
        let screen = NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1600, height: 975)
        // Pille bündig unter der Leiste: höher lässt die Status-Pille sie nicht.
        let center = CGPoint(x: frame.midX, y: visible.maxY - PillMetrics.height / 2)
        let panel = OverlayController.makeUnifiedPillPanel(center: center)
        defer { panel.close() }
        let wanted = CGRect(
            origin: UnifiedPillGeometry.pillDictationPanelOrigin(center: center, panelSize: OverlayFrameResolver.panelSize),
            size: OverlayFrameResolver.panelSize)
        // Der Schattenrand (24 pt) ragt hier immer über den sichtbaren Bereich hinaus.
        XCTAssertEqual(panel.frame, wanted)
        XCTAssertEqual(panel.constrainFrameRect(wanted, to: screen), wanted)
        XCTAssertEqual(panel.frame.midY, center.y, accuracy: 0.5)
    }

    /// Wie oben, aber durch den echten Fehlerort: AppKit verschiebt beim
    /// Einblenden (`orderFront`), nicht beim Setzen des Rahmens. Das Fenster
    /// ist dabei unsichtbar und klickdurchlässig und geht sofort wieder zu.
    /// Gegenprobe: Dasselbe Fenster ohne `allowsAboveMenuBar` wird verschoben,
    /// der Test sieht den Fehler also wirklich.
    func testUnifiedPillPanelIsNotMovedWhenOrderedFront() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "kein Bildschirm")
        try XCTSkipUnless(screen.visibleFrame.maxY < screen.frame.maxY, "keine sichtbare Menüleiste")
        let center = CGPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY - PillMetrics.height / 2)
        func shiftOnOrderFront(_ panel: RecordingPanel) -> CGFloat {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            defer { panel.close() }
            let before = panel.frame
            panel.orderFrontRegardless()
            return panel.frame.minY - before.minY
        }
        XCTAssertEqual(shiftOnOrderFront(OverlayController.makeUnifiedPillPanel(center: center)), 0)
        let constrained = OverlayController.makeUnifiedPillPanel(center: center)
        constrained.allowsAboveMenuBar = false
        XCTAssertLessThan(shiftOnOrderFront(constrained), -1, "Gegenprobe: ohne Ausnahme schiebt AppKit nach unten")
    }

    /// Übergang: Die Status-Seite bekommt jede Änderung der Sichtbarkeit
    /// genau einmal, Wiederholungen nicht.
    func testStatusContentHiddenIsForwardedOnce() {
        let hub = UnifiedPillHub()
        var applied: [UInt32?] = []
        hub.applyStatusContentHidden = { applied.append($0) }
        hub.setStatusContentHidden(onDisplay: 7)
        hub.setStatusContentHidden(onDisplay: 7)
        hub.setStatusContentHidden(onDisplay: nil)
        hub.setStatusContentHidden(onDisplay: nil)
        XCTAssertEqual(applied, [7, nil])
        XCTAssertNil(hub.statusContentHiddenDisplayID)
    }

    /// Der Tausch wartet, bis der Main Thread sein Bild abgegeben hat: nie
    /// im selben Durchlauf, in dem er geplant wurde, und nur einmal, auch
    /// wenn danach der Ersatzweg abläuft.
    func testHandoverRunsOnlyAfterTheNextCommitAndOnce() {
        var runs = 0
        let done = expectation(description: "nach dem Abgeben")
        OverlayController.afterNextCommit(delay: 0.01, fallback: 0.1) {
            runs += 1
            done.fulfill()
        }
        XCTAssertEqual(runs, 0, "nicht sofort")
        wait(for: [done], timeout: 5)
        let settled = expectation(description: "Ersatzweg vorbei")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(runs, 1)
    }

    /// Läuft der Beobachter nie (anderer Run-Loop-Modus), kommt der Übergang
    /// trotzdem weiter, sonst bliebe das Diktat unsichtbar.
    func testHandoverFallsBackWhenNoCommitIsObserved() {
        var runs = 0
        let done = expectation(description: "Ersatzweg")
        OverlayController.afterNextCommit(delay: 0.01, fallback: 0.05, observesCommit: false) {
            runs += 1
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(runs, 1)
    }

    /// Diktat auf einen anderen Bildschirm gezogen, während die Status-Pille
    /// unsichtbar ist: Die Unsichtbarkeit wandert mit, der alte Bildschirm
    /// zeigt sie wieder. Ohne Übergang bleibt alles sichtbar.
    func testDraggingTheDictationMovesTheHiddenStatus() {
        let hub = UnifiedPillHub()
        var applied: [UInt32?] = []
        hub.applyStatusContentHidden = { applied.append($0) }
        hub.dictationMoved(toDisplay: 3)
        XCTAssertNil(hub.statusContentHiddenDisplayID, "kein Übergang, nichts zu verstecken")
        XCTAssertEqual(hub.dictationDisplayID, 3)
        hub.setStatusContentHidden(onDisplay: 3)
        hub.dictationMoved(toDisplay: 4)
        XCTAssertEqual(hub.statusContentHiddenDisplayID, 4)
        XCTAssertEqual(hub.dictationDisplayID, 4)
        XCTAssertEqual(applied, [3, 4])
    }

    /// Jeder Schließweg macht die Status-Pille wieder sichtbar: Ausblenden
    /// (`tearDownUnified`), Neuaufbau nach Bildschirmwechsel und das Ende des
    /// Übergangs (`closeWindow`).
    func testEveryCloseRevealsTheStatusAgain() {
        let hub = UnifiedPillHub.shared
        defer { hub.setStatusContentHidden(onDisplay: nil) }
        let overlay = OverlayController(presentsWindow: false)

        hub.setStatusContentHidden(onDisplay: 9)
        overlay.hide()
        XCTAssertNil(hub.statusContentHiddenDisplayID, "tearDownUnified")

        hub.setStatusContentHidden(onDisplay: 9)
        overlay.resetForRebuild()
        XCTAssertNil(hub.statusContentHiddenDisplayID, "Neuaufbau")

        hub.setStatusContentHidden(onDisplay: 9)
        overlay.applyMorph([.closeWindow])
        XCTAssertNil(hub.statusContentHiddenDisplayID, "Ende des Übergangs")

        hub.setStatusContentHidden(onDisplay: 9)
        overlay.applyMorph([.revealStatus])
        XCTAssertNil(hub.statusContentHiddenDisplayID, "Rücktausch")
    }

    /// Die getrennte Diktat-Pille überlässt die Lage weiter AppKit.
    func testClassicPanelKeepsTheAppKitConstraint() {
        let panel = RecordingPanel(initialOrigin: .zero)
        defer { panel.close() }
        XCTAssertFalse(panel.allowsAboveMenuBar)
        XCTAssertFalse(panel.clampsLikeStatusPill)
    }

    /// Menüleiste automatisch ausgeblendet: Die vereinte Diktat-Pille bleibt
    /// wie die Status-Pille eine Leistenhöhe unter der Bildschirmkante, damit
    /// die hereinfahrende Leiste ✓ und ✕ nicht verdeckt. Die getrennte Pille
    /// rechnet weiter mit dem sichtbaren Bereich.
    func testUnifiedPillStaysBelowAHiddenMenuBarLikeTheStatusPill() {
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let hiddenBar = NotchScreenInfo(
            displayID: 7, frame: frame, visibleFrame: frame, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false, uuid: "HIDDEN")
        let unified = OverlayController.makeUnifiedPillPanel(center: CGPoint(x: 800, y: 900))
        defer { unified.close() }
        let area = unified.pillClampArea(visibleFrame: frame, info: hiddenBar)
        XCTAssertEqual(area, NotchPillPlacement.usableArea(hiddenBar))
        XCTAssertEqual(area.maxY, frame.maxY - NotchGeometry.fallbackMenuBarHeight)
        // Pille bündig an der Bildschirmkante wird um die Ersatzhöhe heruntergeholt.
        let size = OverlayFrameResolver.panelSize
        let pill = NSRect(x: 100, y: OverlayFrameResolver.contentMargin, width: 200, height: PillMetrics.height)
        let atTop = NSPoint(x: 400, y: frame.maxY - OverlayFrameResolver.contentMargin - PillMetrics.height)
        let clamped = OverlayFrameResolver.clampedPanelOrigin(panelOrigin: atTop, pillFrameInPanel: pill, visibleFrame: area)
        XCTAssertEqual(clamped.y + pill.maxY, area.maxY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(clamped.y + size.height, frame.maxY + OverlayFrameResolver.contentMargin)

        let classic = RecordingPanel(initialOrigin: .zero)
        defer { classic.close() }
        XCTAssertEqual(classic.pillClampArea(visibleFrame: frame, info: hiddenBar), frame)
        // Sichtbare Leiste: beide Bereiche sind gleich.
        XCTAssertEqual(unified.pillClampArea(visibleFrame: pillScreen.visibleFrame, info: pillScreen), pillScreen.visibleFrame)
    }

    // MARK: Asynchroner Aufbau der Diktat-Pille

    private let pillScreen = NotchScreenInfo(
        displayID: 2, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 975), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false, uuid: "PILL")
    private let notchScreen = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: 0, width: 1512, height: 944), safeAreaTop: 38,
        auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltIn: true)

    /// Pille „gezeigt“ ohne Fenster (Testprozess): wie ein Hinweis, der lange steht.
    private func presentedOverlay() -> OverlayController {
        let overlay = OverlayController(presentsWindow: false)
        overlay.showQuickActionHint("x", duration: 60)
        XCTAssertTrue(overlay.isPresented)
        return overlay
    }

    private func begin(
        _ overlay: OverlayController, timeout: TimeInterval = 0.08,
        lookup: @escaping (@escaping @MainActor (UInt32?) -> Void) -> Void,
        build: @escaping @MainActor (DictationPillPlacement) -> Void
    ) {
        overlay.beginUnifiedPresentation(
            screens: [notchScreen, pillScreen], mouseDisplayID: 2, mainDisplayID: 2,
            frontWindowLookup: lookup, timeout: timeout, build: build)
    }

    func testFrontWindowAnswerPlacesThePillThere() {
        let overlay = presentedOverlay()
        var built: [DictationPillPlacement] = []
        begin(overlay, lookup: { answer in answer(1) }, build: { built.append($0) })
        XCTAssertEqual(built, [.notch(notchScreen)], "vorderes Fenster am MacBook: an der Notch")
        overlay.hide()
    }

    /// Antwortet die Fensterliste nicht rechtzeitig, gilt nach dem Zeitlimit
    /// die Maus; eine späte Antwort ändert nichts mehr.
    func testTimeoutFallsBackToTheMouseAndIgnoresALateAnswer() {
        let overlay = presentedOverlay()
        var built: [DictationPillPlacement] = []
        var lateAnswer: (@MainActor (UInt32?) -> Void)?
        begin(overlay, timeout: 0.05, lookup: { lateAnswer = $0 }, build: { built.append($0) })
        XCTAssertTrue(built.isEmpty, "vor dem Zeitlimit steht noch nichts")
        let waited = expectation(description: "Zeitlimit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built.first?.screen.displayID, 2, "Maus-Bildschirm")
        lateAnswer?(1)
        XCTAssertEqual(built.count, 1, "späte Antwort wird verworfen")
        overlay.hide()
    }

    /// Nach `hide` baut eine späte Antwort kein Fenster mehr.
    func testLateAnswerAfterHideBuildsNothing() {
        let overlay = presentedOverlay()
        var built = 0
        var answer: (@MainActor (UInt32?) -> Void)?
        begin(overlay, timeout: 10, lookup: { answer = $0 }, build: { _ in built += 1 })
        overlay.hide()
        answer?(2)
        XCTAssertEqual(built, 0)
    }

    /// Ein neuerer Aufbau (Generation) macht die Antwort des älteren wertlos.
    func testOlderPresentationIsSupersededByANewerOne() {
        let overlay = presentedOverlay()
        var built: [UInt32] = []
        var oldAnswer: (@MainActor (UInt32?) -> Void)?
        begin(overlay, timeout: 10, lookup: { oldAnswer = $0 }, build: { built.append($0.screen.displayID) })
        begin(overlay, lookup: { answer in answer(2) }, build: { built.append($0.screen.displayID) })
        oldAnswer?(1)
        XCTAssertEqual(built, [2])
        overlay.hide()
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
