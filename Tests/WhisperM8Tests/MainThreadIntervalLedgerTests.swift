import AppKit
import XCTest
@testable import WhisperM8

/// WM8-101: Jede Hänger-Meldung soll ihren Verursacher nennen. Vorher stand im
/// Log nur `main_thread_freeze durationMs=…`; die Ursache musste man aus den
/// Zeilen davor erraten (15.11.2026: 8 % der Hängerzeit ohne erkennbaren
/// Anlass, der größte Posten nur über Indizien zugeordnet).
final class MainThreadIntervalLedgerTests: XCTestCase {
    private let ledger = MainThreadIntervalLedger.shared
    private static let probe = PerformanceBudget(name: "test.probe", budget: 10, signposter: PerfSignposts.chats)
    private static let other = PerformanceBudget(name: "test.other", budget: 10, signposter: PerfSignposts.chats)

    override func setUp() {
        super.setUp()
        ledger.reset()
    }

    override func tearDown() {
        ledger.reset()
        super.tearDown()
    }

    // MARK: - Register

    @MainActor
    func testRecordsMainThreadIntervalFromFiftyMilliseconds() {
        var budget = Self.probe
        var clock: TimeInterval = 100
        budget.now = { clock }
        let token = budget.begin()
        clock += 0.120
        budget.end(token)

        let entries = ledger.entries(overlapping: 100, 101)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(MainThreadIntervalLedger.describe(entries), "test.probe:120")
    }

    @MainActor
    func testShortIntervalsStayOut() {
        var budget = Self.probe
        var clock: TimeInterval = 100
        budget.now = { clock }
        let token = budget.begin()
        clock += 0.030
        budget.end(token)

        XCTAssertTrue(ledger.entries(overlapping: 0, 1_000).isEmpty)
    }

    func testIntervalsOffTheMainThreadStayOut() {
        let done = expectation(description: "Hintergrund")
        DispatchQueue.global().async {
            var budget = Self.probe
            var clock: TimeInterval = 100
            budget.now = { clock }
            let token = budget.begin()
            clock += 2
            budget.end(token)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(ledger.entries(overlapping: 0, 1_000).isEmpty)
        XCTAssertTrue(ledger.openNames().isEmpty)
    }

    @MainActor
    func testOpenIntervalIsNamedUntilItEnds() {
        let token = Self.probe.begin()
        XCTAssertEqual(ledger.openNames(), ["test.probe"])
        Self.probe.end(token)
        XCTAssertTrue(ledger.openNames().isEmpty)
    }

    @MainActor
    func testCancelClosesWithoutEntry() {
        var budget = Self.probe
        var clock: TimeInterval = 100
        budget.now = { clock }
        let token = budget.begin()
        clock += 3
        budget.cancel(token)
        XCTAssertTrue(ledger.openNames().isEmpty)
        XCTAssertTrue(ledger.entries(overlapping: 0, 1_000).isEmpty)
    }

    @MainActor
    func testOverlapWindowAndLongestFirst() {
        var probe = Self.probe
        var other = Self.other
        var clock: TimeInterval = 100
        probe.now = { clock }
        other.now = { clock }

        let early = probe.begin()          // endet vor dem Fenster
        clock = 100.2
        probe.end(early)

        clock = 105
        let short = other.begin()
        clock = 105.08
        other.end(short)
        let long = probe.begin()
        clock = 106.3
        probe.end(long)

        let inWindow = ledger.entries(overlapping: 104.9, 106.4)
        XCTAssertEqual(MainThreadIntervalLedger.describe(inWindow), "test.probe:1220,test.other:80")
    }

    func testRingKeepsOnlyTheNewestEntries() {
        for index in 0..<(MainThreadIntervalLedger.capacity + 5) {
            let start = TimeInterval(index)
            ledger.didEnd("test.probe", start: start, end: start + 0.1)
        }
        let all = ledger.entries(overlapping: 0, 10_000)
        XCTAssertEqual(all.count, MainThreadIntervalLedger.capacity)
        XCTAssertFalse(all.contains { $0.start < 5 }, "die ältesten fünf sind überschrieben")
    }

    func testDescribeEmpty() {
        XCTAssertEqual(MainThreadIntervalLedger.describe([]), "-")
        XCTAssertEqual(MainThreadIntervalLedger.describe(openNames: []), "-")
    }

    // MARK: - Hänger-Meldung

    @MainActor
    func testFreezeNamesTheIntervalInItsWindow() {
        let monitor = MainThreadStallMonitor.shared
        monitor.stop()
        var clock: TimeInterval = 5_000
        var budget = Self.probe
        budget.now = { clock }
        var reports: [(TimeInterval, String, String, Bool)] = []
        monitor.now = { clock }
        monitor.onFreeze = { reports.append(($0, $1, $2, $3)) }
        defer { restore(monitor) }

        monitor.tick()
        let token = budget.begin()      // der Main Thread steckt hier fest …
        clock += 1.4
        budget.end(token)
        clock += 0.05
        monitor.tick()                  // … und erst danach meldet der Monitor

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.1, "test.probe:1400")
        XCTAssertEqual(reports.first?.2, "-")
        XCTAssertEqual(reports.first?.3, false)
    }

