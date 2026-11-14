import XCTest
@testable import WhisperM8

final class LinearCostMeterTests: XCTestCase {
    func testReadsCostAndBudgetFromHeaders() {
        let meter = LinearCostMeter()
        let first = ["X-Complexity": "70", "X-RateLimit-Requests-Remaining": "2496", "X-RateLimit-Complexity-Remaining": "2999860"]
        meter.record { first[$0] }
        let second = ["X-Complexity": "45"]
        meter.record { second[$0] }

        let cost = meter.snapshot
        XCTAssertEqual(cost.requests, 2)
        XCTAssertEqual(cost.complexity, 115)
        XCTAssertEqual(cost.lastComplexity, 45)
        // Fehlt eine Kopfzeile, bleibt der letzte bekannte Stand stehen.
        XCTAssertEqual(cost.remainingRequests, 2496)
        XCTAssertEqual(cost.remainingComplexity, 2_999_860)
    }

    func testAnswerWithoutHeadersStillCountsAsRequest() {
        let meter = LinearCostMeter()
        meter.record { _ in nil }
        XCTAssertEqual(meter.snapshot, LinearCost(requests: 1, complexity: 0))
    }

    func testDescribesTheCostOfOneFetch() {
        let before = LinearCost(requests: 3, complexity: 200, remainingRequests: 2490, remainingComplexity: 2_999_000)
        let after = LinearCost(requests: 5, complexity: 340, lastComplexity: 70, remainingRequests: 2488, remainingComplexity: 2_998_860)
        XCTAssertEqual(LinearCostMeter.describe(from: before, to: after),
                       "Abruf: 2 Anfragen, 140 Punkte; übrig in dieser Stunde 2488 Anfragen, 2998860 Punkte")
        // Ohne Anfrage (Tests, gestubbte Quelle) kein Satz.
        XCTAssertNil(LinearCostMeter.describe(from: after, to: after))
    }

    func testLogLineCarriesNoKey() {
        var lines: [String] = []
        Logger.testSink = { lines.append($0) }
        defer { Logger.testSink = nil }
        let headers = ["X-Complexity": "70", "Authorization": "lin_api_geheim"]
        LinearCostMeter().record { headers[$0] }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("linear_cost complexity=70"))
        XCTAssertFalse(lines.joined().contains("lin_api"))
    }
}
