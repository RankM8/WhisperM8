import XCTest
@testable import WhisperM8

// MARK: - Reine Warteschlangen-Logik

final class AgentPromptQueueLogicTests: XCTestCase {
    private let session = UUID()
    private let other = UUID()
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func prompt(
        _ text: String, session: UUID? = nil, offset: TimeInterval = 0,
        state: QueuedPrompt.State = .pending, id: UUID = UUID()
    ) -> QueuedPrompt {
        QueuedPrompt(id: id, sessionID: session ?? self.session, prompt: text,
                     enqueuedAt: base.addingTimeInterval(offset), enqueuedBy: "tester", state: state)
    }

    func testOpenPromptsAreFIFOAndScopedToSession() {
        let all = [
            prompt("zweiter", offset: 20),
            prompt("fremder", session: other, offset: 5),
            prompt("erster", offset: 10),
        ]
        let open = AgentPromptQueueLogic.openPrompts(for: session, in: all)
        XCTAssertEqual(open.map(\.prompt), ["erster", "zweiter"], "Einstell-Reihenfolge entscheidet")
    }

    func testOrderIsStableForIdenticalTimestamps() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let all = [prompt("b", id: b), prompt("a", id: a)]
        XCTAssertEqual(AgentPromptQueueLogic.openPrompts(for: session, in: all).map(\.prompt), ["a", "b"],
                       "gleiche Zeit → stabile Ordnung über die ID, nie zufällig")
    }

    func testClosedStatesAreNotOpen() {
        for state: QueuedPrompt.State in [.delivered, .cancelled, .failed] {
            let all = [prompt("x", state: state)]
            XCTAssertTrue(AgentPromptQueueLogic.openPrompts(for: session, in: all).isEmpty, state.rawValue)
            XCTAssertTrue(AgentPromptQueueLogic.visiblePrompts(for: session, in: all).isEmpty, state.rawValue)
        }
    }

    func testUnknownIsNotCountedAsWaitingButStaysVisible() {
        // Beides muss gelten: nicht als „wartet" zählen (es wird nie
        // zugestellt) UND trotzdem angezeigt werden (jemand muss entscheiden).
        let all = [prompt("unklar", state: .unknown)]
        XCTAssertTrue(AgentPromptQueueLogic.openPrompts(for: session, in: all).isEmpty)
        XCTAssertEqual(AgentPromptQueueLogic.openCounts(in: all)[session], nil)
        XCTAssertEqual(AgentPromptQueueLogic.reviewCounts(in: all)[session], 1)
        XCTAssertEqual(AgentPromptQueueLogic.visiblePrompts(for: session, in: all).map(\.prompt), ["unklar"])
    }

    func testVisibleListsWaitingBeforeUnclear() {
        let all = [prompt("unklar", offset: 0, state: .unknown), prompt("wartet", offset: 10)]
        XCTAssertEqual(AgentPromptQueueLogic.visiblePrompts(for: session, in: all).map(\.prompt),
                       ["wartet", "unklar"], "was noch kommt, steht oben")
    }

    func testNextDeliverableIsBlockedWhileOneIsInFlight() {
        // Zwei parallele Pastes in dieselbe PTY würden die Reihenfolge
        // zerstören und Text ineinander schieben.
        let all = [
            prompt("laeuft", offset: 0, state: .delivering),
            prompt("wartet", offset: 10),
        ]
        XCTAssertNil(AgentPromptQueueLogic.nextDeliverable(for: session, in: all))
    }

    func testNextDeliverableReturnsOldestPending() {
        let all = [prompt("neu", offset: 30), prompt("alt", offset: 5)]
        XCTAssertEqual(AgentPromptQueueLogic.nextDeliverable(for: session, in: all)?.prompt, "alt")
    }

    func testNextDeliverableIgnoresOtherSessions() {
        XCTAssertNil(AgentPromptQueueLogic.nextDeliverable(for: session, in: [prompt("x", session: other)]))
    }

    func testOpenCountsPerSession() {
        let all = [
            prompt("a"), prompt("b", offset: 1),
            prompt("c", session: other),
            prompt("weg", state: .delivered),
        ]
        let counts = AgentPromptQueueLogic.openCounts(in: all)
        XCTAssertEqual(counts[session], 2)
        XCTAssertEqual(counts[other], 1)
    }

    func testRestartMarksInFlightAsUnknownNotPending() {
        // Kern der Höchstens-einmal-Garantie: nach einem Absturz während der
        // Zustellung darf NICHT erneut gesendet werden.
        let all = [prompt("unterwegs", state: .delivering), prompt("wartet")]
        let recovered = AgentPromptQueueLogic.reconcileAfterRestart(all)
        XCTAssertEqual(recovered[0].state, .unknown)
        XCTAssertNotNil(recovered[0].lastError)
        XCTAssertEqual(recovered[1].state, .pending, "unangetastete Aufträge bleiben zustellbar")
        XCTAssertNil(AgentPromptQueueLogic.nextDeliverable(for: session, in: [recovered[0]]),
                     "unknown wird nie automatisch zugestellt")
    }

    func testPruneKeepsOpenAndUnknownButDropsOldFinished() {
        let now = base.addingTimeInterval(7_200)
        var delivered = prompt("alt-erledigt", state: .delivered)
        delivered.deliveredAt = base
        var fresh = prompt("frisch-erledigt", state: .delivered)
        fresh.deliveredAt = now.addingTimeInterval(-60)
        let all = [delivered, fresh, prompt("offen"), prompt("unklar", state: .unknown)]

        let kept = AgentPromptQueueLogic.pruned(all, now: now).map(\.prompt)
        XCTAssertFalse(kept.contains("alt-erledigt"), "abgeschlossen und älter als die Karenzzeit")
        XCTAssertTrue(kept.contains("frisch-erledigt"))
        XCTAssertTrue(kept.contains("offen"))
        XCTAssertTrue(kept.contains("unklar"), "unknown wird nie weggeräumt")
    }
}

