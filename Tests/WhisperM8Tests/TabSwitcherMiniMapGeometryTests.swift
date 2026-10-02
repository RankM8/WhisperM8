import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import WhisperM8

/// Mini-Map-Geometrie des Ctrl+Tab-Switchers (Plan tab-switcher-workspace,
/// Slice S4). Kernfrage: zeigt die Mini-Map dasselbe Raster wie das Grid?
final class TabSwitcherMiniMapGeometryTests: XCTestCase {
    private let gridSize = CGSize(width: 1601, height: 1003)

    /// Ungleich verteilte Gewichte je Achse — zeigen, dass die Mini-Map die
    /// Spurmaße der Entity übernimmt statt gleichmäßig zu teilen.
    private func unevenFractions(count: Int) -> [Double] {
        switch count {
        case 1: return [1]
        case 2: return [0.62, 0.38]
        default: return [0.5, 0.3, 0.2]
        }
    }

    private func entity(capacity: Int) -> AgentGridWorkspace {
        AgentGridWorkspace(
            capacity: capacity,
            columnFractions: unevenFractions(count: AgentGridWorkspace.columns(forCapacity: capacity)),
            rowFractions: unevenFractions(count: AgentGridWorkspace.rows(forCapacity: capacity))
        )
    }

    /// Bildet den Renderer (`AgentGridSplitContainer.gridBody`) unabhängig von
    /// der Geometrie nach: VStack/HStack mit 1-pt-Abstand, nicht-letzte Blöcke
    /// mit fester Breite (Spuren + verschluckte Trennlinien), der letzte Block
    /// einer Zeile bzw. die letzte Zeile füllt den Rest.
    private func rendererRects(for entity: AgentGridWorkspace, in size: CGSize) -> [Int: CGRect] {
        let layout = AgentGridAutoLayout.forCapacity(entity.capacity)
        let colSizes = GridSplitResolver.trackSizes(total: size.width, fractions: entity.columnFractions)
        let rowSizes = GridSplitResolver.trackSizes(total: size.height, fractions: entity.rowFractions)
        var rects: [Int: CGRect] = [:]
        var y: CGFloat = 0
        for row in 0 ..< layout.rows {
            let height = row < layout.rows - 1
                ? rowSizes[row]
                : size.height - y
            let blocks = AgentGridSplitContainer<EmptyView>.blocks(inRow: row, layout: layout)
            var x: CGFloat = 0
            for (position, block) in blocks.enumerated() {
                let width: CGFloat
                if position < blocks.count - 1 {
                    width = block.tracks.reduce(CGFloat(0)) { $0 + colSizes[$1] } + CGFloat(block.tracks.count - 1)
                } else {
                    width = size.width - x
                }
                rects[block.slot] = CGRect(x: x, y: y, width: width, height: height)
                x += width + 1
            }
            y += height + 1
        }
        return rects
    }

