import XCTest
@testable import WhisperM8

/// Prueft, wo Trenner liegen und was ein Zug an ihnen bewirkt.
///
/// Der Griff muss **auf dem Spalt** sitzen, den man sieht. Weicht die Rechnung
/// hier von der in `LayoutGeometry.place` ab, greift der Nutzer ins Leere —
/// ein Fehler, der sich erst mit der Maus zeigt und deshalb hier festgenagelt
/// wird. Der zweite Punkt: Ein Zug darf nur seine beiden Nachbarn bewegen,
/// sonst wandert beim Ziehen eines Trenners das halbe Layout.
final class LayoutDividerGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func cells(_ count: Int) -> [WorkspaceLayout.Cell] {
        (0..<count).map { _ in WorkspaceLayout.Cell(session: UUID()) }
    }

    private func splitLayout(
        axis: WorkspaceLayout.Axis,
        cells liste: [WorkspaceLayout.Cell],
        fractions: [Double]
    ) -> WorkspaceLayout {
        WorkspaceLayout(
            cells: liste,
            arrangement: .manual(.split(
                axis: axis,
                children: liste.map { .leaf(cellID: $0.id) },
                fractions: fractions
            ))
        )
    }

    // MARK: - Wo die Trenner liegen

    func testAutomaticArrangementHasNoDividers() {
        let layout = WorkspaceLayout(cells: cells(4), arrangement: .automatic)
        XCTAssertTrue(LayoutGeometry.dividers(for: layout, in: bounds).isEmpty)
    }

    func testHorizontalSplitHasOneDividerBetweenTwoCells() {
        let liste = cells(2)
        let layout = splitLayout(axis: .horizontal, cells: liste, fractions: [0.5, 0.5])

        let trenner = LayoutGeometry.dividers(for: layout, in: bounds)

        XCTAssertEqual(trenner.count, 1)
        XCTAssertEqual(trenner[0].leadingCellID, liste[0].id)
        XCTAssertEqual(trenner[0].trailingCellID, liste[1].id)
        XCTAssertEqual(trenner[0].axis, .horizontal)
        XCTAssertEqual(trenner[0].available, bounds.width)
    }

    /// Der Griff muss mittig auf der Kante sitzen, die `frames` erzeugt.
    func testDividerHandleSitsOnTheVisibleSeam() {
        let liste = cells(2)
        let layout = splitLayout(axis: .horizontal, cells: liste, fractions: [0.3, 0.7])

        let frames = LayoutGeometry.frames(for: layout, in: bounds)
        let trenner = LayoutGeometry.dividers(for: layout, in: bounds)

        let kante = frames[liste[0].id]!.maxX
        XCTAssertEqual(trenner[0].rect.midX, kante, accuracy: 0.51)
        XCTAssertEqual(trenner[0].rect.width, LayoutGeometry.dividerHandleThickness)
        // Ueber die volle Hoehe greifbar.
        XCTAssertEqual(trenner[0].rect.height, bounds.height, accuracy: 0.51)
    }

    func testVerticalSplitHandleSpansFullWidth() {
        let liste = cells(2)
        let layout = splitLayout(axis: .vertical, cells: liste, fractions: [0.5, 0.5])

        let trenner = LayoutGeometry.dividers(for: layout, in: bounds)

        XCTAssertEqual(trenner.count, 1)
        XCTAssertEqual(trenner[0].axis, .vertical)
        XCTAssertEqual(trenner[0].rect.width, bounds.width, accuracy: 0.51)
        XCTAssertEqual(trenner[0].rect.height, LayoutGeometry.dividerHandleThickness)
        XCTAssertEqual(trenner[0].available, bounds.height)
    }

    func testThreeChildrenYieldTwoDividers() {
        let liste = cells(3)
        let layout = splitLayout(axis: .horizontal, cells: liste, fractions: [0.33, 0.33, 0.34])

        XCTAssertEqual(LayoutGeometry.dividers(for: layout, in: bounds).count, 2)
    }

    /// Verschachtelt: Der aeussere Split liefert seinen Trenner, der innere
    /// seinen — und der innere bezieht sich auf die Laenge SEINER Achse.
    func testNestedSplitReportsDividersOnBothLevels() {
        let liste = cells(3)
        let layout = WorkspaceLayout(
            cells: liste,
            arrangement: .manual(.split(
                axis: .horizontal,
                children: [
                    .leaf(cellID: liste[0].id),
                    .split(
                        axis: .vertical,
                        children: [.leaf(cellID: liste[1].id), .leaf(cellID: liste[2].id)],
                        fractions: [0.5, 0.5]
                    ),
                ],
                fractions: [0.5, 0.5]
            ))
        )

        let trenner = LayoutGeometry.dividers(for: layout, in: bounds)

        XCTAssertEqual(trenner.count, 2)
        XCTAssertEqual(trenner.filter { $0.axis == .horizontal }.count, 1)
        let innen = trenner.first { $0.axis == .vertical }
        XCTAssertEqual(innen?.leadingCellID, liste[1].id)
        XCTAssertEqual(innen?.trailingCellID, liste[2].id)
        // Der innere Trenner teilt nur die Hoehe seines Teilbereichs.
        XCTAssertEqual(innen?.available, bounds.height)
    }

    // MARK: - Was ein Zug bewirkt

    func testDragMovesTheBoundaryBetweenNeighbours() {
        let liste = cells(2)
        let layout = splitLayout(axis: .horizontal, cells: liste, fractions: [0.5, 0.5])

        // 100 Punkte nach rechts auf 1000 Punkten = 10 Prozentpunkte.
        let ergebnis = LayoutDividerApply.apply(
            leadingCellID: liste[0].id,
            trailingCellID: liste[1].id,
            offset: 100,
            available: 1000,
            in: layout
        )

        guard case let .manual(.split(_, _, fractions)) = ergebnis.arrangement else {
            return XCTFail("Anordnung muss manuell bleiben")
        }
        XCTAssertEqual(fractions[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(fractions[1], 0.4, accuracy: 0.001)
    }

    /// Der wichtigste Fall: Bei drei Flaechen darf die dritte unberuehrt
    /// bleiben, wenn man den ersten Trenner zieht.
    func testDragLeavesUninvolvedSiblingsUntouched() {
        let liste = cells(3)
        let layout = splitLayout(
            axis: .horizontal, cells: liste, fractions: [1.0 / 3, 1.0 / 3, 1.0 / 3]
        )

        let ergebnis = LayoutDividerApply.apply(
            leadingCellID: liste[0].id,
            trailingCellID: liste[1].id,
            offset: 90,
            available: 900,
            in: layout
        )

        guard case let .manual(.split(_, _, fractions)) = ergebnis.arrangement else {
            return XCTFail("Anordnung muss manuell bleiben")
        }
        XCTAssertEqual(fractions[2], 1.0 / 3, accuracy: 0.001, "Dritte Flaeche darf sich nicht bewegen")
        XCTAssertEqual(fractions[0] + fractions[1], 2.0 / 3, accuracy: 0.001)
    }

    func testDragOnUnknownNeighboursLeavesLayoutUnchanged() {
        let liste = cells(2)
        let layout = splitLayout(axis: .horizontal, cells: liste, fractions: [0.5, 0.5])

        let ergebnis = LayoutDividerApply.apply(
            leadingCellID: UUID(),
            trailingCellID: UUID(),
            offset: 100,
            available: 1000,
            in: layout
        )

        XCTAssertEqual(ergebnis, LayoutNormalizer.normalize(layout))
    }

    func testDragOnAutomaticArrangementIsIgnored() {
        let layout = WorkspaceLayout(cells: cells(2), arrangement: .automatic)

        let ergebnis = LayoutDividerApply.apply(
            leadingCellID: layout.cells[0].id,
            trailingCellID: layout.cells[1].id,
            offset: 100,
            available: 1000,
            in: layout
        )

        XCTAssertTrue(ergebnis.arrangement.isAutomatic)
    }

    func testZeroOffsetChangesNothing() {
        let liste = cells(2)
        let layout = splitLayout(axis: .horizontal, cells: liste, fractions: [0.4, 0.6])

        let ergebnis = LayoutDividerApply.apply(
            leadingCellID: liste[0].id,
            trailingCellID: liste[1].id,
            offset: 0,
            available: 1000,
            in: layout
        )

        XCTAssertEqual(ergebnis, layout)
    }

    /// Auch ein Zug ueber die Kante hinaus darf keine Flaeche verschwinden
    /// lassen — die Mindestgroesse haelt.
    func testDragBeyondTheEdgeKeepsBothCellsVisible() {
        let liste = cells(2)
        let layout = splitLayout(axis: .horizontal, cells: liste, fractions: [0.5, 0.5])

        let ergebnis = LayoutDividerApply.apply(
            leadingCellID: liste[0].id,
            trailingCellID: liste[1].id,
            offset: 5000,
            available: 1000,
            in: layout
        )

        guard case let .manual(.split(_, _, fractions)) = ergebnis.arrangement else {
            return XCTFail("Anordnung muss manuell bleiben")
        }
        XCTAssertGreaterThan(fractions[1], 0, "Die rechte Flaeche darf nicht verschwinden")
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: 0.001)
    }
}