// MARK: - Persistenz und Zustellreservierung

final class AgentPromptQueueStoreTests: XCTestCase {
    private var directory: URL!
    private var store: AgentPromptQueueStore!
    private let session = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AgentPromptQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEnqueuePersistsAndSurvivesReload() throws {
        store.enqueue(sessionID: session, prompt: "erster Auftrag", by: "jarvis")
        store.enqueue(sessionID: session, prompt: "zweiter Auftrag", by: "jarvis")

        let reloaded = AgentPromptQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        let open = reloaded.openPrompts(for: session)
        XCTAssertEqual(open.map(\.prompt), ["erster Auftrag", "zweiter Auftrag"],
                       "Aufträge überleben einen App-Neustart in Reihenfolge")
    }

    func testRapidEnqueuesKeepTheirOrder() {
        // Regression: mehrere Aufträge in derselben Millisekunde fielen früher
        // auf eine zufällige UUID-Sortierung zurück.
        let texts = (1...12).map { "Auftrag \($0)" }
        for text in texts {
            store.enqueue(sessionID: session, prompt: text, by: "jarvis")
        }
        XCTAssertEqual(store.openPrompts(for: session).map(\.prompt), texts)

        let reloaded = AgentPromptQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        XCTAssertEqual(reloaded.openPrompts(for: session).map(\.prompt), texts,
                       "Reihenfolge überlebt auch das Neuladen von Disk")
    }

    func testSequenceKeepsGrowingAcrossReloads() {
        store.enqueue(sessionID: session, prompt: "A", by: "jarvis")
        let reloaded = AgentPromptQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        let second = reloaded.enqueue(sessionID: session, prompt: "B", by: "jarvis")
        XCTAssertEqual(second.sequence, 2, "die Nummer setzt nach einem Neustart fort, statt neu zu zählen")
    }

    func testReserveNextIsExclusiveUntilResolved() {
        store.enqueue(sessionID: session, prompt: "A", by: "jarvis")
        store.enqueue(sessionID: session, prompt: "B", by: "jarvis")

        let first = store.reserveNext(for: session)
        XCTAssertEqual(first?.prompt, "A")
        XCTAssertNil(store.reserveNext(for: session), "solange A unterwegs ist, wird B nicht gegriffen")

        store.markDelivered(id: first!.id)
        XCTAssertEqual(store.reserveNext(for: session)?.prompt, "B")
    }

    func testDeliveringStateIsPersistedBeforeDelivery() throws {
        store.enqueue(sessionID: session, prompt: "unterwegs", by: "jarvis")
        _ = store.reserveNext(for: session)

        // Genau darauf beruht die Höchstens-einmal-Garantie: der Zustand muss
        // schon VOR dem Paste auf der Platte stehen.
        let onDisk = AgentPromptQueueStore.read(from: directory.appendingPathComponent("queue.json"))
        XCTAssertEqual(onDisk.first?.state, .delivering)
    }

    func testFailedWithRetryGoesBackToPending() {
        store.enqueue(sessionID: session, prompt: "A", by: "jarvis")
        let reserved = store.reserveNext(for: session)!

        store.markFailed(id: reserved.id, error: "keine PTY", retry: true)
        XCTAssertEqual(store.openPrompts(for: session).first?.state, .pending,
                       "ein nicht bereites Ziel darf den Auftrag nicht verlieren")
        XCTAssertEqual(store.reserveNext(for: session)?.prompt, "A", "wieder zustellbar")
    }

    func testFailedWithoutRetryClosesTheEntry() {
        store.enqueue(sessionID: session, prompt: "A", by: "jarvis")
        let reserved = store.reserveNext(for: session)!
        store.markFailed(id: reserved.id, error: "archiviert", retry: false)
        XCTAssertTrue(store.openPrompts(for: session).isEmpty)
        XCTAssertEqual(store.all().first?.state, .failed)
    }