    @MainActor
    func testFreezeRightAfterWakeIsMarked() {
        let monitor = MainThreadStallMonitor.shared
        monitor.stop()
        var clock: TimeInterval = 6_000
        var reports: [Bool] = []
        monitor.now = { clock }
        monitor.onFreeze = { _, _, _, afterWake in reports.append(afterWake) }
        defer { restore(monitor) }

        monitor.tick()
        monitor.noteWake()
        clock += 1.5                    // Aufholen nach dem Schlaf
        monitor.tick()
        clock += MainThreadStallMonitor.wakeGrace + 1.0
        monitor.tick()                  // später: wieder ein echter Hänger

        XCTAssertEqual(reports, [true, false])
    }

    func testWakeGraceIsPure() {
        XCTAssertFalse(MainThreadStallMonitor.isWithinWakeGrace(10, lastWake: nil))
        XCTAssertTrue(MainThreadStallMonitor.isWithinWakeGrace(10, lastWake: 0))
        XCTAssertFalse(MainThreadStallMonitor.isWithinWakeGrace(MainThreadStallMonitor.wakeGrace, lastWake: 0))
        XCTAssertFalse(MainThreadStallMonitor.isWithinWakeGrace(5, lastWake: 8), "vor dem Aufwachen zählt nicht")
    }

    func testWatchdogStaysQuietDuringWakeGrace() {
        let watchdog = StallWatchdog()
        var clock: TimeInterval = 100
        watchdog.now = { clock }
        var reports: [TimeInterval] = []
        watchdog.onBlock = { reports.append($0) }

        watchdog.beat()
        watchdog.suppress(until: 103)
        clock += 2
        watchdog.check()
        XCTAssertTrue(reports.isEmpty)

        clock += 1.5                    // Schonfrist vorbei, Main Thread steht weiter
        watchdog.check()
        XCTAssertEqual(reports.count, 1)
    }

    // MARK: - Chatwechsel

    func testSelectionDiffersOnlyOnSelection() {
        let windowID = UUID()
        let state = AgentUIState(windows: [AgentChatWindowState(id: windowID, isPrimary: true)], primaryWindowID: windowID)
        var changed = state
        changed.pinnedSessionIDs = [UUID()]
        XCTAssertFalse(ChatSwitchMeasurement.selectionDiffers(state, changed))

        changed.windows[0].selectedSessionID = UUID()
        XCTAssertTrue(ChatSwitchMeasurement.selectionDiffers(state, changed))

        var global = state
        global.selectedSessionID = UUID()
        XCTAssertTrue(ChatSwitchMeasurement.selectionDiffers(state, global))
    }

    @MainActor
    func testAfterNextCommitRunsOnce() {
        var runs = 0
        MainRunLoopCommit.afterNextCommit { runs += 1 }
        XCTAssertEqual(runs, 0, "läuft erst nach dem laufenden Durchgang")
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(runs, 1)
    }

    @MainActor
    private func restore(_ monitor: MainThreadStallMonitor) {
        monitor.stop()
        monitor.now = { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
        monitor.onFreeze = nil
    }
}
