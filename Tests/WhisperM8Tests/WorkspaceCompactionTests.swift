import XCTest
@testable import WhisperM8

/// Prueft das Verdichten beim Entfernen.
///
/// Der Kern ist nicht „es wird kleiner", sondern **die Reihenfolge bleibt**:
/// Wer einen Chat aus der Mitte entfernt, sucht die uebrigen dort, wo sie
/// vorher relativ zueinander standen. Wuerde umsortiert, waere jedes
/// Entfernen eine Ueberraschung.
final class WorkspaceCompactionTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private func workspace(slots: [UUID?], capacity: Int) -> AgentGridWorkspace {
        AgentGridWorkspace(name: "Test", slots: slots, capacity: capacity)
    }

    // MARK: - Verdichten

    func testRemovingFromTheMiddleClosesTheGap() {
        let ws = workspace(slots: [a, b, c, d], capacity: 4)
        let (result, removed) = WorkspaceSlotOps.remove(b, from: ws)

        XCTAssertTrue(removed)
        XCTAssertEqual(result.slots.compactMap { $0 }, [a, c, d],
                       "Reihenfolge der uebrigen bleibt erhalten")
        XCTAssertNil(result.slots.first { $0 == nil } ?? nil,
                     "kein Loch zwischen den belegten Slots")
    }

    func testCapacityFallsToTheSmallestFittingStage() {
        let ws = workspace(slots: [a, b, c, d], capacity: 4)
        let (result, _) = WorkspaceSlotOps.remove(d, from: ws)

        // 3 Chats passen in Stufe 3 — die 4er-Stufe wird nicht gehalten.
        XCTAssertEqual(result.capacity, 3)
        XCTAssertEqual(result.slots.compactMap { $0 }, [a, b, c])
    }

    func testStageDropsStepByStepDownToTwo() {
        var ws = workspace(slots: [a, b, c, d], capacity: 4)
        ws = WorkspaceSlotOps.remove(d, from: ws).workspace
        XCTAssertEqual(ws.capacity, 3)
        ws = WorkspaceSlotOps.remove(c, from: ws).workspace
        XCTAssertEqual(ws.capacity, 2)
    }

    /// Die kleinste Stufe ist der Boden: Ein leerer Workspace ohne Slots
    /// haette keine Drop-Ziele mehr und liesse sich nicht wieder fuellen.
    func testEmptyWorkspaceKeepsTheSmallestStage() {
        var ws = workspace(slots: [a, b], capacity: 2)
        ws = WorkspaceSlotOps.remove(a, from: ws).workspace
        ws = WorkspaceSlotOps.remove(b, from: ws).workspace

        XCTAssertEqual(ws.capacity, 2, "kleinste Stufe bleibt")
        XCTAssertTrue(ws.occupiedSessionIDs.isEmpty)
        XCTAssertEqual(ws.slots.count, 2, "zwei leere Drop-Ziele bleiben sichtbar")
    }

    func testFractionsStayValidAfterStageChange() {
        let ws = workspace(slots: [a, b, c, d], capacity: 4)
        let (result, _) = WorkspaceSlotOps.remove(d, from: ws)

        let spalten = AgentGridWorkspace.columns(forCapacity: result.capacity)
        let zeilen = AgentGridWorkspace.rows(forCapacity: result.capacity)
        XCTAssertEqual(result.columnFractions.count, spalten,
                       "Gewichte muessen zur neuen Spaltenzahl passen")
        XCTAssertEqual(result.rowFractions.count, zeilen)
        XCTAssertEqual(result.columnFractions.reduce(0, +), 1.0, accuracy: 0.001)
        XCTAssertEqual(result.rowFractions.reduce(0, +), 1.0, accuracy: 0.001)
    }

    // MARK: - Abschaltbar

    func testWithoutCompactingTheHoleRemains() {
        let ws = workspace(slots: [a, b, c, d], capacity: 4)
        let (result, removed) = WorkspaceSlotOps.remove(b, from: ws, compacting: false)

        XCTAssertTrue(removed)
        XCTAssertEqual(result.capacity, 4, "Stufe bleibt")
        XCTAssertEqual(result.slots[1], nil, "das Loch bleibt genau dort stehen")
        XCTAssertEqual(result.slots[2], c, "nichts rueckt nach")
    }

    // MARK: - Unveraendert

    func testRemovingUnknownSessionChangesNothing() {
        let ws = workspace(slots: [a, b], capacity: 2)
        let (result, removed) = WorkspaceSlotOps.remove(UUID(), from: ws)

        XCTAssertFalse(removed)
        XCTAssertEqual(result, ws)
    }

    func testFullWorkspaceInFittingStageIsUntouched() {
        let ws = workspace(slots: [a, b], capacity: 2)
        XCTAssertEqual(WorkspaceSlotOps.compacted(ws), ws)
    }

    /// Ein Workspace mit Loechern wird auch ohne Entfernen aufgeraeumt —
    /// wichtig fuer Bestandsdaten, die vor dieser Aenderung entstanden sind.
    func testExistingHolesAreClosedOnCompaction() {
        let ws = workspace(slots: [a, nil, c, nil], capacity: 4)
        let result = WorkspaceSlotOps.compacted(ws)

        XCTAssertEqual(result.slots.compactMap { $0 }, [a, c])
        XCTAssertEqual(result.capacity, 2)
    }
}
