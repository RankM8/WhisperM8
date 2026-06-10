import Foundation
import XCTest
@testable import WhisperM8

final class AgentWorkspaceStoreTests: XCTestCase {
    private final class PersistSpy: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var saved: [AgentWorkspace] = []
        var failNextSave = false

        func persist(_ workspace: AgentWorkspace) throws {
            lock.lock()
            defer { lock.unlock() }
            if failNextSave {
                failNextSave = false
                throw CocoaError(.fileWriteNoPermission)
            }
            saved.append(workspace)
        }

        var saveCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return saved.count
        }
    }

    private func makeSession(projectID: UUID = UUID(), title: String = "Chat") -> AgentChatSession {
        AgentChatSession(
            provider: .claude,
            projectID: projectID,
            title: title,
            createdManually: true
        )
    }

    func testMutationPersistsOnceAndNoOpDoesNot() throws {
        let spy = PersistSpy()
        let store = AgentWorkspaceStore(
            loadInitial: { .empty },
            persist: { try spy.persist($0) }
        )

        let session = makeSession()
        try store.mutate { $0.sessions.append(session) }
        XCTAssertEqual(spy.saveCount, 1)

        // No-op-Mutation: Equatable-Diff verhindert den Save.
        try store.mutate { workspace in
            workspace.sessions = workspace.sessions
        }
        XCTAssertEqual(spy.saveCount, 1, "Unveränderter Workspace darf nicht erneut persistiert werden")
    }

    func testConcurrentMutationsLoseNoUpdates() throws {
        let store = AgentWorkspaceStore(
            loadInitial: { .empty },
            persist: { _ in }
        )
        let projectID = UUID()

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            try? store.mutate { workspace in
                workspace.sessions.append(self.makeSession(projectID: projectID, title: "S\(index)"))
            }
        }

        let count = store.read { $0.sessions.count }
        XCTAssertEqual(count, 100, "Alle 100 parallelen Mutationen müssen ankommen (kein Lost Update)")
    }

    func testNormalizeRunsAfterEveryMutation() throws {
        // normalize entfernt hier alle Sessions mit Titel "weg" — Stellvertreter
        // für die Migrations-Prunes (removeUnresumableClaudeSessions etc.).
        let store = AgentWorkspaceStore(
            loadInitial: { .empty },
            persist: { _ in },
            normalize: { workspace in
                var result = workspace
                result.sessions.removeAll { $0.title == "weg" }
                return result
            }
        )

        try store.mutate { workspace in
            workspace.sessions.append(self.makeSession(title: "bleibt"))
            workspace.sessions.append(self.makeSession(title: "weg"))
        }

        XCTAssertEqual(store.read { $0.sessions.map(\.title) }, ["bleibt"])
    }

    func testRegistryReturnsSameInstancePerURL() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWorkspaceStoreTests-\(UUID().uuidString).json")
        let a = AgentWorkspaceStoreRegistry.store(for: url)
        let b = AgentWorkspaceStoreRegistry.store(for: url)
        XCTAssertTrue(a === b, "Gleiche fileURL muss denselben Kern liefern")
    }

    /// Der Race-Regressionstest aus Plan P1 Schritt 3: UI-Mutationen und
    /// Indexer-Merge laufen parallel über ZWEI Facade-Kopien mit derselben
    /// fileURL. Auf dem alten Code (Voll-Load+Voll-Save pro Mutation ohne
    /// Lock) verlor dieser Test Updates (Last-Writer-Wins auf Dateiebene).
    func testParallelFacadeWritersLoseNothing() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWorkspaceStoreRace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let storeA = AgentSessionStore(fileURL: fileURL)
        let storeB = AgentSessionStore(fileURL: fileURL)
        let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)
        let session = makeSession(projectID: project.id, title: "Start")
        try storeA.saveWorkspace(AgentWorkspace(projects: [project], sessions: [session]))

        let indexed = (0..<10).map { index in
            IndexedAgentSession(
                provider: .codex,
                externalSessionID: "ext-\(index)",
                cwd: FileManager.default.temporaryDirectory.path,
                title: "Indexed \(index)",
                createdAt: Date(timeIntervalSince1970: 1_000),
                lastActivityAt: Date(timeIntervalSince1970: 2_000)
            )
        }

        DispatchQueue.concurrentPerform(iterations: 110) { index in
            if index < 100 {
                try? storeA.updateSession(id: session.id) { $0.title = "Update \(index)" }
            } else {
                try? storeB.mergeIndexedSessions([indexed[index - 100]])
            }
        }

        let workspace = storeA.loadWorkspace()
        XCTAssertTrue(workspace.sessions.first { $0.id == session.id }!.title.hasPrefix("Update "))
        let mergedCount = workspace.sessions.filter { $0.externalSessionID?.hasPrefix("ext-") == true }.count
        XCTAssertEqual(mergedCount, 10, "Alle 10 Merge-Effekte müssen neben den 100 Updates überleben")
    }

    // MARK: - Debounced Persistenz (P1 Schritt 4)

    func testDebouncedPolicyCoalescesSaves() throws {
        let spy = PersistSpy()
        let store = AgentWorkspaceStore(
            loadInitial: { .empty },
            persist: { try spy.persist($0) },
            policy: .debounced(0.05)
        )

        for index in 0..<5 {
            try store.mutate { $0.sessions.append(self.makeSession(title: "S\(index)")) }
        }
        XCTAssertEqual(spy.saveCount, 0, "Innerhalb des Debounce-Fensters darf nichts geschrieben sein")

        let deadline = Date().addingTimeInterval(2.0)
        while spy.saveCount == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(spy.saveCount, 1, "5 Mutationen müssen zu genau einem Save gebündelt werden")
        XCTAssertEqual(spy.saved.last?.sessions.count, 5)
    }

    func testFlushWritesImmediately() throws {
        let spy = PersistSpy()
        let store = AgentWorkspaceStore(
            loadInitial: { .empty },
            persist: { try spy.persist($0) },
            policy: .debounced(10)
        )

        try store.mutate { $0.sessions.append(self.makeSession()) }
        XCTAssertEqual(spy.saveCount, 0)

        store.flush()
        XCTAssertEqual(spy.saveCount, 1)
    }

    func testFailedDebouncedSaveRetriesOnNextFlush() throws {
        let spy = PersistSpy()
        let store = AgentWorkspaceStore(
            loadInitial: { .empty },
            persist: { try spy.persist($0) },
            policy: .debounced(10)
        )

        try store.mutate { $0.sessions.append(self.makeSession()) }
        spy.failNextSave = true
        store.flush()
        XCTAssertEqual(spy.saveCount, 0, "Fehlgeschlagener Save zählt nicht")

        // dirty-Flag muss gesetzt geblieben sein → Retry beim nächsten Flush.
        store.flush()
        XCTAssertEqual(spy.saveCount, 1)
    }
}
