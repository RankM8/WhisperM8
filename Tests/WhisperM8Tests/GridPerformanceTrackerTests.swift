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

    /// - Parameter frozenClock: Friert die Budget-Uhr über den bereits
    ///   vorhandenen `now`-Test-Hook ein, sodass jede Messung die Dauer 0
    ///   bekommt.
    ///
    ///   Diese Tests prüfen die ZUSTANDSMASCHINE (Generation-Bindung, Abbruch
    ///   statt Fake-Messung), nicht das Zeitbudget. Mit echter Wall-Clock
    ///   maßen sie faktisch die Laufzeit ihrer eigenen `Task.sleep`-Aufrufe
    ///   gegen das 50-ms-Budget von `grid.build` — bei nur 20 ms Puffer.
    ///   Unter CI-Last reichte das nicht, und
    ///   `testOverlappingBeginBuildCancelsPreviousWithoutViolation` schlug
    ///   fehl, obwohl die Zustandsmaschine korrekt arbeitete.
    ///
    ///   Nur der Timeout-Test braucht die echte Uhr — er will eine
    ///   Verletzung sehen und ist nach oben robust.
    private func makeTracker(
        violations: ViolationCounter,
        timeout: Duration = .seconds(2),
        frozenClock: Bool = true
    ) -> GridPerformanceTracker {
        let tracker = GridPerformanceTracker()
        tracker.timeout = timeout
        if frozenClock {
            let fixed = TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            tracker.buildBudget.now = { fixed }
            tracker.focusBudget.now = { fixed }
        }
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
        // Echte Uhr: Dieser Test WILL die Budget-Verletzung sehen. Er ist nach
        // oben robust — je langsamer die Maschine, desto sicherer greift er.
        let tracker = makeTracker(violations: violations, timeout: .milliseconds(80),
                                  frozenClock: false)
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
        let target = UUID()
        tracker.beginFocusSwitch(target: target)
        XCTAssertTrue(tracker.hasActiveFocusMeasurement)
        tracker.focusApplied(sessionID: target)
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        XCTAssertEqual(violations.count, 0)
    }

    func testFocusAppliedWithoutBeginIsNoOp() {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        tracker.focusApplied(sessionID: UUID())
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        XCTAssertEqual(violations.count, 0)
    }

    func testAbortFocusSwitchCancelsWithoutViolation() async throws {
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations, timeout: .milliseconds(50))
        let target = UUID()
        tracker.beginFocusSwitch(target: target)
        tracker.abortFocusSwitch(sessionID: target)
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        // Auch der Timeout darf danach nichts mehr bewerten.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(violations.count, 0)
    }

    func testStaleFocusCallbackCannotFinishNewGeneration() {
        // Review-Finding: der verspätete async-Callback des ALTEN Fokusziels
        // (A) darf die neue Messung (B) weder beenden noch abbrechen.
        let violations = ViolationCounter()
        let tracker = makeTracker(violations: violations)
        let a = UUID(); let b = UUID()
        tracker.beginFocusSwitch(target: a)
        tracker.beginFocusSwitch(target: b)
        tracker.focusApplied(sessionID: a)
        XCTAssertTrue(tracker.hasActiveFocusMeasurement, "B läuft weiter")
        tracker.abortFocusSwitch(sessionID: a)
        XCTAssertTrue(tracker.hasActiveFocusMeasurement, "auch Abort ist zielgebunden")
        tracker.focusApplied(sessionID: b)
        XCTAssertFalse(tracker.hasActiveFocusMeasurement)
        XCTAssertEqual(violations.count, 0)
    }
}
