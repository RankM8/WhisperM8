import CoreGraphics
import XCTest
@testable import WhisperM8

/// Vereinte Pille, reine Teile: Priorität, wo das Diktat erscheint, Raute,
/// Geometrie, Klickziel und Aufklapprichtung.
final class UnifiedPillModelTests: XCTestCase {
    private let macBook = NotchScreenInfo(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), safeAreaTop: 38,
        auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5, isBuiltIn: true, uuid: "MACBOOK")
    private let external = NotchScreenInfo(
        displayID: 2, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 70, width: 2560, height: 1345), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isBuiltIn: false, uuid: "EXTERNAL")

    // MARK: Priorität

    func testPriorityIslandBeforeDictationBeforeListBeforeAlertBeforeRest() {
        var s = UnifiedPillSituation(island: true, dictation: true, list: true, alert: true)
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .island)
        s.island = false
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .dictation)
        s.dictation = false
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .list)
        s.list = false
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .alert)
        s.alert = false
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .rest)
    }

    /// Status aus: die Pille gibt es nur noch fürs Diktat und die Insel.
    func testStatusOffShowsOnlyDictationAndIsland() {
        var s = UnifiedPillSituation(alert: true, statusActive: false)
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .hidden)
        s.dictation = true
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .dictation)
        s.dictation = false
        s.island = true
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .island)
    }

    /// Vollbild: in Ruhe weg, Diktat und Insel trotzdem.
    func testFullscreenHidesRestButNotDictationOrIsland() {
        var s = UnifiedPillSituation(alert: true, fullscreen: true)
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .hidden)
        s.dictation = true
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .dictation)
        s = UnifiedPillSituation(island: true, fullscreen: true)
        XCTAssertEqual(UnifiedPillPriority.content(for: s), .island)
    }

    /// An der Notch ist in Ruhe nichts zu sehen, wenn nichts los ist.
    func testRestCanBeInvisible() {
        XCTAssertEqual(UnifiedPillPriority.content(for: UnifiedPillSituation(restVisible: false)), .hidden)
    }

    // MARK: Raute

    func testBadgeOnlyForWaitingAndErrors() {
        XCTAssertNil(DictationStatusBadge(summary: NotchSummary(working: 3, freshDone: 2)))
        XCTAssertEqual(DictationStatusBadge(summary: NotchSummary(working: 1, waiting: 2)),
                       DictationStatusBadge(waiting: 2, errored: 0))
        XCTAssertEqual(DictationStatusBadge(summary: NotchSummary(errored: 1))?.errored, 1)
    }

    // MARK: Wo das Diktat erscheint

    func testDictationShowsWhereYouType() {
        let atNotch = DictationPillPlacement.resolve(
            frontWindowDisplayID: 1, mouseDisplayID: 2, mainDisplayID: 2,
            screens: [macBook, external], positions: [:])
        XCTAssertEqual(atNotch, .notch(macBook))

        let onExternal = DictationPillPlacement.resolve(
            frontWindowDisplayID: 2, mouseDisplayID: 1, mainDisplayID: 1,
            screens: [macBook, external], positions: [:])
        XCTAssertEqual(onExternal?.screen.displayID, 2)
        XCTAssertEqual(onExternal?.isNotch, false)
    }

    /// Ohne vorderes Fenster zählt die Maus, dann der Hauptbildschirm.
    func testDictationFallsBackToMouseThenMain() {
        let byMouse = DictationPillPlacement.resolve(
            frontWindowDisplayID: nil, mouseDisplayID: 2, mainDisplayID: 1,
            screens: [macBook, external], positions: [:])
        XCTAssertEqual(byMouse?.screen.displayID, 2)
        let byMain = DictationPillPlacement.resolve(
            frontWindowDisplayID: 99, mouseDisplayID: nil, mainDisplayID: 1,
            screens: [macBook, external], positions: [:])
        XCTAssertEqual(byMain?.screen.displayID, 1)
        XCTAssertNil(DictationPillPlacement.resolve(
            frontWindowDisplayID: 1, mouseDisplayID: 1, mainDisplayID: 1, screens: [], positions: [:]))
    }

    /// Ohne Notch an der gemerkten Lage dieses Bildschirms, sonst oben mittig.
    func testDictationPillUsesTheRememberedSpotOfItsScreen() {
        let standard = DictationPillPlacement.resolve(
            frontWindowDisplayID: 2, mouseDisplayID: nil, mainDisplayID: 2, screens: [external], positions: [:])
        guard case .pill(_, let top) = standard else { return XCTFail("Pille erwartet") }
        XCTAssertEqual(top, NotchPillPlacement.defaultCenter(external))
        XCTAssertEqual(top.x, external.frame.midX)

        let moved = NotchPillPosition(x: 0.25, y: 0.2)
        let remembered = DictationPillPlacement.resolve(
            frontWindowDisplayID: 2, mouseDisplayID: nil, mainDisplayID: 2, screens: [external],
            positions: ["EXTERNAL": moved])
        guard case .pill(_, let center) = remembered else { return XCTFail("Pille erwartet") }
        XCTAssertEqual(center, NotchPillPlacement.center(external, stored: moved))
    }

    func testDisplayOfAWindowIsTheScreenWithTheLargestOverlap() {
        let mostlyExternal = CGRect(x: 1400, y: 200, width: 800, height: 600)
        XCTAssertEqual(DictationPillPlacement.displayID(containing: mostlyExternal, screens: [macBook, external]), 2)
        let offscreen = CGRect(x: -5000, y: 0, width: 10, height: 10)
        XCTAssertNil(DictationPillPlacement.displayID(containing: offscreen, screens: [macBook, external]))
    }

    // MARK: Geometrie

    /// Darüberfahren: die rechte Kante bleibt, wo sie zugeklappt war.
    func testHoverExpansionKeepsTheRightEdge() {
        XCTAssertEqual(UnifiedPillGeometry.centerGuide(width: 200, collapsedWidth: nil, hoverExpanded: false), 100)
        XCTAssertEqual(UnifiedPillGeometry.centerGuide(width: 200, collapsedWidth: 150, hoverExpanded: false), 100)
        // Aufgeklappt 260 statt 200: Ausrichtungspunkt 100 vor der rechten Kante.
        let guide = UnifiedPillGeometry.centerGuide(width: 260, collapsedWidth: 200, hoverExpanded: true)
        XCTAssertEqual(guide, 160)
        // Mitte des Fensters bei 0: rechte Kante bei 260 − 160 = 100, wie zugeklappt (200 / 2).
        XCTAssertEqual(260 - guide, 200 / 2)
    }

    /// Kommt beim Darüberfahren Kontext dazu, bleibt die Pille im Fenster
    /// (560 pt Platz): nicht mehr als die halbe Breite links der Mitte.
    func testHoverGuideNeverPushesThePillOutOfThePanel() {
        let guide = UnifiedPillGeometry.centerGuide(width: 500, collapsedWidth: 120, hoverExpanded: true, available: 560)
        XCTAssertEqual(guide, 280, "linke Kante bei 0")
        XCTAssertLessThanOrEqual(500 - guide, 280, "rechte Kante im Fenster")
        let narrow = UnifiedPillGeometry.centerGuide(width: 300, collapsedWidth: 220, hoverExpanded: true, available: 560)
        XCTAssertEqual(narrow, 190)
    }

    func testStatusPanelIsCenteredOnThePillWithShadowMargin() {
        let center = NotchPillPlacement.defaultCenter(external)
        let frame = UnifiedPillGeometry.statusPanelFrame(mode: .compact(chipCount: 2), center: center, screen: external)
        XCTAssertEqual(frame.midX, center.x, accuracy: 0.5)
        XCTAssertEqual(frame.midY, center.y, accuracy: 0.5)
        XCTAssertEqual(frame.height, NotchGeometry.pillHeight + 2 * UnifiedPillGeometry.shadowMargin)
        XCTAssertEqual(frame.width, UnifiedPillGeometry.statusPanelWidth)
    }

    /// Oben: die Liste wächst nach unten, die Pillen-Zeile bleibt stehen.
    func testExpandedStatusPanelKeepsThePillRowAtTheTop() {
        let center = NotchPillPlacement.defaultCenter(external)
        let mode = NotchPanelMode.expanded(rowCount: 4, sectionCount: 2)
        let frame = UnifiedPillGeometry.statusPanelFrame(mode: mode, center: center, screen: external)
        XCTAssertEqual(frame.maxY - UnifiedPillGeometry.shadowMargin, center.y + NotchGeometry.pillHeight / 2, accuracy: 0.5)
        XCTAssertGreaterThan(frame.height, 200)
    }

    /// Unten: alles klappt nach oben, die Pillen-Zeile bleibt unten.
    func testExpandedStatusPanelOpensUpwardInTheLowerHalf() {
        let low = NotchPillPlacement.center(external, stored: NotchPillPosition(x: 0.5, y: 0.15))
        let mode = NotchPanelMode.expanded(rowCount: 4, sectionCount: 2)
        let frame = UnifiedPillGeometry.statusPanelFrame(mode: mode, center: low, screen: external)
        XCTAssertEqual(frame.minY + UnifiedPillGeometry.shadowMargin, low.y - NotchGeometry.pillHeight / 2, accuracy: 0.5)
    }

    /// Am rechten Rand: der breite Hinweis wird zur Mitte hin verschoben.
    func testAlertNearTheRightEdgeShiftsInward() {
        let edge = NotchPillPlacement.center(external, stored: NotchPillPosition(x: 0.995, y: 0.9))
        let visible = UnifiedPillGeometry.statusVisibleFrame(mode: .alert, center: edge, screen: external)
        XCTAssertLessThanOrEqual(visible.maxX, external.visibleFrame.maxX + 0.5)
        XCTAssertEqual(visible.width, NotchGeometry.pillAlertWidth)
    }

    func testDraggedCenterStaysOnScreen() {
        let start = NotchPillPlacement.defaultCenter(external)
        let moved = UnifiedPillGeometry.draggedCenter(
            from: start, by: CGVector(dx: 10_000, dy: 10_000), compactWidth: 64, screen: external)
        let area = NotchPillPlacement.usableArea(external)
        XCTAssertEqual(moved.x + 32, area.maxX, accuracy: 0.5)
        XCTAssertEqual(moved.y + NotchGeometry.pillHeight / 2, area.maxY, accuracy: 0.5)
    }

    func testStatusHeaderHitAreaRespectsTheShadowMargin() {
        // Fenster 300 hoch, Liste nach unten: Kopf von 236 bis 276.
        XCTAssertTrue(UnifiedPillGeometry.isInStatusHeader(y: 250, panelHeight: 300, headerAtBottom: false))
        XCTAssertFalse(UnifiedPillGeometry.isInStatusHeader(y: 290, panelHeight: 300, headerAtBottom: false))
        XCTAssertFalse(UnifiedPillGeometry.isInStatusHeader(y: 100, panelHeight: 300, headerAtBottom: false))
        // Liste nach oben: Kopf von 24 bis 64.
        XCTAssertTrue(UnifiedPillGeometry.isInStatusHeader(y: 40, panelHeight: 300, headerAtBottom: true))
        XCTAssertFalse(UnifiedPillGeometry.isInStatusHeader(y: 10, panelHeight: 300, headerAtBottom: true))
    }

    /// Diktat an der Notch: oben bündig, mittig unter der Aussparung.
    func testNotchDictationPanelHangsFromTheTop() {
        let frame = UnifiedPillGeometry.notchDictationPanelFrame(screen: macBook, panelWidth: 608)
        XCTAssertEqual(frame.maxY, macBook.frame.maxY)
        XCTAssertEqual(frame.midX, macBook.notchCenterX)
        XCTAssertEqual(frame.height, 38 + PillMetrics.height + UnifiedPillGeometry.shadowMargin)
    }

    func testDictationPanelIsCenteredOnThePill() {
        let origin = UnifiedPillGeometry.pillDictationPanelOrigin(
            center: CGPoint(x: 500, y: 400), panelSize: CGSize(width: 608, height: 88))
        XCTAssertEqual(origin, CGPoint(x: 196, y: 356))
        let anchor = PillAnchor(maxX: 600, minX: 400, y: 380)
        XCTAssertEqual(UnifiedPillGeometry.center(of: anchor), CGPoint(x: 500, y: 400))
    }

    // MARK: Klick und Richtung

    func testClickOnTheCoreStartsDictationElseOpensTheList() {
        let core = CGRect(x: 30, y: 30, width: 46, height: 28)
        XCTAssertEqual(UnifiedPillClickTarget.resolve(point: CGPoint(x: 50, y: 40), coreFrame: core), .core)
        XCTAssertEqual(UnifiedPillClickTarget.resolve(point: CGPoint(x: 90, y: 40), coreFrame: core), .status)
        XCTAssertEqual(UnifiedPillClickTarget.resolve(point: CGPoint(x: 50, y: 40), coreFrame: nil), .status)
    }

    func testMenusOpenDownwardInTheUpperHalf() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertTrue(UnifiedPillMenuDirection.opensDownward(
            pillFrame: CGRect(x: 400, y: 700, width: 200, height: 40), screenFrame: screen))
        XCTAssertFalse(UnifiedPillMenuDirection.opensDownward(
            pillFrame: CGRect(x: 400, y: 60, width: 200, height: 40), screenFrame: screen))
    }
}
