import CoreGraphics
import Foundation
import XCTest
@testable import WhisperM8

/// Situation A des Ctrl+Tab-Switchers (Grid-Markierung): Pane-Rollen,
/// geometrische Pfeil-Navigation im Umfang, Chip-Stufen und der kleine
/// Beobachtungswert (diff-gated Spiegel).
final class TabSwitcherGridMarkingTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    // MARK: - Rollen

    func testInactiveWithoutRun() {
        XCTAssertEqual(TabSwitcherGridMarking.role(sessionID: a, isActive: false, highlightedID: a), .inactive)
        XCTAssertEqual(TabSwitcherGridMarking.role(sessionID: nil, isActive: false, highlightedID: nil), .inactive)
    }

    func testHighlightedPaneIsTargetOthersDimmed() {
        XCTAssertEqual(TabSwitcherGridMarking.role(sessionID: a, isActive: true, highlightedID: a), .target)
        XCTAssertEqual(TabSwitcherGridMarking.role(sessionID: b, isActive: true, highlightedID: a), .dimmed)
    }

    func testEmptySlotIsDimmedNeverTarget() {
        XCTAssertEqual(TabSwitcherGridMarking.role(sessionID: nil, isActive: true, highlightedID: nil), .dimmed)
        XCTAssertEqual(TabSwitcherGridMarking.role(sessionID: nil, isActive: true, highlightedID: a), .dimmed)
    }

    func testRolesAcrossGridExactlyOneTarget() {
        let slots: [UUID?] = [a, nil, b, c]
        let roles = slots.map {
            TabSwitcherGridMarking.role(sessionID: $0, isActive: true, highlightedID: b)
        }
        XCTAssertEqual(roles, [.dimmed, .dimmed, .target, .dimmed])
    }

    // MARK: - Pfeiltasten

    private func entity(_ slots: [UUID?], capacity: Int) -> AgentGridWorkspace {
        AgentGridWorkspace(slots: slots, capacity: capacity)
    }

    func testArrowRightAndDownIn2x2() {
        // 2×2: a b / c d
        let ws = entity([a, b, c, d], capacity: 4)
        let order = [a, b, c, d]
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: a, direction: .right, entity: ws, order: order), b)
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: a, direction: .down, entity: ws, order: order), c)
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: d, direction: .up, entity: ws, order: order), b)
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: d, direction: .left, entity: ws, order: order), c)
    }

    func testArrowStopsAtEdgeWithoutWrap() {
        let ws = entity([a, b, c, d], capacity: 4)
        let order = [a, b, c, d]
        XCTAssertNil(TabSwitcherGridMarking.arrowTarget(from: b, direction: .right, entity: ws, order: order))
        XCTAssertNil(TabSwitcherGridMarking.arrowTarget(from: a, direction: .up, entity: ws, order: order))
    }

    func testArrowSkipsSlotsOutsideScope() {
        // 3×2: a b c / d _ _ — b liegt in einem anderen Fenster (nicht im
        // Umfang) → → von a springt über b hinweg auf c.
        let ws = entity([a, b, c, d, nil, nil], capacity: 6)
        let order = [a, c, d]
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: a, direction: .right, entity: ws, order: order), c)
    }

    func testArrowSkipsEmptySlots() {
        // 3×2: a _ c / ...
        let ws = entity([a, nil, c, nil, nil, nil], capacity: 6)
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: a, direction: .right, entity: ws, order: [a, c]), c)
    }

    func testArrowFollowsSpanningSlot() {
        // Stufe 3: a b oben, c spannt die untere Zeile → ↓ von b trifft c.
        let ws = entity([a, b, c], capacity: 3)
        let order = [a, b, c]
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: b, direction: .down, entity: ws, order: order), c)
        XCTAssertEqual(TabSwitcherGridMarking.arrowTarget(from: c, direction: .up, entity: ws, order: order), a)
    }

    func testArrowFromUnknownHighlightStartsAtSlotZero() {
        let ws = entity([a, b, c, d], capacity: 4)
        XCTAssertEqual(
            TabSwitcherGridMarking.arrowTarget(from: UUID(), direction: .right, entity: ws, order: [a, b, c, d]),
            b
        )
    }

    func testDirectionKeyCodes() {
        XCTAssertEqual(TabSwitcherGridMarking.direction(keyCode: 123), .left)
        XCTAssertEqual(TabSwitcherGridMarking.direction(keyCode: 124), .right)
        XCTAssertEqual(TabSwitcherGridMarking.direction(keyCode: 125), .down)
        XCTAssertEqual(TabSwitcherGridMarking.direction(keyCode: 126), .up)
        XCTAssertNil(TabSwitcherGridMarking.direction(keyCode: 48))
    }

    // MARK: - Modell-Sprung

    func testModelHighlightOnlyWithinScope() {
        var model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        model.highlight(c, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, c)
        model.highlight(d, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, c)
        XCTAssertEqual(model.commitTarget(order: [a, b, c]), c)
    }

    // MARK: - Chip

    func testLargePaneGetsFullChip() {
        let chip = TabSwitcherGridMarking.chip(forPaneSize: CGSize(width: 600, height: 400))
        XCTAssertEqual(chip?.detail, .full)
        XCTAssertEqual(chip?.size.width, TabSwitcherGridMarking.chipMaxWidth)
        XCTAssertEqual(chip?.size.height, TabSwitcherGridMarking.chipFullHeight)
    }

    func testLowPaneDropsActivityLine() {
        // Chip darf höchstens die halbe Pane bedecken — sonst ohne Stand-Zeile.
        let chip = TabSwitcherGridMarking.chip(forPaneSize: CGSize(width: 600, height: 150))
        XCTAssertEqual(chip?.detail, .withoutActivity)
        XCTAssertEqual(chip?.size.height, TabSwitcherGridMarking.chipCompactHeight)
    }

    func testNarrowPaneKeepsStatusAndTitle() {
        let chip = TabSwitcherGridMarking.chip(forPaneSize: CGSize(width: 160, height: 400))
        XCTAssertEqual(chip?.detail, .statusAndTitle)
        XCTAssertEqual(chip?.size.width, 144)
    }

    func testTinyPaneGetsNoChip() {
        XCTAssertNil(TabSwitcherGridMarking.chip(forPaneSize: CGSize(width: 100, height: 400)))
        XCTAssertNil(TabSwitcherGridMarking.chip(forPaneSize: CGSize(width: 600, height: 60)))
    }

    // MARK: - Beobachtungswert

    @MainActor
    func testStateMirrorsAndResets() {
        let state = TabSwitcherGridMarkingState()
        XCTAssertFalse(state.isActive)
        state.update(highlightedID: b, targets: [a, b])
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.highlightedID, b)
        XCTAssertEqual(state.targetIDs, [a, b])
        state.reset()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.highlightedID)
        XCTAssertTrue(state.targetIDs.isEmpty)
    }

    /// Ein Schritt ändert nur `highlightedID` — `isActive`/`targetIDs` werden
    /// nicht erneut geschrieben (Observation meldete sonst jede Pane als
    /// geändert, auch ohne Wertänderung).
    @MainActor
    func testUpdateIsDiffGated() {
        let state = TabSwitcherGridMarkingState()
        state.update(highlightedID: a, targets: [a, b])

        var activeChanged = false
        var targetsChanged = false
        withObservationTracking {
            _ = state.isActive
            _ = state.targetIDs
        } onChange: {
            activeChanged = true
            targetsChanged = true
        }
        var highlightChanged = false
        withObservationTracking {
            _ = state.highlightedID
        } onChange: {
            highlightChanged = true
        }

        state.update(highlightedID: b, targets: [a, b])
        XCTAssertTrue(highlightChanged)
        XCTAssertFalse(activeChanged)
        XCTAssertFalse(targetsChanged)
    }
}
