import XCTest
@testable import WhisperM8

/// Der Punkt im Chat- und Kachelkopf zeigt denselben Laufzeitstatus wie die
/// Sidebar — nicht mehr „grün, sobald der Prozess läuft".
final class SessionHeaderStatusTests: XCTestCase {
    func testLiveStatusWinsRegardlessOfProcess() {
        for status in [AgentSessionRuntimeStatus.working, .awaitingInput, .idle, .errored] {
            XCTAssertEqual(SessionHeaderStatus.resolve(live: status, isProcessRunning: true), status)
            XCTAssertEqual(SessionHeaderStatus.resolve(live: status, isProcessRunning: false), status)
        }
    }

    func testRunningProcessWithoutKnownStatusIsIdleNotWorking() {
        XCTAssertEqual(SessionHeaderStatus.resolve(live: nil, isProcessRunning: true), .idle,
                       "ein laufender Prozess allein heißt nicht „arbeitet“")
        XCTAssertEqual(SessionHeaderStatus.resolve(live: .stopped, isProcessRunning: true), .idle,
                       "veralteter stopped-Wert bei laufendem Prozess")
    }

    func testNoProcessAndNoStatusShowsThePlaceholder() {
        XCTAssertNil(SessionHeaderStatus.resolve(live: nil, isProcessRunning: false))
        XCTAssertNil(SessionHeaderStatus.resolve(live: .stopped, isProcessRunning: false))
    }
}
