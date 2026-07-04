import XCTest
@testable import WhisperM8

final class ProcessAncestryTests: XCTestCase {
    // MARK: - Pure (Fake-Provider)

    /// Simulierter Prozessbaum: whisperm8(100) ← zsh(50) ← claude(40) ← WhisperM8(30) ← launchd(1)
    private let fakeTree: [Int32: ProcessAncestry.ProcessInfoEntry] = [
        100: .init(pid: 100, ppid: 50, name: "whisperm8"),
        50: .init(pid: 50, ppid: 40, name: "zsh"),
        40: .init(pid: 40, ppid: 30, name: "claude"),
        30: .init(pid: 30, ppid: 1, name: "WhisperM8"),
    ]

    func testFindsClaudeAncestorThroughShell() {
        let tree = fakeTree
        let found = ProcessAncestry.findAncestor(named: "claude", from: 100, infoProvider: { tree[$0] })
        XCTAssertEqual(found, 40)
    }

    func testReturnsNilWhenAncestorMissing() {
        let tree = fakeTree
        XCTAssertNil(ProcessAncestry.findAncestor(named: "codex", from: 100, infoProvider: { tree[$0] }))
    }

    func testStopsAtInitWithoutMatching() {
        // Direkt unter WhisperM8 gestartet (kein claude in der Kette).
        let tree: [Int32: ProcessAncestry.ProcessInfoEntry] = [
            100: .init(pid: 100, ppid: 30, name: "whisperm8"),
            30: .init(pid: 30, ppid: 1, name: "WhisperM8"),
        ]
        XCTAssertNil(ProcessAncestry.findAncestor(named: "claude", from: 100, infoProvider: { tree[$0] }))
    }

    func testMaxDepthGuardsAgainstDegenerateChains() {
        // Künstlich lange Kette ohne Treffer — darf nicht endlos laufen.
        var tree: [Int32: ProcessAncestry.ProcessInfoEntry] = [:]
        for pid in Int32(2)...Int32(200) {
            tree[pid] = .init(pid: pid, ppid: pid - 1, name: "sh")
        }
        tree[1] = .init(pid: 1, ppid: 0, name: "launchd")
        let capturedTree = tree
        XCTAssertNil(ProcessAncestry.findAncestor(named: "claude", from: 200, maxDepth: 16, infoProvider: { capturedTree[$0] }))
    }

    // MARK: - ancestorChain (namensunabhängig)

    func testAncestorChainCollectsAllParents() {
        let tree = fakeTree
        let chain = ProcessAncestry.ancestorChain(from: 100, infoProvider: { tree[$0] })
        // zsh(50) → claude(40) → WhisperM8(30); launchd(1) bleibt draußen.
        XCTAssertEqual(chain, [50, 40, 30])
    }

    func testAncestorChainForRootlessProcessIsEmpty() {
        let tree: [Int32: ProcessAncestry.ProcessInfoEntry] = [
            100: .init(pid: 100, ppid: 1, name: "detached"),
        ]
        XCTAssertTrue(ProcessAncestry.ancestorChain(from: 100, infoProvider: { tree[$0] }).isEmpty)
    }

    func testAncestorChainRespectsMaxDepth() {
        var tree: [Int32: ProcessAncestry.ProcessInfoEntry] = [:]
        for pid in Int32(2)...Int32(100) {
            tree[pid] = .init(pid: pid, ppid: pid - 1, name: "sh")
        }
        let capturedTree = tree
        let chain = ProcessAncestry.ancestorChain(from: 100, maxDepth: 5, infoProvider: { capturedTree[$0] })
        XCTAssertEqual(chain.count, 5)
    }

    func testRealAncestorChainIsNonEmpty() {
        // Der Testrunner hat immer mindestens einen Eltern-Prozess.
        XCTAssertFalse(ProcessAncestry.ancestorChain().isEmpty)
    }

    // MARK: - Echtes sysctl (Smoke)

    func testInfoForOwnProcessReturnsEntry() throws {
        let entry = try XCTUnwrap(ProcessAncestry.info(for: ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(entry.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertGreaterThan(entry.ppid, 0)
        XCTAssertFalse(entry.name.isEmpty)
    }

    func testInfoForDeadPidReturnsNil() {
        // PID_MAX auf macOS ist 99998 — 99999 existiert nie.
        XCTAssertNil(ProcessAncestry.info(for: 99999))
    }
}
