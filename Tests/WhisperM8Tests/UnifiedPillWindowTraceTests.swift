import XCTest
@testable import WhisperM8

/// `whisperm8 debug pill`: Auswertung des Fenster-Mitschnitts und Aufruf.
final class UnifiedPillWindowTraceTests: XCTestCase {
    private typealias Sample = UnifiedPillWindowSample
    private let status = 10
    private let dictation = 20

    private func window(_ number: Int, midY: CGFloat = 44) -> Sample.Window {
        .init(number: number, bounds: CGRect(x: 100, y: midY - 44, width: 400, height: 88), alpha: 1)
    }

    private func verdict(_ samples: [Sample]) -> UnifiedPillTraceVerdict {
        UnifiedPillTraceVerdict.evaluate(samples: samples, dictationWindow: dictation, statusWindows: [status])
    }

    /// Hin und zurück mit Überlappung, gleiche Mitte: nahtlos.
    func testSeamlessHandoverBothWays() {
        let result = verdict([
            Sample(time: 0, windows: [window(status)]),
            Sample(time: 10, windows: [window(status), window(dictation)]),
            Sample(time: 45, windows: [window(dictation)]),
            Sample(time: 1500, windows: [window(dictation), window(status)]),
            Sample(time: 1530, windows: [window(status)]),
        ])
        XCTAssertTrue(result.isSeamless)
        XCTAssertEqual(result.longestGapMs, 0)
        XCTAssertEqual(result.overlapMs, 65)
        XCTAssertEqual(result.dictationAppearedMs, 10)
        XCTAssertEqual(result.statusHiddenMs, 45)
        XCTAssertEqual(result.statusBackMs, 1500)
        XCTAssertEqual(result.dictationGoneMs, 1530)
    }

    /// Status-Pille geht, bevor das Diktat steht: Lücke, nicht nahtlos.
    func testGapWithoutAnyPillIsReported() {
        let result = verdict([
            Sample(time: 0, windows: [window(status)]),
            Sample(time: 5, windows: [window(status), window(dictation)]),
            Sample(time: 8, windows: []),
            Sample(time: 41, windows: [window(dictation)]),
        ])
        XCTAssertFalse(result.isSeamless)
        XCTAssertEqual(result.longestGapMs, 33)
    }

    /// Diktat-Fenster steht tiefer als die Status-Pille (AppKit schob es unter
    /// die Menüleiste): Versatz in Punkten, nicht nahtlos.
    func testVerticalOffsetIsReported() {
        let result = verdict([
            Sample(time: 0, windows: [window(status, midY: 68)]),
            Sample(time: 10, windows: [window(status, midY: 68), window(dictation, midY: 92)]),
            Sample(time: 40, windows: [window(dictation, midY: 92)]),
        ])
        XCTAssertFalse(result.isSeamless)
        XCTAssertEqual(result.maxCenterOffset, 24)
    }

    /// Tausch der Sichtbarkeit, bevor das Diktat-Fenster in der Fensterliste
    /// stand: nicht nahtlos, auch wenn immer ein Fenster stand.
    func testRevealBeforeTheWindowIsOnScreenIsReported() {
        let samples = [
            Sample(time: 0, windows: [window(status)]),
            Sample(time: 40, windows: [window(status), window(dictation)]),
            Sample(time: 90, windows: [window(dictation)]),
        ]
        let early = UnifiedPillTraceVerdict.evaluate(
            samples: samples, events: [UnifiedPillTraceEvent(time: 30, name: "revealDictation")],
            dictationWindow: dictation, statusWindows: [status])
        XCTAssertEqual(early.revealDictationLeadMs, -10)
        XCTAssertFalse(early.isSeamless)
        let inTime = UnifiedPillTraceVerdict.evaluate(
            samples: samples, events: [UnifiedPillTraceEvent(time: 70, name: "revealDictation")],
            dictationWindow: dictation, statusWindows: [status])
        XCTAssertEqual(inTime.revealDictationLeadMs, 30)
        XCTAssertTrue(inTime.isSeamless)
    }

    func testWithoutDictationWindowNothingIsJudged() {
        let result = UnifiedPillTraceVerdict.evaluate(
            samples: [Sample(time: 0, windows: [window(status)])], dictationWindow: nil, statusWindows: [status])
        XCTAssertNil(result.dictationAppearedMs)
        XCTAssertEqual(result.longestGapMs, 0)
    }

    func testCLIArguments() throws {
        XCTAssertEqual(try DebugCLIArguments.parse(["pill"], cwd: "/"), .pill(holdMs: nil, busyMs: nil, busyAfterMs: nil))
        XCTAssertEqual(
            try DebugCLIArguments.parse(["pill", "--hold", "800", "--busy", "120", "--busy-after", "10"], cwd: "/"),
            .pill(holdMs: 800, busyMs: 120, busyAfterMs: 10))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["pill", "--busy", "5000"], cwd: "/"))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["pill", "--hold"], cwd: "/"))
        XCTAssertThrowsError(try DebugCLIArguments.parse(["pill", "extra"], cwd: "/"))
    }
}
