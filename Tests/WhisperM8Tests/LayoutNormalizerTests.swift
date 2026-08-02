import XCTest
@testable import WhisperM8

/// Prueft die Invarianten, indem jede absichtlich VERLETZT wird.
///
/// Ein Test, der nur gueltige Zustaende durchreicht, prueft nichts — er wuerde
/// auch bestehen, wenn der Normalisierer nichts taete. Deshalb geht hier in
/// jeden Test ein kaputtes Layout hinein.
final class LayoutNormalizerTests: XCTestCase {
    private let sessionA = UUID()
    private let sessionB = UUID()
    private let sessionC = UUID()

    // MARK: - Invariante 1: keine leeren Zellen

    func testEmptyCellsAreRemoved() {
        let layout = WorkspaceLayout(cells: [
            WorkspaceLayout.Cell(sessions: [], active: nil),
            WorkspaceLayout.Cell(session: sessionA),
        ])
        let result = LayoutNormalizer.normalize(layout)
        XCTAssertEqual(result.cells.count, 1)
        XCTAssertEqual(result.cells.first?.sessions, [sessionA])
    }

    /// Der Kern der Beschwerde „muss ich klein machen": Wird der letzte Chat
    /// entfernt, darf kein Loch zurueckbleiben.
    func testLayoutWithOnlyEmptyCellsBecomesEmpty() {
        let layout = WorkspaceLayout(cells: [
            WorkspaceLayout.Cell(sessions: [], active: nil),
            WorkspaceLayout.Cell(sessions: [], active: nil),
        ])
        XCTAssertTrue(LayoutNormalizer.normalize(layout).cells.isEmpty)
    }

    // MARK: - Invariante 2: active liegt in sessions

    func testActiveOutsideSessionsIsRepaired() {
        let fremd = UUID()
        var cell = WorkspaceLayout.Cell(sessions: [sessionA, sessionB])
        cell.active = fremd   // zeigt auf einen Chat, den die Zelle nicht hat
        let result = LayoutNormalizer.normalize(WorkspaceLayout(cells: [cell]))
        XCTAssertEqual(result.cells.first?.active, sessionA)
    }

    // MARK: - Invariante 3: ein Chat nur einmal je Layout

    func testDuplicateSessionAcrossCellsKeepsFirst() {
        let layout = WorkspaceLayout(cells: [
            WorkspaceLayout.Cell(session: sessionA),
            WorkspaceLayout.Cell(sessions: [sessionA, sessionB]),
        ])
        let result = LayoutNormalizer.normalize(layout)
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertEqual(result.cells[0].sessions, [sessionA])
        XCTAssertEqual(result.cells[1].sessions, [sessionB], "Doppelter Eintrag muss weichen")
    }

    func testDuplicateSessionWithinOneCellIsDeduplicated() {
        let layout = WorkspaceLayout(cells: [
            WorkspaceLayout.Cell(sessions: [sessionA, sessionA, sessionB]),
        ])
        XCTAssertEqual(LayoutNormalizer.normalize(layout).cells.first?.sessions, [sessionA, sessionB])
    }

    func testDuplicateCellIDsGetFreshID() {
        let shared = UUID()
        let layout = WorkspaceLayout(cells: [
            WorkspaceLayout.Cell(id: shared, session: sessionA),
            WorkspaceLayout.Cell(id: shared, session: sessionB),
        ])
        let result = LayoutNormalizer.normalize(layout)
        XCTAssertEqual(result.cells.count, 2)
        XCTAssertNotEqual(result.cells[0].id, result.cells[1].id)
    }

    // MARK: - Invariante 4: Baum und Zellen stimmen ueberein

    func testTreeLeafWithoutCellIsPruned() {
        let cellA = WorkspaceLayout.Cell(session: sessionA)
        let verwaist = UUID()
        let layout = WorkspaceLayout(
            cells: [cellA],
            arrangement: .manual(.split(
                axis: .horizontal,
                children: [.leaf(cellID: cellA.id), .leaf(cellID: verwaist)],
                fractions: [0.5, 0.5]
            ))
        )
        let result = LayoutNormalizer.normalize(layout)
        XCTAssertEqual(result.arrangement.tree?.leafIDs, [cellA.id])
    }

    /// Eine Zelle, die im Baum fehlt, waere unsichtbar obwohl sie Mitglied ist.
    func testCellMissingFromTreeIsAppended() {
        let cellA = WorkspaceLayout.Cell(session: sessionA)
        let cellB = WorkspaceLayout.Cell(session: sessionB)
        let layout = WorkspaceLayout(
            cells: [cellA, cellB],
            arrangement: .manual(.leaf(cellID: cellA.id))   // B fehlt
        )
        let leaves = LayoutNormalizer.normalize(layout).arrangement.tree?.leafIDs ?? []
        XCTAssertEqual(Set(leaves), [cellA.id, cellB.id])
    }

