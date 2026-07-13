import Foundation
import XCTest
@testable import WhisperM8

/// Pure Slot-Operationen (Testmatrix aus der Robustheits-Spez 14d92786).
final class WorkspaceSlotOpsTests: XCTestCase {
    private func workspace(slots: [UUID?], capacity: Int) -> AgentGridWorkspace {
        AgentGridWorkspace(slots: slots, capacity: capacity)
    }

    // MARK: - Add ohne Ziel

    func testAddUsesFirstFreeSlotWithoutReordering() {
        let a = UUID(); let b = UUID(); let new = UUID()
        let (updated, result) = WorkspaceSlotOps.add(
            new, to: workspace(slots: [a, nil, b, nil], capacity: 4)
        )
        XCTAssertEqual(result, .added(slotIndex: 1, grewTo: nil))
        XCTAssertEqual(updated.slots, [a, new, b, nil])
    }

    func testAddExistingSessionWithoutTargetIsNoOp() {
        let a = UUID()
        let original = workspace(slots: [nil, a], capacity: 2)
        let (updated, result) = WorkspaceSlotOps.add(a, to: original)
        XCTAssertEqual(result, .alreadyMember(slotIndex: 1))
        XCTAssertEqual(updated, original)
    }

    // MARK: - Gezielte Platzierung

    func testTargetedAddInsertsIntoEmptySlot() {
        let a = UUID(); let new = UUID()
        let (updated, result) = WorkspaceSlotOps.add(
            new, to: workspace(slots: [a, nil], capacity: 2), at: 1
        )
        XCTAssertEqual(result, .added(slotIndex: 1, grewTo: nil))
        XCTAssertEqual(updated.slots, [a, new])
    }

    func testTargetedAddReplacesOccupiedSlot() {
        let a = UUID(); let b = UUID(); let new = UUID()
        let (updated, result) = WorkspaceSlotOps.add(
            new, to: workspace(slots: [a, b], capacity: 2), at: 1
        )
        XCTAssertEqual(result, .replaced(slotIndex: 1, displaced: b))
        XCTAssertEqual(updated.slots, [a, new])
    }

    func testTargetedAddOfExistingMemberSwapsSlots() {
        let a = UUID(); let b = UUID()
        let (updated, result) = WorkspaceSlotOps.add(
            a, to: workspace(slots: [a, b], capacity: 2), at: 1
        )
        XCTAssertEqual(result, .swapped(from: 0, to: 1))
        XCTAssertEqual(updated.slots, [b, a], "Tausch statt Duplikat")
    }

    func testTargetedAddToInvalidSlotIsRejected() {
        let original = workspace(slots: [UUID(), nil], capacity: 2)
        let (updated, result) = WorkspaceSlotOps.add(UUID(), to: original, at: 7)
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(updated, original)
    }

    // MARK: - Auto-Wachsen

    func testAutoGrowClimbsAllStages() {
        for (from, to) in [(2, 3), (3, 4), (4, 6), (6, 9)] {
            let ids = (0 ..< from).map { _ in UUID() }
            let new = UUID()
            let (updated, result) = WorkspaceSlotOps.add(
                new, to: workspace(slots: ids.map { $0 }, capacity: from)
            )
            XCTAssertEqual(result, .added(slotIndex: from, grewTo: to),
                           "voll bei \(from) → wächst auf \(to), neuer Chat in den ersten neuen Slot")
            XCTAssertEqual(updated.capacity, to)
            XCTAssertEqual(updated.slots.prefix(from).compactMap { $0 }, ids,
                           "bestehende Positionen exakt erhalten")
            XCTAssertEqual(updated.slots[from], new)
        }
    }

    func testFullNineWorkspaceRejectsUntargetedAdd() {
        let ids = (0 ..< 9).map { _ in UUID() }
        let original = workspace(slots: ids.map { $0 }, capacity: 9)
        let (updated, result) = WorkspaceSlotOps.add(UUID(), to: original)
        XCTAssertEqual(result, .full)
        XCTAssertEqual(updated, original, "kein State-Change")
    }

