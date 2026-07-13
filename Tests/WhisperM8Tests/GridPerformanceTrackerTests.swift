import Foundation
import XCTest
@testable import WhisperM8

/// Zustandsmaschine des Grid-Performance-Trackings: Generation-Bindung,
/// Abbruch statt Fake-Messung, Timeout-Pfad (Review-Finding 7, Paket 1).
@MainActor
final class GridPerformanceTrackerTests: XCTestCase {
    /// Referenz-Box für den `onViolation`-Hook (Budget ist ein Struct).
    private final class ViolationCounter {
        var count = 0
    }

    private func makeTracker(
        violations: ViolationCounter,
        timeout: Duration = .seconds(2)
    ) -> GridPerformanceTracker {
        let tracker = GridPerformanceTracker()
        tracker.timeout = timeout
        tracker.buildBudget.onViolation = { _, _ in violations.count += 1 }
        tracker.focusBudget.onViolation = { _, _ in violations.count += 1 }
        return tracker
    }

    // MARK: - grid.build

    func testBuildEndsWithoutViolationWhenAllPanesAttach() async throws {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        let a = UUID(); let b = UUID()

        tracker.beginBuild(expectedPaneIDs: [a, b])
        XCTAssertTrue(tracker.hasActiveBuildMeasurement)
        tracker.didAttach(sessionID: a)
        XCTAssertTrue(tracker.hasActiveBuildMeasurement, "b fehlt noch")
        tracker.didAttach(sessionID: b)

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(tracker.hasActiveBuildMeasurement)
        XCTAssertEqual(violations.count, 0)
    }

    func testEmptyExpectationEndsOnNextRunloopTurn() async throws {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        tracker.beginBuild(expectedPaneIDs: [])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(tracker.hasActiveBuildMeasurement)
        XCTAssertEqual(violations.count, 0)
    }

    func testOverlappingBeginBuildCancelsPreviousWithoutViolation() async throws {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        let stale = UUID(); let fresh = UUID()

        tracker.beginBuild(expectedPaneIDs: [stale])
        tracker.beginBuild(expectedPaneIDs: [fresh])
        // Ein verspäteter Attach der ALTEN Erwartung darf die neue Messung
        // nicht beenden.
        tracker.didAttach(sessionID: stale)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(tracker.hasActiveBuildMeasurement, "neue Messung läuft weiter")

        tracker.didAttach(sessionID: fresh)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(tracker.hasActiveBuildMeasurement)
        XCTAssertEqual(violations.count, 0, "abgebrochene Messung bewertet kein Budget")
    }

    func testBuildTimeoutEndsLeakedMeasurementAsViolation() async throws {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations, timeout: .milliseconds(80))
        tracker.beginBuild(expectedPaneIDs: [UUID()]) // attached nie

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(tracker.hasActiveBuildMeasurement, "Timeout räumt auf")
        XCTAssertEqual(violations.count, 1, "80 ms > 50-ms-Budget → Verletzung")
    }

    func testDidAttachWithoutMeasurementIsNoOp() {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        tracker.didAttach(sessionID: UUID())
        XCTAssertFalse(tracker.hasActiveBuildMeasurement)
        XCTAssertEqual(violations.count, 0)
    }

    // MARK: - grid.focusSwitch

    func testFocusAppliedEndsMeasurement() {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        tracker.beginFocusSwitch()
        XCTAssertTrue(tracker.hasActiveFocusMeasurement)
        tracker.focusApplied()
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        XCTAssertEqual(violations.count, 0)
    }

    func testFocusAppliedWithoutBeginIsNoOp() {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        tracker.focusApplied()
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        XCTAssertEqual(violations.count, 0)
    }

    func testAbortFocusSwitchCancelsWithoutViolation() async throws {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations, timeout: .milliseconds(50))
        tracker.beginFocusSwitch()
        tracker.abortFocusSwitch()
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        // Auch der Timeout darf danach nichts mehr bewerten.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(violations.count, 0)
    }

    func testOverlappingFocusSwitchCancelsPreviousMeasurement() {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        tracker.beginFocusSwitch()
        tracker.beginFocusSwitch()
        tracker.focusApplied()
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        XCTAssertEqual(violations.count, 0)
    }
}
