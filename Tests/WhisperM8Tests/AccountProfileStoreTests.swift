import Foundation
import Observation
import XCTest
@testable import WhisperM8

/// WM8-101: Kontoprofile im Speicher statt Platten-I/O im Body. Gelesen wird
/// abseits des Main Threads, Salven von Anstößen werden zusammengelegt, und
/// ein unveränderter Stand löst keinen Neuaufbau der Seitenleiste aus.
@MainActor
final class AccountProfileStoreTests: XCTestCase {
    /// Zählt Lesevorgänge und merkt sich, ob einer auf dem Main Thread lief.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _loads = 0
        private var _onMain = false
        private var _snapshot: AccountProfileStore.Snapshot

        init(_ snapshot: AccountProfileStore.Snapshot) { _snapshot = snapshot }

        var loads: Int { lock.withLock { _loads } }
        var loadedOnMain: Bool { lock.withLock { _onMain } }
        func set(_ snapshot: AccountProfileStore.Snapshot) { lock.withLock { _snapshot = snapshot } }

        func load() -> AccountProfileStore.Snapshot {
            lock.withLock {
                _loads += 1
                if Thread.isMainThread { _onMain = true }
                return _snapshot
            }
        }
    }

    private static func snapshot(_ claudeNames: [String], undoable: Bool = false) -> AccountProfileStore.Snapshot {
        AccountProfileStore.Snapshot(
            claude: claudeNames.map { ClaudeAccountProfile(name: $0, configDir: URL(fileURLWithPath: "/tmp/\($0)")) },
            gpt: [], hasUndoableAccountMove: undoable)
    }

    private func settle(_ store: AccountProfileStore, loads: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while store.loadCount < loads, Date() < deadline { await Task.yield() }
    }

    func testFirstStateIsThereWithoutWaiting() {
        let store = AccountProfileStore(loader: .fixed(Self.snapshot(["main", "zweit"])))
        XCTAssertEqual(store.claudeProfiles.map(\.name), ["main", "zweit"])
    }

    func testRefreshReadsOffTheMainThreadAndPublishesChanges() async {
        let probe = Probe(Self.snapshot(["main"]))
        let store = AccountProfileStore(loader: .init { probe.load() }, initial: Self.snapshot(["main"]))
        probe.set(Self.snapshot(["main", "neu"], undoable: true))

        store.refresh()
        await settle(store, loads: 1)

        XCTAssertFalse(probe.loadedOnMain, "Lesen gehört nicht auf den Main Thread")
        XCTAssertEqual(store.claudeProfiles.map(\.name), ["main", "neu"])
        XCTAssertTrue(store.hasUndoableAccountMove)
    }

    func testABurstOfRefreshesReadsAtMostTwice() async {
        let probe = Probe(Self.snapshot(["main"]))
        let store = AccountProfileStore(loader: .init { probe.load() }, initial: Self.snapshot(["main"]))

        for _ in 0..<20 { store.refresh() }
        await settle(store, loads: 2)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(probe.loads, 2, "ein Lauf plus genau ein Nachlauf")
    }

    func testUnchangedStateDoesNotNotifyObservers() async {
        let state = Self.snapshot(["main"])
        let store = AccountProfileStore(loader: .fixed(state), initial: state)
        var notified = false
        withObservationTracking { _ = store.snapshot } onChange: { notified = true }

        store.refresh()
        await settle(store, loads: 1)

        XCTAssertFalse(notified, "gleicher Stand: die Seitenleiste rechnet nicht neu")
    }

    func testChangedStateNotifiesObservers() async {
        let probe = Probe(Self.snapshot(["main"]))
        let store = AccountProfileStore(loader: .init { probe.load() }, initial: Self.snapshot(["main"]))
        var notified = false
        withObservationTracking { _ = store.snapshot } onChange: { notified = true }

        probe.set(Self.snapshot(["main"], undoable: true))
        store.refresh()
        await settle(store, loads: 1)

        XCTAssertTrue(notified)
    }
}
