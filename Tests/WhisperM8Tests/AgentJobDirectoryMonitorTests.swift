import XCTest
@testable import WhisperM8

/// Pure Pfadfilter-Tests des Job-Verzeichnis-Monitors: nur state.json und
/// last-message.txt sind sync-relevant — events.jsonl feuert im Burst und
/// darf keine Syncs auslösen.
final class AgentJobDirectoryMonitorTests: XCTestCase {
    private let root = "/Users/x/Library/Application Support/WhisperM8/agent-jobs"

    func testStateJsonAndLastMessageAreRelevant() {
        let paths = [
            "\(root)/a1b2c3d4/state.json",
            "\(root)/a1b2c3d4/last-message.txt",
        ]
        XCTAssertEqual(AgentJobDirectoryMonitor.relevantPaths(paths), paths)
    }

    func testEventsJsonlAndNoiseAreIgnored() {
        let paths = [
            "\(root)/a1b2c3d4/events.jsonl",
            "\(root)/a1b2c3d4/supervisor.log",
            "\(root)/a1b2c3d4/pending-prompt.txt",
            "\(root)/a1b2c3d4/report-schema.json",
            "\(root)/a1b2c3d4/state.json.tmp-ABC-123",
            "\(root)/a1b2c3d4",
        ]
        XCTAssertTrue(AgentJobDirectoryMonitor.relevantPaths(paths).isEmpty)
    }

    func testMixedBurstKeepsOnlyRelevantPaths() {
        let paths = [
            "\(root)/a1b2c3d4/events.jsonl",
            "\(root)/a1b2c3d4/state.json",
            "\(root)/ffee0011/events.jsonl",
            "\(root)/ffee0011/last-message.txt",
        ]
        XCTAssertEqual(
            AgentJobDirectoryMonitor.relevantPaths(paths),
            ["\(root)/a1b2c3d4/state.json", "\(root)/ffee0011/last-message.txt"]
        )
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertTrue(AgentJobDirectoryMonitor.relevantPaths([]).isEmpty)
    }
}