    func testFullNineWorkspaceStillAllowsTargetedReplace() {
        let ids = (0 ..< 9).map { _ in UUID() }
        let new = UUID()
        let (updated, result) = WorkspaceSlotOps.add(
            new, to: workspace(slots: ids.map { $0 }, capacity: 9), at: 4
        )
        XCTAssertEqual(result, .replaced(slotIndex: 4, displaced: ids[4]))
        XCTAssertEqual(updated.slots[4], new)
    }

    // MARK: - Entfernen / Verschieben / Tauschen

    func testRemoveLeavesNilAtOriginalIndex() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let (updated, removed) = WorkspaceSlotOps.remove(
            b, from: workspace(slots: [a, b, c], capacity: 3)
        )
        XCTAssertTrue(removed)
        XCTAssertEqual(updated.slots, [a, nil, c], "Nachbarn unverändert, nichts rückt nach")
    }

    func testRemoveDoesNotAutoShrink() {
        let a = UUID()
        var slots: [UUID?] = Array(repeating: nil, count: 9)
        slots[3] = a
        let (updated, removed) = WorkspaceSlotOps.remove(
            a, from: workspace(slots: slots, capacity: 9)
        )
        XCTAssertTrue(removed)
        XCTAssertEqual(updated.capacity, 9, "nie automatisch schrumpfen")
    }

    func testRemoveUnknownSessionIsNoOp() {
        let original = workspace(slots: [UUID(), nil], capacity: 2)
        let (updated, removed) = WorkspaceSlotOps.remove(UUID(), from: original)
        XCTAssertFalse(removed)
        XCTAssertEqual(updated, original)
    }

    func testMoveSlotMovesIntoEmptyTarget() {
        let a = UUID()
        let (updated, moved) = WorkspaceSlotOps.moveSlot(
            in: workspace(slots: [a, nil, nil], capacity: 3), from: 0, to: 2
        )
        XCTAssertTrue(moved)
        XCTAssertEqual(updated.slots, [nil, nil, a])
    }

    func testMoveSlotRejectsOccupiedTarget() {
        let a = UUID(); let b = UUID()
        let original = workspace(slots: [a, b], capacity: 2)
        let (updated, moved) = WorkspaceSlotOps.moveSlot(in: original, from: 0, to: 1)
        XCTAssertFalse(moved, "belegte Ziele gehen über swapSlots")
        XCTAssertEqual(updated, original)
    }

    func testMoveSlotRejectsInvalidOrEmptySource() {
        let original = workspace(slots: [nil, UUID()], capacity: 2)
        XCTAssertFalse(WorkspaceSlotOps.moveSlot(in: original, from: 0, to: 1).moved, "leere Quelle")
        XCTAssertFalse(WorkspaceSlotOps.moveSlot(in: original, from: 9, to: 0).moved, "ungültige Quelle")
        XCTAssertFalse(WorkspaceSlotOps.moveSlot(in: original, from: 1, to: 1).moved, "gleicher Index")
    }

    func testSwapSlotsExchangesTwoSessions() {
        let a = UUID(); let b = UUID()
        let (updated, swapped) = WorkspaceSlotOps.swapSlots(
            in: workspace(slots: [a, b], capacity: 2), 0, 1
        )
        XCTAssertTrue(swapped)
        XCTAssertEqual(updated.slots, [b, a])
    }

    func testSwapWithNilBehavesAsStableMove() {
        let a = UUID()
        let (updated, swapped) = WorkspaceSlotOps.swapSlots(
            in: workspace(slots: [a, nil], capacity: 2), 0, 1
        )
        XCTAssertTrue(swapped)
        XCTAssertEqual(updated.slots, [nil, a])
    }

    func testSwapSameOrInvalidIndexIsNoOp() {
        let original = workspace(slots: [UUID(), UUID()], capacity: 2)
        XCTAssertFalse(WorkspaceSlotOps.swapSlots(in: original, 1, 1).swapped)
        XCTAssertFalse(WorkspaceSlotOps.swapSlots(in: original, 0, 5).swapped)
    }

    // MARK: - Kapazität

    func testCapacityGrowPadsWithoutMovingExistingSlots() {
        let a = UUID(); let b = UUID()
        let (updated, result) = WorkspaceSlotOps.setCapacity(
            of: workspace(slots: [a, b], capacity: 2), to: 6
        )
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(updated.slots, [a, b, nil, nil, nil, nil])
    }

    func testCapacityShrinkReportsTailEvictionsInOrder() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let evicted = WorkspaceSlotOps.previewCapacityChange(
            of: workspace(slots: ids.map { $0 }, capacity: 4), to: 2
        )
        XCTAssertEqual(evicted, [ids[2], ids[3]], "Slot-Reihenfolge")
    }

    func testCapacityShrinkRequiresMatchingConfirmation() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let original = workspace(slots: ids.map { $0 }, capacity: 4)
        // Stale Bestätigung (Liste passt nicht mehr) → keine Mutation.
        let (updated, result) = WorkspaceSlotOps.setCapacity(
            of: original, to: 2, expectedEvictedSessionIDs: [ids[3]]
        )
        XCTAssertEqual(result, .confirmationRequired([ids[2], ids[3]]))
        XCTAssertEqual(updated, original)
    }

    func testConfirmedCapacityShrinkDropsOnlyTailSlots() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let (updated, result) = WorkspaceSlotOps.setCapacity(
            of: workspace(slots: ids.map { $0 }, capacity: 4),
            to: 2,
            expectedEvictedSessionIDs: [ids[2], ids[3]]
        )
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(updated.slots, [ids[0], ids[1]], "Prefix unverändert")
        XCTAssertEqual(updated.capacity, 2)
    }

    func testCapacityChangePreservesOrResetsFractionsPerAxis() {
        // 4 (2×2) → 6 (3×2): Spalten ändern sich (2→3, Reset), Zeilen
        // bleiben (2→2, erhalten).
        var original = workspace(slots: [], capacity: 4)
        original.columnFractions = [0.3, 0.7]
        original.rowFractions = [0.6, 0.4]
        let (updated, _) = WorkspaceSlotOps.setCapacity(of: original, to: 6)
        XCTAssertEqual(updated.columnFractions.count, 3)
        XCTAssertEqual(updated.columnFractions[0], 1.0 / 3.0, accuracy: 0.0001, "neue Achse gleichverteilt")
        XCTAssertEqual(updated.rowFractions, [0.6, 0.4], "unveränderte Achse bleibt")
    }

    func testCapacityGrowSixToNineKeepsColumnsResetsRows() {
        // 6 (3×2) → 9 (3×3): Spalten behalten ihre Gewichte (3→3),
        // Zeilen werden gleichverteilt neu initialisiert (2→3).
        var original = workspace(slots: [], capacity: 6)
        original.columnFractions = [0.2, 0.3, 0.5]
        original.rowFractions = [0.6, 0.4]
        let (updated, result) = WorkspaceSlotOps.setCapacity(of: original, to: 9)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(updated.columnFractions, [0.2, 0.3, 0.5], "unveränderte Achse bleibt")
        XCTAssertEqual(updated.rowFractions.count, 3)
        XCTAssertEqual(updated.rowFractions[0], 1.0 / 3.0, accuracy: 0.0001)
    }

    func testInvalidExplicitCapacityIsRejected() {
        let original = workspace(slots: [], capacity: 4)
        let (updated, result) = WorkspaceSlotOps.setCapacity(of: original, to: 5)
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(updated, original)
    }
}
