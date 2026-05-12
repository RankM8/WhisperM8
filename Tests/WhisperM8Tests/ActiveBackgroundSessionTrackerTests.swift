import Foundation
import XCTest
@testable import WhisperM8

@MainActor
final class ActiveBackgroundSessionTrackerTests: XCTestCase {

    // MARK: - displayName fallbacks

    func testDisplayNamePrefersName() {
        let job = SupervisorJobState(shortID: "a1", name: "background diagnostics", intent: "diagnose", cwd: "/x", state: nil, linkScanPath: nil, updatedAt: nil)
        XCTAssertEqual(ActiveBackgroundSessionTracker.displayName(for: job), "background diagnostics")
    }

    func testDisplayNameFallsBackToIntentTrimmingNewlines() {
        let job = SupervisorJobState(shortID: "a1", name: nil, intent: "first line\nmore", cwd: "/x", state: nil, linkScanPath: nil, updatedAt: nil)
        XCTAssertEqual(ActiveBackgroundSessionTracker.displayName(for: job), "first line more")
    }

    func testDisplayNameTruncatesLongIntent() {
        let job = SupervisorJobState(
            shortID: "a1", name: nil,
            intent: String(repeating: "x", count: 100),
            cwd: "/x", state: nil, linkScanPath: nil, updatedAt: nil
        )
        let display = ActiveBackgroundSessionTracker.displayName(for: job)
        XCTAssertLessThanOrEqual(display.count, 60)
        XCTAssertTrue(display.hasSuffix("…"))
    }

    func testDisplayNameFallsBackToShortIDWhenBothMissing() {
        let job = SupervisorJobState(shortID: "abc12345", name: nil, intent: nil, cwd: "/x", state: nil, linkScanPath: nil, updatedAt: nil)
        XCTAssertEqual(
            ActiveBackgroundSessionTracker.displayName(for: job),
            "Hintergrund-Agent · abc12345"
        )
    }

    // MARK: - projectDisplayName canonicalization

    func testProjectDisplayNameStripsWorktreePath() {
        let cwd = "/Users/x/repos/whisperm8/.claude/worktrees/bg-feature"
        XCTAssertEqual(
            ActiveBackgroundSessionTracker.projectDisplayName(forCwd: cwd),
            "whisperm8"
        )
    }

    func testProjectDisplayNameUsesLastComponentForRegularRepo() {
        let cwd = "/Users/x/repos/heartbeat"
        XCTAssertEqual(
            ActiveBackgroundSessionTracker.projectDisplayName(forCwd: cwd),
            "heartbeat"
        )
    }

    func testProjectDisplayNameHandlesTrailingSlashes() {
        let cwd = "/Users/x/repos/akquise-ai-shadow/"
        XCTAssertEqual(
            ActiveBackgroundSessionTracker.projectDisplayName(forCwd: cwd),
            "akquise-ai-shadow"
        )
    }
}