    func testTreeWithoutAnyValidLeafFallsBackToAutomatic() {
        let layout = WorkspaceLayout(
            cells: [WorkspaceLayout.Cell(session: sessionA)],
            arrangement: .manual(.leaf(cellID: UUID()))
        )
        // Zeigt KEIN Blatt mehr auf eine existierende Zelle, ist der Baum
        // wertlos. Dann ist die automatische Anordnung richtig — einen Baum aus
        // den uebrigen Zellen zu konstruieren waere eine erfundene Absicht, die
        // der Nutzer nie geaeussert hat.
        let result = LayoutNormalizer.normalize(layout)
        XCTAssertTrue(result.arrangement.isAutomatic)
        XCTAssertEqual(result.cells.count, 1, "Die Zelle selbst bleibt erhalten")
    }

    func testSingleChildSplitIsCollapsed() {
        let cellA = WorkspaceLayout.Cell(session: sessionA)
        let layout = WorkspaceLayout(
            cells: [cellA],
            arrangement: .manual(.split(
                axis: .horizontal,
                children: [.leaf(cellID: cellA.id), .leaf(cellID: UUID())],
                fractions: [0.5, 0.5]
            ))
        )
        // Nach dem Entfernen des verwaisten Blatts bleibt ein Einzelkind —
        // das muss hochgezogen werden, sonst waechst der Baum bei jeder
        // Aenderung um eine sinnlose Ebene.
        if case .leaf = LayoutNormalizer.normalize(layout).arrangement.tree {
            // erwartet
        } else {
            XCTFail("Einzelkind haette hochgezogen werden muessen")
        }
    }

    // MARK: - Invariante 5: Fractions

    func testFractionsAreNormalizedToSumOne() {
        let result = LayoutNormalizer.normalizedFractions([2, 2], count: 2)
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 0.0001)
        XCTAssertEqual(result, [0.5, 0.5])
    }

    /// Flaechen mit Breite 0 oder NaN sind im alten Modell schon einmal
    /// aufgetreten — deshalb wird hier nicht vertraut, sondern gerechnet.
    func testInvalidFractionsFallBackToEqual() {
        XCTAssertEqual(LayoutNormalizer.normalizedFractions([.nan, .infinity], count: 2), [0.5, 0.5])
        XCTAssertEqual(LayoutNormalizer.normalizedFractions([0, 0], count: 2), [0.5, 0.5])
        XCTAssertEqual(LayoutNormalizer.normalizedFractions([-1, -2], count: 2), [0.5, 0.5])
    }

    func testFractionCountIsAdjustedToChildren() {
        XCTAssertEqual(LayoutNormalizer.normalizedFractions([0.5, 0.5], count: 3).count, 3)
        XCTAssertEqual(LayoutNormalizer.normalizedFractions([0.2, 0.3, 0.5], count: 2).count, 2)
    }

    // MARK: - Invariante 6: hidden nur bei abgeleiteten Layouts

    func testHiddenIsClearedForManualSource() {
        let layout = WorkspaceLayout(
            cells: [WorkspaceLayout.Cell(session: sessionA)],
            hidden: [sessionB],
            source: .manual
        )
        XCTAssertTrue(LayoutNormalizer.normalize(layout).hidden.isEmpty)
    }

    func testHiddenDropsSessionsThatAreMembers() {
        let layout = WorkspaceLayout(
            cells: [WorkspaceLayout.Cell(session: sessionA)],
            hidden: [sessionA, sessionB],
            source: .project(UUID())
        )
        // sessionA ist Mitglied — gleichzeitig ausgeblendet zu sein waere ein
        // Widerspruch.
        XCTAssertEqual(LayoutNormalizer.normalize(layout).hidden, [sessionB])
    }

    // MARK: - Bindungen

    func testBindingsToMissingSessionsAreDropped() {
        let layout = WorkspaceLayout(
            cells: [WorkspaceLayout.Cell(sessions: [sessionA, sessionB])],
            bindings: [sessionB: sessionA, sessionC: sessionA]
        )
        let result = LayoutNormalizer.normalize(layout)
        XCTAssertEqual(result.bindings, [sessionB: sessionA])
    }

    // MARK: - Idempotenz

    /// Zweimal normalisieren muss dasselbe ergeben wie einmal. Sonst wandert
    /// ein Layout bei jeder Aenderung weiter, ohne dass jemand etwas tut.
    func testNormalizeIsIdempotent() {
        let cellA = WorkspaceLayout.Cell(sessions: [sessionA, sessionA])
        let layout = WorkspaceLayout(
            cells: [cellA, WorkspaceLayout.Cell(sessions: [])],
            arrangement: .manual(.split(axis: .horizontal,
                                        children: [.leaf(cellID: cellA.id), .leaf(cellID: UUID())],
                                        fractions: [.nan, 3])),
            bindings: [sessionB: sessionC],
            hidden: [sessionA],
            source: .project(UUID())
        )
        let once = LayoutNormalizer.normalize(layout)
        let twice = LayoutNormalizer.normalize(once)
        XCTAssertEqual(once, twice)
    }
}