    func testCancelAllRemovesOnlyPendingOnes() {
        store.enqueue(sessionID: session, prompt: "A", by: "jarvis")
        store.enqueue(sessionID: session, prompt: "B", by: "jarvis")
        let inFlight = store.reserveNext(for: session)!

        let cancelled = store.cancel(sessionID: session)
        XCTAssertEqual(cancelled.map(\.prompt), ["B"], "nur wartende Aufträge")
        XCTAssertEqual(store.all().first { $0.id == inFlight.id }?.state, .delivering,
                       "eine laufende Zustellung ist nicht mehr zurückholbar")
    }

    func testCancelSpecificIDLeavesOthersAlone() {
        let a = store.enqueue(sessionID: session, prompt: "A", by: "jarvis")
        store.enqueue(sessionID: session, prompt: "B", by: "jarvis")

        let cancelled = store.cancel(sessionID: session, ids: [a.id])
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(store.openPrompts(for: session).map(\.prompt), ["B"])
    }

    func testCancelDoesNotTouchOtherSessions() {
        let foreign = UUID()
        store.enqueue(sessionID: session, prompt: "meiner", by: "jarvis")
        store.enqueue(sessionID: foreign, prompt: "fremder", by: "jarvis")
        store.cancel(sessionID: session)
        XCTAssertEqual(store.openPrompts(for: foreign).map(\.prompt), ["fremder"])
    }

    func testReconcileOnLaunchMarksInterruptedDelivery() {
        store.enqueue(sessionID: session, prompt: "unterwegs", by: "jarvis")
        _ = store.reserveNext(for: session)

        let restarted = AgentPromptQueueStore(fileURL: directory.appendingPathComponent("queue.json"))
        restarted.reconcileOnLaunch()
        XCTAssertEqual(restarted.all().first?.state, .unknown)
        XCTAssertNil(restarted.reserveNext(for: session), "kein stiller Zweitversuch nach Absturz")
    }

    func testMissingFileYieldsEmptyQueueNotACrash() {
        let missing = AgentPromptQueueStore(fileURL: directory.appendingPathComponent("gibt-es-nicht.json"))
        XCTAssertTrue(missing.all().isEmpty)
    }
}

// MARK: - Ausgabe

final class ChatsQueueSupportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_600)
    private func make(_ state: QueuedPrompt.State, error: String? = nil) -> QueuedPrompt {
        QueuedPrompt(sessionID: UUID(), prompt: "Baue das Feature fertig",
                     enqueuedAt: Date(timeIntervalSince1970: 1_000_000),
                     enqueuedBy: "whisperm8/Jarvis", state: state, lastError: error)
    }

    func testPendingLineShowsPositionAndOrigin() {
        let line = ChatsQueueSupport.line(for: make(.pending), position: 2, now: now)
        XCTAssertTrue(line.hasPrefix("2."))
        XCTAssertTrue(line.contains("whisperm8/Jarvis"))
    }

    func testStatesAreVisuallyDistinct() {
        XCTAssertTrue(ChatsQueueSupport.line(for: make(.delivering), position: nil, now: now).contains("zugestellt"))
        XCTAssertTrue(ChatsQueueSupport.line(for: make(.cancelled), position: nil, now: now).contains("storniert"))
        XCTAssertTrue(ChatsQueueSupport.line(for: make(.failed, error: "keine PTY"), position: nil, now: now)
            .contains("keine PTY"))
    }

    func testUnknownStateSaysOutcomeIsUnclear() {
        let line = ChatsQueueSupport.line(for: make(.unknown), position: nil, now: now)
        XCTAssertTrue(line.contains("Ausgang unklar"))
        XCTAssertTrue(line.hasPrefix("⚠︎"))
    }

    func testMultilinePromptIsFlattenedAndTruncated() {
        var prompt = make(.pending)
        prompt.prompt = "Zeile eins\nZeile zwei " + String(repeating: "x", count: 200)
        let line = ChatsQueueSupport.line(for: prompt, position: 1, now: now)
        XCTAssertFalse(line.contains("\n"), "eine Zeile pro Auftrag")
        XCTAssertLessThan(line.count, 140)
    }

    func testSummaryIsNilWhenNothingWaits() {
        XCTAssertNil(ChatsQueueSupport.summary(open: []))
    }

    func testSummaryUsesSingularAndPluralAndFlagsInFlight() {
        XCTAssertEqual(ChatsQueueSupport.summary(open: [make(.pending)]), "1 Folgeauftrag wartet")
        XCTAssertEqual(ChatsQueueSupport.summary(open: [make(.pending), make(.pending)]),
                       "2 Folgeaufträge warten")
        XCTAssertTrue(ChatsQueueSupport.summary(open: [make(.delivering), make(.pending)])?
            .contains("wird gerade zugestellt") ?? false)
    }

    func testJSONCarriesStateAndPosition() {
        let dict = ChatsQueueSupport.json(for: make(.pending), position: 3)
        XCTAssertEqual(dict["state"] as? String, "pending")
        XCTAssertEqual(dict["position"] as? Int, 3)
        XCTAssertEqual(dict["promptChars"] as? Int, "Baue das Feature fertig".count)
    }
}
