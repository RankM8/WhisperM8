import Foundation
import XCTest
@testable import WhisperM8

/// Auswahlmodus beim Verkleinern: Vorbelegung, Umschalten und die
/// Rekonziliation gegen eine von außen geänderte Belegung. Die Interaktion
/// selbst (Klick-Catcher, Overlays) ist wie Drag/Drop nicht unit-testbar.
final class GridShrinkSelectionTests: XCTestCase {
    private func makeSelection(
        candidates: [UUID], targetCapacity: Int = 2
    ) -> GridShrinkSelection {
        GridShrinkSelection(
            workspaceID: UUID(), targetCapacity: targetCapacity, candidates: candidates
        )
    }

    func testPreselectsFirstCandidatesUpToTargetCapacity() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let selection = makeSelection(candidates: ids)
        XCTAssertEqual(selection.orderedRetained, [ids[0], ids[1]])
        XCTAssertEqual(selection.orderedEvicted, [ids[2], ids[3]])
        XCTAssertTrue(selection.isCommitEnabled, "Vorbelegung ist sofort committbar")
    }

    func testToggleMovesBetweenRetainedAndEvicted() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let selection = makeSelection(candidates: ids)
        selection.toggle(ids[0])
        XCTAssertEqual(selection.orderedRetained, [ids[1]])
        XCTAssertEqual(selection.orderedEvicted, [ids[0], ids[2], ids[3]])
        selection.toggle(ids[3])
        XCTAssertEqual(selection.orderedRetained, [ids[1], ids[3]], "immer in Slot-Reihenfolge")
    }

    func testToggleIgnoresUnknownSession() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let selection = makeSelection(candidates: ids)
        selection.toggle(UUID())
        XCTAssertEqual(selection.orderedRetained, [ids[0], ids[1]])
    }

    /// Mehr behalten als Slots blockiert den Commit; weniger ist erlaubt.
    func testCommitGateAllowsFewerButNotMoreThanCapacity() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let selection = makeSelection(candidates: ids)
        selection.toggle(ids[2])
        XCTAssertFalse(selection.isCommitEnabled)
        XCTAssertEqual(selection.overflowCount, 1)

        selection.toggle(ids[0])
        selection.toggle(ids[1])
        XCTAssertTrue(selection.isCommitEnabled, "nur noch einer behalten — zulässig")
        XCTAssertEqual(selection.overflowCount, 0)
        XCTAssertEqual(selection.orderedRetained, [ids[2]])
    }

    func testRetentionSlotNumberFollowsSlotOrder() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let selection = makeSelection(candidates: ids, targetCapacity: 3)
        selection.toggle(ids[1]) // abwählen
        selection.toggle(ids[3]) // dazunehmen
        XCTAssertEqual(selection.retentionSlotNumber(of: ids[0]), 1)
        XCTAssertEqual(selection.retentionSlotNumber(of: ids[2]), 2)
        XCTAssertEqual(selection.retentionSlotNumber(of: ids[3]), 3)
        XCTAssertNil(selection.retentionSlotNumber(of: ids[1]), "verlässt den Workspace")
    }

    // MARK: - Rekonziliation

    func testReconcileDropsVanishedSessionsAndContinues() {
        let ids = (0 ..< 5).map { _ in UUID() }
        let selection = makeSelection(candidates: ids)
        selection.toggle(ids[4]) // markiert: 0, 1, 4
        XCTAssertEqual(
            selection.reconcile(withOccupied: [ids[0], ids[2], ids[3], ids[4]]), .continues
        )
        XCTAssertEqual(selection.orderedRetained, [ids[0], ids[4]], "ids[1] ist weg")
        XCTAssertEqual(selection.orderedEvicted, [ids[2], ids[3]])
    }

    /// Neu hinzugekommene starten unmarkiert — sie sind an der Pane als
    /// „verlässt" ausgewiesen, verschwinden also nie stillschweigend.
    func testReconcileAddsNewCandidatesUnmarked() {
        let ids = (0 ..< 3).map { _ in UUID() }
        let newcomer = UUID()
        let selection = makeSelection(candidates: ids)
        XCTAssertEqual(
            selection.reconcile(withOccupied: ids + [newcomer]), .continues
        )
        XCTAssertEqual(selection.orderedRetained, [ids[0], ids[1]])
        XCTAssertTrue(selection.orderedEvicted.contains(newcomer))
    }

    func testReconcileReportsNoLongerNeededWhenEverythingFits() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let selection = makeSelection(candidates: ids)
        XCTAssertEqual(
            selection.reconcile(withOccupied: [ids[0], ids[3]]), .noLongerNeeded
        )
    }

    func testReconcileReportsObsoleteWhenWorkspaceEmpties() {
        let ids = (0 ..< 4).map { _ in UUID() }
        let selection = makeSelection(candidates: ids)
        XCTAssertEqual(selection.reconcile(withOccupied: []), .obsolete)
    }
}
