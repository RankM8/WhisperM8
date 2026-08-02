import Foundation
import XCTest
@testable import WhisperM8

/// Drop-Auflösung der Drag-&-Drop-Matrix (Plan F7).
final class GridDropZoneResolverTests: XCTestCase {
    func testSameWorkspaceDragIntoEmptySlotIsMove() {
        let a = UUID()
        let ws = AgentGridWorkspace(slots: [a, nil], capacity: 2)
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: a, sourceWorkspaceID: ws.id, sourceSlotIndex: 0,
                targetSlot: 1, workspace: ws
            ),
            .moveSlot(from: 0, to: 1)
        )
    }

    func testSameWorkspaceDragOntoOccupiedPaneIsSwap() {
        let a = UUID(); let b = UUID()
        let ws = AgentGridWorkspace(slots: [a, b], capacity: 2)
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: a, sourceWorkspaceID: ws.id, sourceSlotIndex: 0,
                targetSlot: 1, workspace: ws
            ),
            .swapSlots(0, 1)
        )
    }

    func testDropOntoOwnSlotIsNoOp() {
        let a = UUID()
        let ws = AgentGridWorkspace(slots: [a, nil], capacity: 2)
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: a, sourceWorkspaceID: ws.id, sourceSlotIndex: 0,
                targetSlot: 0, workspace: ws
            ),
            .none
        )
        // Auch ohne Slot-Herkunft: Chat liegt schon im Ziel-Slot.
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: a, sourceWorkspaceID: nil, sourceSlotIndex: nil,
                targetSlot: 0, workspace: ws
            ),
            .none
        )
    }

    func testExternalSourceIsPlace() {
        let a = UUID(); let external = UUID()
        let ws = AgentGridWorkspace(slots: [a, nil], capacity: 2)
        // Tab/Sidebar (keine Slot-Herkunft) → platzieren.
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: external, sourceWorkspaceID: nil, sourceSlotIndex: nil,
                targetSlot: 0, workspace: ws
            ),
            .place
        )
        // Pane-Header eines ANDEREN Workspace → ebenfalls platzieren
        // (Add/Place, nicht Move — Review-Finding zur mehrdeutigen Herkunft).
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: external, sourceWorkspaceID: UUID(), sourceSlotIndex: 0,
                targetSlot: 1, workspace: ws
            ),
            .place
        )
    }

    func testStaleSlotOriginFallsBackToPlace() {
        let a = UUID(); let b = UUID()
        // Payload behauptet Slot 0, dort liegt aber inzwischen b — die
        // Herkunft ist veraltet und zählt nicht mehr als Move/Swap.
        let ws = AgentGridWorkspace(slots: [b, nil], capacity: 2)
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: a, sourceWorkspaceID: ws.id, sourceSlotIndex: 0,
                targetSlot: 1, workspace: ws
            ),
            .place
        )
    }

    func testInvalidTargetIsNoOp() {
        let ws = AgentGridWorkspace(slots: [UUID(), nil], capacity: 2)
        XCTAssertEqual(
            GridDropZoneResolver.action(
                sessionID: UUID(), sourceWorkspaceID: nil, sourceSlotIndex: nil,
                targetSlot: 7, workspace: ws
            ),
            .none
        )
    }
}
