import XCTest
@testable import WhisperM8

/// Scroll-Lock im Normal-Buffer: zeilenbasiertes Tail-Following mit exaktem
/// Einrasten (Terminal-friert-bis-Klick, 2026-10-22).
final class TerminalTailFollowTests: XCTestCase {
    // MARK: - decide

    func testExactlyAtTailFollows() {
        XCTAssertEqual(TerminalTailFollow.decide(distanceToTail: 0, movedDown: false), .follow)
        XCTAssertEqual(TerminalTailFollow.decide(distanceToTail: 0, movedDown: true), .follow)
    }

    func testDownwardScrollEndingJustShortSnaps() {
        for distance in 1...TerminalTailFollow.snapRows {
            XCTAssertEqual(
                TerminalTailFollow.decide(distanceToTail: distance, movedDown: true), .snapToTail,
                "distance \(distance)"
            )
        }
    }

    /// Ein, zwei Zeilen hochscrollen ist eine echte Leseabsicht — kein
    /// Zurückschnappen.
    func testUpwardScrollNearTailDetaches() {
        XCTAssertEqual(TerminalTailFollow.decide(distanceToTail: 1, movedDown: false), .detach)
    }

    func testDownwardScrollFarFromTailDetaches() {
        XCTAssertEqual(
            TerminalTailFollow.decide(distanceToTail: TerminalTailFollow.snapRows + 1, movedDown: true),
            .detach
        )
    }

    // MARK: - distanceToTail

    func testNoScrollbackIsAtTail() {
        // SwiftTerm meldet ohne Scrollback position 0 — das ist das Ende,
        // nicht „ganz oben".
        XCTAssertEqual(TerminalTailFollow.distanceToTail(yDisp: 0, position: 0, canScroll: false), 0)
    }

    func testPositionOneIsAtTail() {
        XCTAssertEqual(TerminalTailFollow.distanceToTail(yDisp: 500, position: 1, canScroll: true), 0)
    }

    func testTopOfScrollbackIsFarAway() {
        XCTAssertEqual(TerminalTailFollow.distanceToTail(yDisp: 0, position: 0, canScroll: true), Int.max)
    }

    /// Großer Scrollback: zwei Zeilen über dem Ende sind position ≈ 0,9998 —
    /// die alte 0,985-Toleranz hätte das als „folgt" gewertet.
    func testRecoversExactRowDistanceFromPosition() {
        let maxScrollback = 10_000
        for distance in [1, 2, 3, 150] {
            let yDisp = maxScrollback - distance
            let position = Double(yDisp) / Double(maxScrollback)
            XCTAssertEqual(
                TerminalTailFollow.distanceToTail(yDisp: yDisp, position: position, canScroll: true),
                distance
            )
        }
    }
}
