import XCTest
@testable import WhisperM8

/// Lage der Menü-Karte am Chat (Runde 5): unter dem Kopf, an der Kachel,
/// neben der Zeile der Liste; kippen und begrenzen an den Rändern.
final class ControllerMenuPlacementTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let width: CGFloat = 300
    private let legend: CGFloat = 30

    private func place(_ kind: ControllerMenuPlacement.Anchor?, _ rect: CGRect = .zero, height: CGFloat,
                       container: CGRect? = nil) -> ControllerMenuPlacement.Result {
        ControllerMenuPlacement.place(
            anchor: kind.map { (kind: $0, rect: rect) }, contentHeight: height, width: width,
            container: container ?? window, bottomInset: legend)
    }

    func testHeaderPutsTheCardRightAlignedBelow() {
        let header = CGRect(x: 280, y: 60, width: 920, height: 36)
        let result = place(.header, header, height: 400)
        // Rechts bündig mit dem Kopf, am Fensterrand um den Rand eingerückt.
        XCTAssertEqual(result.frame.maxX, window.maxX - ControllerMenuPlacement.margin)
        XCTAssertEqual(result.frame.minY, header.maxY + ControllerMenuPlacement.gap)
        XCTAssertEqual(result.frame.height, 400)
        XCTAssertFalse(result.scrolls)
    }

    func testTileInTheMiddleOfTheGridOpensBelowItsHeader() {
        let tile = CGRect(x: 300, y: 430, width: 450, height: 26)
        let result = place(.tile, tile, height: 250)
        XCTAssertEqual(result.frame.minY, tile.maxY + ControllerMenuPlacement.gap)
        XCTAssertEqual(result.frame.maxX, tile.maxX)
    }

    /// Kachel unten im Raster: unten zu wenig Platz, also über den Kachelkopf.
    func testTileNearTheBottomFlipsAbove() {
        let tile = CGRect(x: 600, y: 640, width: 600, height: 26)
        let result = place(.tile, tile, height: 420)
        XCTAssertEqual(result.frame.maxY, tile.minY - ControllerMenuPlacement.gap)
        XCTAssertEqual(result.frame.height, 420)
    }

    func testListRowOpensBesideTheRowAndStaysOnScreen() {
        let row = CGRect(x: 0, y: 700, width: 260, height: 26)
        let result = place(.listRow, row, height: 500)
        XCTAssertEqual(result.frame.minX, row.maxX + ControllerMenuPlacement.gap)
        // Nach oben geschoben, damit die Karte über der Legende endet.
        XCTAssertEqual(result.frame.maxY, window.maxY - ControllerMenuPlacement.margin - legend)
        XCTAssertFalse(result.scrolls)
    }

    func testListRowNearTheRightEdgeGoesLeft() {
        let row = CGRect(x: 950, y: 100, width: 240, height: 26)
        let result = place(.listRow, row, height: 200)
        XCTAssertEqual(result.frame.maxX, row.minX - ControllerMenuPlacement.gap)
    }

    /// Kleines Fenster mit langem Menü: Die Karte füllt die Höhe und scrollt.
    func testSmallWindowScrollsInsideTheCard() {
        let small = CGRect(x: 0, y: 0, width: 420, height: 360)
        let header = CGRect(x: 0, y: 50, width: 420, height: 34)
        let result = place(.header, header, height: 700, container: small)
        XCTAssertTrue(result.scrolls)
        XCTAssertGreaterThanOrEqual(result.frame.minY, small.minY + ControllerMenuPlacement.margin)
        XCTAssertLessThanOrEqual(result.frame.maxY, small.maxY - ControllerMenuPlacement.margin - legend)
        XCTAssertGreaterThanOrEqual(result.frame.minX, ControllerMenuPlacement.margin)
        XCTAssertLessThanOrEqual(result.frame.maxX, small.maxX - ControllerMenuPlacement.margin)
    }

    func testNarrowWindowShrinksTheCard() {
        let narrow = CGRect(x: 0, y: 0, width: 240, height: 600)
        let result = place(.header, CGRect(x: 0, y: 40, width: 240, height: 30), height: 300, container: narrow)
        XCTAssertEqual(result.frame.width, 240 - 2 * ControllerMenuPlacement.margin)
        XCTAssertEqual(result.frame.minX, ControllerMenuPlacement.margin)
    }

    func testWithoutAnchorBottomCenterAboveTheLegend() {
        let result = place(nil, height: 300)
        XCTAssertEqual(result.frame.midX, window.midX)
        XCTAssertEqual(result.frame.maxY, window.maxY - ControllerMenuPlacement.margin - legend)
    }

    func testListBeatsTileBeatsHeader() {
        XCTAssertEqual(ControllerMenuPlacement.Anchor.preferred([.header, .tile, .listRow]), .listRow)
        XCTAssertEqual(ControllerMenuPlacement.Anchor.preferred([.header, .tile]), .tile)
        XCTAssertNil(ControllerMenuPlacement.Anchor.preferred([]))
    }

    /// Die volle Höhe ergibt sich aus festen Zeilenhöhen (kein Messen).
    @MainActor
    func testCardHeightCountsHeadingsAndSeparators() {
        typealias Metrics = ControllerMenuCardMetrics
        let rows = [
            ControllerMenuRow(id: "a", title: "A", groupHeading: "X"),
            ControllerMenuRow(id: "b", title: "B"),
            ControllerMenuRow(id: "c", title: "C", startsGroup: true),
        ]
        XCTAssertEqual(Metrics.listHeight(rows),
                       2 * Metrics.listPadding + 3 * Metrics.rowHeight + Metrics.headingHeight + Metrics.separatorHeight)
    }
}

