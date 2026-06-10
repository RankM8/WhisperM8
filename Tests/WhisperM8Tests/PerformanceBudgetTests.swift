import Foundation
import XCTest
@testable import WhisperM8

final class PerformanceBudgetTests: XCTestCase {
    /// Deterministische Uhr nach Repo-Konvention (Closure-DI).
    private final class Clock {
        var current = Date(timeIntervalSince1970: 1_000)
        func advance(by interval: TimeInterval) {
            current = current.addingTimeInterval(interval)
        }
    }

    private func makeBudget(
        _ limit: TimeInterval,
        clock: Clock,
        onViolation: @escaping (String, TimeInterval) -> Void
    ) -> PerformanceBudget {
        PerformanceBudget(
            name: "test.interval",
            budget: limit,
            signposter: PerfSignposts.store,
            now: { clock.current },
            onViolation: onViolation
        )
    }

    func testUnderBudgetDoesNotViolate() {
        let clock = Clock()
        var violations: [(String, TimeInterval)] = []
        let budget = makeBudget(0.1, clock: clock) { violations.append(($0, $1)) }

        let token = budget.begin()
        clock.advance(by: 0.05)
        budget.end(token)

        XCTAssertTrue(violations.isEmpty)
    }

    func testOverBudgetViolatesOnceWithMeasuredDuration() {
        let clock = Clock()
        var violations: [(String, TimeInterval)] = []
        let budget = makeBudget(0.1, clock: clock) { violations.append(($0, $1)) }

        let token = budget.begin()
        clock.advance(by: 0.25)
        budget.end(token)

        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.0, "test.interval")
        XCTAssertEqual(violations.first?.1 ?? 0, 0.25, accuracy: 0.0001)
    }

    func testExactlyAtBudgetDoesNotViolate() {
        let clock = Clock()
        var violations: [(String, TimeInterval)] = []
        // 0.125 ist binär exakt darstellbar — 0.1 würde durch Float-Rundung
        // der Date-Arithmetik knapp über dem Budget landen.
        let budget = makeBudget(0.125, clock: clock) { violations.append(($0, $1)) }

        let token = budget.begin()
        clock.advance(by: 0.125)
        budget.end(token)

        XCTAssertTrue(violations.isEmpty)
    }

    func testEndIsIdempotent() {
        let clock = Clock()
        var violations: [(String, TimeInterval)] = []
        let budget = makeBudget(0.1, clock: clock) { violations.append(($0, $1)) }

        let token = budget.begin()
        clock.advance(by: 0.2)
        budget.end(token)
        clock.advance(by: 1.0)
        // Safety-defer-Muster: zweites end darf weder messen noch erneut feuern.
        budget.end(token)

        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.1 ?? 0, 0.2, accuracy: 0.0001)
    }

    func testWithIntervalEndsOnThrow() {
        struct TestError: Error {}
        let clock = Clock()
        var violations: [(String, TimeInterval)] = []
        let budget = makeBudget(0.1, clock: clock) { violations.append(($0, $1)) }

        XCTAssertThrowsError(
            try budget.withInterval {
                clock.advance(by: 0.3)
                throw TestError()
            }
        )

        XCTAssertEqual(violations.count, 1, "Intervall muss auch auf dem Throw-Pfad enden")
    }
}
