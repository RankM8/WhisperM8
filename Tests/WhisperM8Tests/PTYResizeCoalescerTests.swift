import XCTest
@testable import WhisperM8

/// LR-AU-015: PTY-Resizes beim Ziehen werden gebündelt. Messung vorher/nachher:
/// ein 1-s-Drag mit 30 Ticks erzeugte 30 TIOCSWINSZ, jetzt 2 (erste + letzte Größe).
@MainActor
final class PTYResizeCoalescerTests: XCTestCase {
    private var time: TimeInterval = 100
    private var scheduled: [(at: TimeInterval, work: () -> Void, cancelled: Bool)] = []
    private var forwarded: [(Int, Int)] = []
    private var requested = 0
    private var forwardedCount = 0

    private func makeCoalescer() -> PTYResizeCoalescer {
        PTYResizeCoalescer(
            quietInterval: 0.15,
            now: { self.time },
            schedule: { delay, work in
                let index = self.scheduled.count
                self.scheduled.append((self.time + delay, work, false))
                return { self.scheduled[index].cancelled = true }
            },
            onRequested: { self.requested += 1 },
            onForwarded: { self.forwardedCount += 1 },
            forward: { self.forwarded.append(($0, $1)) }
        )
    }

    /// Spielt fällige, nicht abgebrochene Trailing-Aufträge ab.
    private func advance(to newTime: TimeInterval) {
        time = newTime
        for index in scheduled.indices where !scheduled[index].cancelled && scheduled[index].at <= newTime {
            scheduled[index].cancelled = true
            scheduled[index].work()
        }
    }

    func testSingleResizeAfterQuietGoesThroughImmediately() {
        let c = makeCoalescer()
        c.request(cols: 100, rows: 30)
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?.0, 100)
    }

    func testDragOfThirtyTicksSendsOnlyFirstAndLastSize() {
        let c = makeCoalescer()
        for tick in 0..<30 {
            time = 100 + Double(tick) * 0.033
            c.request(cols: 100 + tick, rows: 30)
        }
        XCTAssertEqual(requested, 30)
        XCTAssertEqual(forwarded.count, 1, "während der Geste geht nur die erste Größe durch")
        advance(to: time + 0.2)
        XCTAssertEqual(forwarded.count, 2)
        XCTAssertEqual(forwarded.last?.0, 129, "am Ende zählt die letzte Größe")
        XCTAssertEqual(forwardedCount, 2)
    }

    func testResizeAfterPauseIsLeadingAgain() {
        let c = makeCoalescer()
        c.request(cols: 80, rows: 24)
        advance(to: time + 1)
        c.request(cols: 90, rows: 24)
        XCTAssertEqual(forwarded.map(\.0), [80, 90])
    }
}