    private func assertEqual(_ lhs: CGRect, _ rhs: CGRect, accuracy: CGFloat = 0.0001,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, "\(message) minX", file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, "\(message) minY", file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, "\(message) width", file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, "\(message) height", file: file, line: line)
    }

    // MARK: - Deckung mit dem Renderer

    func testUnscaledRectsMatchRendererForEveryCapacity() {
        for capacity in 2 ... 9 {
            let entity = entity(capacity: capacity)
            let expected = rendererRects(for: entity, in: gridSize)
            let actual = TabSwitcherMiniMapGeometry.slotRects(
                for: entity, gridSize: gridSize, targetSize: gridSize
            )
            XCTAssertEqual(actual.count, expected.count, "Kapazität \(capacity)")
            for slotRect in actual {
                guard let rendered = expected[slotRect.slot] else {
                    XCTFail("Kapazität \(capacity): Slot \(slotRect.slot) fehlt im Renderer")
                    continue
                }
                assertEqual(slotRect.rect, rendered, "Kapazität \(capacity), Slot \(slotRect.slot)")
            }
        }
    }

    func testScaledRectsMatchScaledRendererForEveryCapacity() {
        let target = TabSwitcherMiniMapGeometry.mapSize(contentSize: gridSize)
        let scale = target.width / gridSize.width
        XCTAssertEqual(target.height / gridSize.height, scale, accuracy: 0.0001, "einheitliche Skalierung")
        for capacity in 2 ... 9 {
            let entity = entity(capacity: capacity)
            let expected = rendererRects(for: entity, in: gridSize)
            let actual = TabSwitcherMiniMapGeometry.slotRects(
                for: entity, gridSize: gridSize, targetSize: target
            )
            XCTAssertEqual(actual.count, capacity, "Kapazität \(capacity)")
            for slotRect in actual {
                guard let rendered = expected[slotRect.slot] else {
                    XCTFail("Kapazität \(capacity): Slot \(slotRect.slot) fehlt im Renderer")
                    continue
                }
                let scaled = CGRect(
                    x: rendered.minX * scale, y: rendered.minY * scale,
                    width: rendered.width * scale, height: rendered.height * scale
                )
                assertEqual(slotRect.rect, scaled, "Kapazität \(capacity), Slot \(slotRect.slot)")
            }
        }
    }

    // MARK: - Kein Phantom-Slot

    func testNoPhantomSlotAndNoOverlap() {
        let target = CGSize(width: 700, height: 440)
        for capacity in 2 ... 9 {
            let rects = TabSwitcherMiniMapGeometry.slotRects(
                for: entity(capacity: capacity), gridSize: gridSize, targetSize: target
            )
            XCTAssertEqual(rects.map(\.slot), Array(0 ..< capacity), "Kapazität \(capacity): genau die Slots 0..<capacity")
            let bounds = CGRect(origin: .zero, size: target)
            for slotRect in rects {
                XCTAssertGreaterThan(slotRect.rect.width, 0, "Kapazität \(capacity), Slot \(slotRect.slot)")
                XCTAssertGreaterThan(slotRect.rect.height, 0, "Kapazität \(capacity), Slot \(slotRect.slot)")
                XCTAssertTrue(
                    bounds.insetBy(dx: -0.001, dy: -0.001).contains(slotRect.rect),
                    "Kapazität \(capacity), Slot \(slotRect.slot) ragt aus der Map"
                )
            }
            for (i, a) in rects.enumerated() {
                for b in rects[(i + 1)...] {
                    let overlap = a.rect.intersection(b.rect)
                    XCTAssertTrue(
                        overlap.isNull || overlap.width < 0.001 || overlap.height < 0.001,
                        "Kapazität \(capacity): Slots \(a.slot) und \(b.slot) überlappen"
                    )
                }
            }
            // Jede Zeile füllt die volle Breite — kein leerer Platz, auf dem
            // ein Phantom-Slot säße. Breite der Zeile = Map minus Trennlinien.
            let scale = target.width / gridSize.width
            for row in Set(rects.map(\.row)) {
                let inRow = rects.filter { $0.row == row }
                let gaps = CGFloat(inRow.count - 1) * GridSplitResolver.divider * scale
                let width = inRow.reduce(CGFloat(0)) { $0 + $1.rect.width } + gaps
                XCTAssertEqual(width, target.width, accuracy: 0.001, "Kapazität \(capacity), Zeile \(row)")
            }
        }
    }

    // MARK: - Gewichte

    func testUnevenFractionsShapeTheMap() {
        // Zwei Spalten 70/30 in einem 1001 pt breiten Grid: 700 + 1 + 300.
        let entity = AgentGridWorkspace(capacity: 2, columnFractions: [0.7, 0.3])
        let rects = TabSwitcherMiniMapGeometry.slotRects(
            for: entity,
            gridSize: CGSize(width: 1001, height: 600),
            targetSize: CGSize(width: 1001, height: 600)
        )
        XCTAssertEqual(rects[0].rect.width, 700)
        XCTAssertEqual(rects[1].rect.minX, 701)
        XCTAssertEqual(rects[1].rect.width, 300)
    }

    func testMinPaneClampIsResolvedInGridSpaceNotInMapSpace() {
        // In der kleinen Map-Fläche (300 pt) würde `trackSizes` wegen
        // minPane = 240 gleich verteilen. Gerechnet wird aber in der echten
        // Grid-Größe — das Verhältnis 70/30 bleibt in der Map erhalten.
        let entity = AgentGridWorkspace(capacity: 2, columnFractions: [0.7, 0.3])
        let rects = TabSwitcherMiniMapGeometry.slotRects(
            for: entity,
            gridSize: CGSize(width: 2001, height: 1000),
            targetSize: CGSize(width: 300, height: 150)
        )
        XCTAssertEqual(rects[0].rect.width / rects[1].rect.width, 0.7 / 0.3, accuracy: 0.01)
    }

    func testFractionsWithWrongCountFallBackToEqualLikeRenderer() {
        let rects = TabSwitcherMiniMapGeometry.slotRects(
            layout: .grid3x3,
            columnFractions: [0.9, 0.1],
            rowFractions: [],
            in: CGSize(width: 902, height: 902)
        )
        XCTAssertEqual(rects.map(\.rect.width), Array(repeating: 300, count: 9))
        XCTAssertEqual(rects.map(\.rect.height), Array(repeating: 300, count: 9))
    }

    // MARK: - Zwei Geometrie-Quellen

    /// Pfeiltasten (`GridFocusNavigator` über `cell(forSlot:)`) und Bild
    /// (`blocks(inRow:)`) müssen dieselben Zellen liefern — sonst springt der
    /// Fokus woanders hin, als die Mini-Map zeigt.
    func testFocusNavigatorCellsMatchRendererBlocks() {
        for capacity in 2 ... 9 {
            let layout = AgentGridAutoLayout.forCapacity(capacity)
            var blockCells: [Int: (row: Int, tracks: ClosedRange<Int>)] = [:]
            for row in 0 ..< layout.rows {
                for block in AgentGridSplitContainer<EmptyView>.blocks(inRow: row, layout: layout) {
                    XCTAssertNil(blockCells[block.slot], "Kapazität \(capacity): Slot \(block.slot) doppelt")
                    blockCells[block.slot] = (row, block.tracks)
                }
            }
            XCTAssertEqual(Set(blockCells.keys), Set(0 ..< layout.paneCount), "Kapazität \(capacity)")
            for slot in 0 ..< layout.paneCount {
                let cell = layout.cell(forSlot: slot)
                XCTAssertEqual(cell?.row, blockCells[slot]?.row, "Kapazität \(capacity), Slot \(slot): Zeile")
                XCTAssertEqual(cell?.cols, blockCells[slot]?.tracks, "Kapazität \(capacity), Slot \(slot): Spalten")
            }
            XCTAssertNil(layout.cell(forSlot: layout.paneCount), "Kapazität \(capacity): kein Phantom-Slot im Navigator")
        }
    }

    // MARK: - Größe der Mini-Map

    func testMapSizeIsSeventyPercentOfLargeContent() {
        let size = TabSwitcherMiniMapGeometry.mapSize(contentSize: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(size.width, 1120, accuracy: 0.001)
        XCTAssertEqual(size.height, 700, accuracy: 0.001)
    }

    func testMapSizeGrowsBeyondSeventyPercentForMinimumNinthTile() {
        // 70 % von 600 pt = 420 pt → 1/9-Kachel nur 140 pt breit. Die Map
        // wächst auf 450 pt (3 × 150), Seitenverhältnis bleibt.
        let size = TabSwitcherMiniMapGeometry.mapSize(contentSize: CGSize(width: 600, height: 400))
        XCTAssertEqual(size.width, 450, accuracy: 0.001)
        XCTAssertEqual(size.height, 300, accuracy: 0.001)
        XCTAssertEqual(
            TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: size.width / 3, height: size.height / 3)),
            .full
        )
    }

    func testMapSizeNeverExceedsContent() {
        let content = CGSize(width: 400, height: 180)
        let size = TabSwitcherMiniMapGeometry.mapSize(contentSize: content)
        XCTAssertEqual(size, content)
        // Hier reicht der Platz nicht: die 1/9-Kachel verliert die Stand-Zeile.
        XCTAssertEqual(
            TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: size.width / 3, height: size.height / 3)),
            .withoutActivity
        )
    }

    func testMapSizeOfEmptyContentIsZero() {
        XCTAssertEqual(TabSwitcherMiniMapGeometry.mapSize(contentSize: .zero), .zero)
    }

    // MARK: - Detailstufe

    func testTileDetailThresholds() {
        XCTAssertEqual(TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: 150, height: 72)), .full)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: 400, height: 200)), .full)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: 149, height: 200)), .withoutActivity)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: 400, height: 71)), .withoutActivity)
        // Dritte Stufe: auch die Dauer entfällt, Status + Titel bleiben.
        XCTAssertEqual(TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: 130, height: 52)), .withoutActivity)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: 129, height: 200)), .statusAndTitle)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.tileDetail(for: CGSize(width: 400, height: 51)), .statusAndTitle)
    }

    func testTileDetailStagesDropActivityBeforeDuration() {
        XCTAssertTrue(TabSwitcherTileDetail.full.showsActivity)
        XCTAssertTrue(TabSwitcherTileDetail.full.showsDuration)
        XCTAssertFalse(TabSwitcherTileDetail.withoutActivity.showsActivity)
        XCTAssertTrue(TabSwitcherTileDetail.withoutActivity.showsDuration)
        XCTAssertFalse(TabSwitcherTileDetail.statusAndTitle.showsActivity)
        XCTAssertFalse(TabSwitcherTileDetail.statusAndTitle.showsDuration)
    }

    // MARK: - Größe mit Chrome

    func testFittedMapSizeKeepsMapSizeWhenChromeFits() {
        let content = CGSize(width: 2000, height: 1200)
        let fitted = TabSwitcherMiniMapGeometry.fittedMapSize(
            contentSize: content, chrome: CGSize(width: 80, height: 134)
        )
        XCTAssertEqual(fitted, TabSwitcherMiniMapGeometry.mapSize(contentSize: content))
    }

    func testFittedMapSizeShrinksUniformlyWhenChromeDoesNotFit() {
        let content = CGSize(width: 600, height: 400)
        let chrome = CGSize(width: 80, height: 134)
        let fitted = TabSwitcherMiniMapGeometry.fittedMapSize(contentSize: content, chrome: chrome)
        XCTAssertLessThanOrEqual(fitted.width + chrome.width, content.width + 0.001)
        XCTAssertLessThanOrEqual(fitted.height + chrome.height, content.height + 0.001)
        // Seitenverhältnis des Content-Bereichs bleibt (keine Verzerrung).
        XCTAssertEqual(fitted.width / fitted.height, content.width / content.height, accuracy: 0.001)
    }

    func testFittedMapSizeIsZeroForEmptyContent() {
        XCTAssertEqual(
            TabSwitcherMiniMapGeometry.fittedMapSize(contentSize: .zero, chrome: CGSize(width: 80, height: 134)),
            .zero
        )
    }

    // MARK: - Räumliche Pfeil-Navigation

    private func workspace(capacity: Int, filled: Int) -> (AgentGridWorkspace, [UUID]) {
        let ids = (0 ..< filled).map { _ in UUID() }
        return (AgentGridWorkspace(slots: ids, capacity: capacity), ids)
    }

    func testSpatialTargetFollowsRowsAndColumns() {
        // 2×2: 0 1 / 2 3
        let (entity, s) = workspace(capacity: 4, filled: 4)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: s[0], direction: .right, in: entity, order: s), s[1])
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: s[0], direction: .down, in: entity, order: s), s[2])
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: s[3], direction: .up, in: entity, order: s), s[1])
        XCTAssertNil(TabSwitcherMiniMapGeometry.spatialTarget(from: s[1], direction: .right, in: entity, order: s),
                     "kein Wrap-around am Rand")
    }

    func testSpatialTargetHitsSpanningSlot() {
        // 3 = „2 oben + 1 breit": Slot 2 überdeckt beide Spalten.
        let (entity, s) = workspace(capacity: 3, filled: 3)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: s[1], direction: .down, in: entity, order: s), s[2])
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: s[2], direction: .up, in: entity, order: s), s[0])
    }

    func testSpatialTargetSkipsSlotsOutsideScope() {
        // 3×2: 0 1 2 / 3 4 5 — Slot 1 hält z. B. ein anderes Fenster (nicht im
        // Umfang), Slot 4 ist leer: beide werden in der Richtung übersprungen.
        var (entity, s) = workspace(capacity: 6, filled: 6)
        entity.slots[4] = nil
        let order = [s[0], s[2], s[3], s[5]]
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: s[0], direction: .right, in: entity, order: order), s[2])
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: s[3], direction: .right, in: entity, order: order), s[5])
        XCTAssertNil(TabSwitcherMiniMapGeometry.spatialTarget(from: s[2], direction: .left, in: entity, order: [s[2], s[3]]))
    }

    func testSpatialTargetWithoutHighlightStartsAtFirstTarget() {
        let (entity, s) = workspace(capacity: 4, filled: 4)
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: nil, direction: .right, in: entity, order: s), s[1])
        XCTAssertEqual(TabSwitcherMiniMapGeometry.spatialTarget(from: UUID(), direction: .down, in: entity, order: s), s[2])
    }
}
