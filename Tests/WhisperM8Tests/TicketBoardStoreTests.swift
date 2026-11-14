import XCTest
@testable import WhisperM8

@MainActor
final class TicketBoardStoreTests: XCTestCase {
    /// Wartefunktion, die erst weiterläuft, wenn der Test sie freigibt.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Error>] = []
        private(set) var sleeps = 0

        func sleep(_: Duration) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock(); sleeps += 1; waiting.append(continuation); lock.unlock()
                }
            } onCancel: {
                self.release(throwing: CancellationError())
            }
        }

        func release(throwing error: Error? = nil) {
            lock.lock(); let pending = waiting; waiting = []; lock.unlock()
            for continuation in pending {
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return sleeps }
    }

    private func settle(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Bedingung nicht erreicht", file: file, line: line)
    }

    func testActivateLoadsAtOnceThenInIntervals() async {
        let source = TicketSourceStub()
        var round = 0
        source.onBoard = { _ in round += 1; return TicketFixtures.snapshot([TicketFixtures.ticket(round)], at: Double(round)) }
        let gate = Gate()
        let store = TicketBoardStore(source: source, sleep: gate.sleep)

        store.activate(team: "WM8")
        await settle { store.snapshot != nil && gate.count == 1 }
        XCTAssertEqual(store.snapshot?.tickets.map(\.key), ["WM8-1"])
        XCTAssertNil(store.lastError)

        gate.release()
        await settle { gate.count == 2 }
        XCTAssertEqual(store.snapshot?.tickets.map(\.key), ["WM8-2"], "nach dem Takt der nächste Abzug")
        store.deactivate()
    }

    func testDeactivateStopsFetching() async {
        let source = TicketSourceStub()
        source.onBoard = { _ in TicketFixtures.snapshot([]) }
        let gate = Gate()
        let store = TicketBoardStore(source: source, sleep: gate.sleep)
        store.activate(team: "WM8")
        await settle { gate.count == 1 }

        store.deactivate()
        XCTAssertFalse(store.isActive)
        gate.release()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(source.calls.filter { $0 == "board WM8" }.count, 1, "verdeckt: kein weiterer Abruf")
        XCTAssertNotNil(store.snapshot, "der Abzug bleibt für das nächste Öffnen stehen")
    }

    func testActivateTwiceRunsOneLoop() async {
        let source = TicketSourceStub()
        source.onBoard = { _ in TicketFixtures.snapshot([]) }
        let gate = Gate()
        let store = TicketBoardStore(source: source, sleep: gate.sleep)
        store.activate(team: "WM8")
        store.activate(team: "WM8")
        await settle { gate.count == 1 }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(source.calls.count, 1)
        store.deactivate()
    }

    func testErrorKeepsLastSnapshot() async {
        let source = TicketSourceStub()
        var fail = false
        source.onBoard = { _ in
            if fail { throw TicketSourceError.network("-1009") }
            return TicketFixtures.snapshot([TicketFixtures.ticket(7)], at: 5)
        }
        let gate = Gate()
        let store = TicketBoardStore(source: source, sleep: gate.sleep)
        store.activate(team: "WM8")
        await settle { store.snapshot != nil && gate.count == 1 }

        fail = true
        gate.release()
        await settle { store.lastError != nil }
        XCTAssertEqual(store.lastError, .network("-1009"))
        XCTAssertEqual(store.snapshot?.tickets.map(\.key), ["WM8-7"], "alter Stand bleibt sichtbar")
        XCTAssertEqual(store.snapshot?.fetchedAt, Date(timeIntervalSince1970: 5), "sein Alter auch")

        fail = false
        await settle { gate.count == 2 }
        gate.release()
        await settle { store.lastError == nil }
        store.deactivate()
    }

    func testFirstLoadFailureShowsErrorWithoutSnapshot() async {
        let source = TicketSourceStub()
        source.onBoard = { _ in throw TicketSourceError.notConfigured }
        let gate = Gate()
        let store = TicketBoardStore(source: source, sleep: gate.sleep)
        store.activate(team: "WM8")
        await settle { store.lastError != nil }
        XCTAssertEqual(store.lastError, .notConfigured)
        XCTAssertNil(store.snapshot)
        store.deactivate()
    }

    func testSwitchingTeamDropsOldSnapshot() async {
        let source = TicketSourceStub()
        source.onBoard = { team in
            TicketBoardSnapshot(team: team, statuses: [], tickets: [], fetchedAt: Date(timeIntervalSince1970: 0))
        }
        let gate = Gate()
        let store = TicketBoardStore(source: source, sleep: gate.sleep)
        store.activate(team: "WM8")
        await settle { store.snapshot?.team == "WM8" }
        store.activate(team: "DS")
        XCTAssertNil(store.snapshot, "kein Board des alten Teams unter dem neuen Namen")
        await settle { store.snapshot?.team == "DS" }
        store.deactivate()
    }

    func testRefreshWithoutTeamDoesNothing() async {
        let source = TicketSourceStub()
        let store = TicketBoardStore(source: source)
        await store.refresh()
        XCTAssertTrue(source.calls.isEmpty)
    }
}

final class TicketConfigTests: XCTestCase {
    func testLongestProjectPathWins() {
        var config = TicketConfig()
        config.set(team: "wm8", forProject: "/Users/g/repos/whisperm8/")
        config.set(team: "DS", forProject: "/Users/g/repos")
        XCTAssertEqual(config.team(forDirectory: "/Users/g/repos/whisperm8"), "WM8", "Kürzel groß, Schrägstrich am Ende egal")
        XCTAssertEqual(config.team(forDirectory: "/Users/g/repos/whisperm8/.claude/worktrees/ticket-board"), "WM8", "Arbeitsordner gehören zum Projekt")
        XCTAssertEqual(config.team(forDirectory: "/Users/g/repos/ListM8"), "DS")
        XCTAssertNil(config.team(forDirectory: "/Users/g/repos-andere"), "kein Treffer auf bloßen Namensanfang")
        XCTAssertEqual(config.projectPath(forDirectory: "/Users/g/repos/whisperm8/Tests"), "/Users/g/repos/whisperm8")
        XCTAssertNil(config.onlyTeam)
        XCTAssertEqual(config.projectPaths(forTeam: "wm8"), ["/Users/g/repos/whisperm8"])
    }

    func testOnlyTeam() {
        var config = TicketConfig()
        XCTAssertNil(config.onlyTeam)
        config.set(team: "WM8", forProject: "/a")
        config.set(team: "WM8", forProject: "/b")
        XCTAssertEqual(config.onlyTeam, "WM8")
    }

    func testStoreRoundTripAndMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tickets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TicketConfigStore(fileURL: directory.appendingPathComponent("WhisperM8/tickets.json"))
        XCTAssertEqual(store.load(), TicketConfig(), "fehlende Datei: leere Zuordnung")
        var config = TicketConfig()
        config.set(team: "WM8", forProject: "/Users/g/repos/whisperm8")
        try store.save(config)
        XCTAssertEqual(store.load(), config)
        try Data("kaputt".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), TicketConfig(), "unlesbare Datei: leere Zuordnung statt Absturz")
    }
}
