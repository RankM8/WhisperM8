import Foundation
import Observation
import XCTest
@testable import WhisperM8

/// Pure Durchlauf-Maschine des Ctrl+Tab-Switchers: Aktivierung, Wrap-around,
/// Robustheit gegen extern verschwindende Tabs, Commit-Ziel.
final class TabSwitcherModelTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    // MARK: - Aktivierung

    func testBeginNeedsAtLeastTwoTabs() {
        XCTAssertNil(TabSwitcherModel.begin(order: [], current: nil, direction: 1))
        XCTAssertNil(TabSwitcherModel.begin(order: [a], current: a, direction: 1))
    }

    func testBeginHighlightsNextTab() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)
        XCTAssertEqual(model?.highlightedID, b)
    }

    func testBeginBackwardWrapsToLast() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: -1)
        XCTAssertEqual(model?.highlightedID, c)
    }

    func testBeginWithNilCurrentStartsFromFirst() {
        // Keine Selektion → Anker ist der erste Tab, ein Schritt vor = zweiter.
        let model = TabSwitcherModel.begin(order: [a, b, c], current: nil, direction: 1)
        XCTAssertEqual(model?.highlightedID, b)
    }

    // MARK: - Durchlauf

    func testAdvanceMovesForwardWithWrap() {
        var model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        model.advance(1, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, c)
        model.advance(1, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, a)
    }

    func testAdvanceBackward() {
        var model = TabSwitcherModel.begin(order: [a, b, c], current: c, direction: 1)!
        XCTAssertEqual(model.highlightedID, a)
        model.advance(-1, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, c)
    }

    func testAdvanceFallsBackWhenHighlightedTabDisappeared() {
        var model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        XCTAssertEqual(model.highlightedID, b)
        // b wurde extern geschlossen/archiviert → Fallback auf den ersten Tab
        // der frischen Reihenfolge statt hängen/crashen.
        model.advance(1, order: [a, c])
        XCTAssertEqual(model.highlightedID, a)
    }

    func testAdvanceMultiStepBeyondCountWrapsSafely() {
        // Die Mini-Map springt per `advance` um den Index-Abstand zum
        // räumlichen Ziel (mehrere Schritte auf einmal). Nach externem
        // Tab-Close kann ein Sprung die Tab-Anzahl übersteigen — der Wrap
        // darf dann nie in einen negativen Index laufen (Swifts `%` behält
        // das Vorzeichen).
        var model = TabSwitcherModel.begin(order: [a, b, c], current: b, direction: 1)!
        XCTAssertEqual(model.highlightedID, c)
        model.advance(-4, order: [a, b, c])   // idx 2 → -2 → wrap → b
        XCTAssertEqual(model.highlightedID, b)

        model = TabSwitcherModel.begin(order: [a, b, c], current: c, direction: 1)!
        XCTAssertEqual(model.highlightedID, a)
        model.advance(-4, order: [a, b, c])   // idx 0 → -4 → wrap → c (crashte vorher)
        XCTAssertEqual(model.highlightedID, c)
    }

    // MARK: - Commit

    func testCommitTargetReturnsHighlighted() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        XCTAssertEqual(model.commitTarget(order: [a, b, c]), b)
    }

    func testCommitTargetIsNilWhenHighlightedTabDisappeared() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        // b existiert beim Loslassen nicht mehr → Selektion bleibt, wie sie ist.
        XCTAssertNil(model.commitTarget(order: [a, c]))
    }

    // MARK: - Beobachtungswert für Mini-Map/Liste (TabSwitcherRunState)

    /// Ein Ctrl+Tab-Schritt darf nur das Highlight melden — der Body der
    /// AgentChatsView hängt an `isActive` und würde sonst bei jedem Schritt
    /// samt Sidebar neu ausgewertet.
    @MainActor
    func testStepReportsOnlyHighlight() {
        let run = TabSwitcherRunState()
        let order = [a, b, c]
        run.setSessions(order.map {
            AgentChatSession(id: $0, provider: .claude, projectID: UUID(), title: "t", status: .running)
        })
        run.model = TabSwitcherModel.begin(order: order, current: a, direction: 1)
        XCTAssertTrue(run.isActive)
        XCTAssertEqual(run.highlightedID, b)

        var bodyChanged = false
        withObservationTracking {
            _ = run.isActive
        } onChange: {
            bodyChanged = true
        }
        var snapshotChanged = false
        withObservationTracking {
            _ = run.sessions
            _ = run.miniMapWorkspace
        } onChange: {
            snapshotChanged = true
        }
        var highlightChanged = false
        withObservationTracking {
            _ = run.highlightedID
        } onChange: {
            highlightChanged = true
        }

        // Schritt wie im Key-Event-Pfad: Modell mutieren, gleichen Umfang
        // erneut ablegen (diff-gated → kein Signal).
        run.model?.advance(1, order: order)
        run.setSessions(run.sessions)
        run.setMiniMapWorkspace(nil)

        XCTAssertEqual(run.highlightedID, c)
        XCTAssertTrue(highlightChanged)
        XCTAssertFalse(bodyChanged)
        XCTAssertFalse(snapshotChanged)
    }

    @MainActor
    func testOpenAndCloseToggleIsActive() {
        let run = TabSwitcherRunState()
        var changed = false
        withObservationTracking {
            _ = run.isActive
        } onChange: {
            changed = true
        }
        run.model = TabSwitcherModel.begin(order: [a, b], current: a, direction: 1)
        XCTAssertTrue(changed)
        XCTAssertTrue(run.isActive)

        run.model = nil
        XCTAssertFalse(run.isActive)
        XCTAssertNil(run.highlightedID)
    }
}