/// Kleines Fenster: nur ganze Zeilen, Markierung mit Nachbarn (Nachbesserung
/// nach der Freigabe der Menü-Karte).
final class ControllerMenuWindowTests: XCTestCase {
    func testEverythingFits() {
        XCTAssertEqual(ControllerMenuWindow.range(heights: [28, 28, 28], selected: 1, available: 100), 0..<3)
    }

    func testOnlyWholeRowsAroundTheSelection() {
        let heights: [CGFloat] = Array(repeating: 28, count: 20)
        let range = ControllerMenuWindow.range(heights: heights, selected: 10, available: 150)
        XCTAssertEqual(range.count, 5, "5 × 28 = 140 passt, 6 nicht")
        XCTAssertTrue(range.contains(10))
        XCTAssertEqual(range, 8..<13, "Markierung in der Mitte")
    }

    func testAtTheEdgesTheWindowStaysFull() {
        let heights: [CGFloat] = Array(repeating: 28, count: 20)
        XCTAssertEqual(ControllerMenuWindow.range(heights: heights, selected: 0, available: 150), 0..<5)
        XCTAssertEqual(ControllerMenuWindow.range(heights: heights, selected: 19, available: 150), 15..<20)
    }

    func testRowsWithHeadingsCountTheirHeading() {
        let heights: [CGFloat] = [50, 28, 28, 50, 28, 28]
        let range = ControllerMenuWindow.range(heights: heights, selected: 3, available: 110)
        XCTAssertLessThanOrEqual(range.map { heights[$0] }.reduce(0, +), 110)
        XCTAssertTrue(range.contains(3))
    }
}

/// Woran die Karte hängt (Review Runde 5): Die markierte Zeile trägt sie nur,
/// wenn das Menü ihr gilt; sonst Kopf bzw. Kachel des ausgewählten Chats.
final class ControllerMenuAnchorRuleTests: XCTestCase {
    private let selected = UUID()
    private let other = UUID()

    private func setup(target: SidebarNavigationRow?) -> ControllerMenuSetup {
        ControllerMenuSetup(sessionID: target?.sessionID, target: target, chat: ControllerChatActionInfo(title: "Chat"))
    }

    func testProjectRowMarkedMenuHangsAtTheSelectedChat() {
        // Projekt-Zeile markiert: Das Menü gilt dem ausgewählten Chat.
        let menu = setup(target: .chat(selected))
        XCTAssertFalse(ControllerMenuPlacement.listRowCarriesMenu(menu, row: .project(UUID())))
        XCTAssertTrue(ControllerMenuPlacement.chatCarriesMenu(menu, sessionID: selected))
        XCTAssertFalse(ControllerMenuPlacement.chatCarriesMenu(menu, sessionID: other))
    }

    func testMarkedChatRowCarriesItsMenu() {
        let row = SidebarNavigationRow.workspaceChat(session: other, workspace: UUID())
        let menu = setup(target: row)
        XCTAssertTrue(ControllerMenuPlacement.listRowCarriesMenu(menu, row: row))
        XCTAssertFalse(ControllerMenuPlacement.listRowCarriesMenu(menu, row: .chat(other)), "andere Zeile desselben Chats")
        XCTAssertFalse(ControllerMenuPlacement.chatCarriesMenu(menu, sessionID: selected))
        XCTAssertEqual(ControllerMenuPlacement.Anchor.preferred([.listRow, .header]), .listRow)
    }

    func testClosedMenuOrNoChatCarriesNothing() {
        XCTAssertFalse(ControllerMenuPlacement.listRowCarriesMenu(nil, row: .chat(selected)))
        XCTAssertFalse(ControllerMenuPlacement.chatCarriesMenu(nil, sessionID: selected))
        XCTAssertFalse(ControllerMenuPlacement.chatCarriesMenu(setup(target: nil), sessionID: nil))
    }
}
