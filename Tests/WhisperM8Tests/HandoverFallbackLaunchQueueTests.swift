import XCTest
@testable import WhisperM8

/// Befund 3 (Dex): Nach dem Rückfall der Übernahme starten die Chats auch in
/// unterdrückten Grid-Panes. Die Absturz-Wiederaufnahme und das normale Grid
/// bleiben, wie sie sind (Vorgabe Jarvis 13.11.2026: beide Seiten festhalten).
@MainActor
final class HandoverFallbackLaunchQueueTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func queue() -> HandoverFallbackLaunchQueue {
        HandoverFallbackLaunchQueue(now: { self.clock }, spacing: 0.5, lifetime: 300)
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wm8-fallback-\(name)-\(UUID().uuidString).json")
    }

    func testQueuedChatsStartOneAfterAnother() {
        let queue = queue()
        let a = UUID(), b = UUID(), c = UUID()
        queue.schedule([a, b, c])
        XCTAssertEqual(queue.takeLaunchSlot(for: a), 0)
        XCTAssertEqual(queue.takeLaunchSlot(for: b), 0.5)
        XCTAssertEqual(queue.takeLaunchSlot(for: c), 1.0)
        XCTAssertNil(queue.takeLaunchSlot(for: a), "jeder Eintrag genau einmal")
    }

    /// Normales Grid: Ein Chat, den der Rückfall nicht vorgemerkt hat, startet
    /// in einer unterdrückten Pane nicht (Plan F9 bleibt).
    func testChatsNotFromTheFallbackDoNotStartInSuppressedPanes() {
        let queue = queue()
        queue.schedule([UUID()])
        XCTAssertNil(queue.takeLaunchSlot(for: UUID()))
    }

    func testOldEntriesAndForgottenOnesDoNotStart() {
        let queue = queue()
        let late = UUID(), elsewhere = UUID()
        queue.schedule([late, elsewhere])
        queue.forget(elsewhere)
        XCTAssertNil(queue.takeLaunchSlot(for: elsewhere), "schon über die Fokus-Pane gestartet")
        clock = clock.addingTimeInterval(301)
        XCTAssertNil(queue.takeLaunchSlot(for: late), "Pane erst viel später geöffnet")
    }

    /// Der Rückfall füllt die Warteschlange und merkt sich die Chats für den
    /// zweiten Schub; Dopplungen auf einer Sitzung kommen nicht hinein.
    func testFallbackResumeFillsTheQueue() throws {
        let store = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let windowStore = AgentWindowStore(persistence: store)
        let project = UUID()
        let first = try store.upsertSession(AgentChatSession(provider: .codex, projectID: project,
                                                             externalSessionID: "x", title: "a", status: .running))
        let double = try store.upsertSession(AgentChatSession(provider: .codex, projectID: project,
                                                              externalSessionID: "x", title: "b", status: .running,
                                                              createdAt: Date().addingTimeInterval(60)))
        let queue = queue()
        HandoverTakeService.scheduleFallbackResume([first.id, double.id], store: store, windowStore: windowStore,
                                                   runningSessionIDs: [], queue: queue)
        XCTAssertEqual(queue.scheduledThisLaunch, [first.id])
        XCTAssertNotNil(queue.takeLaunchSlot(for: first.id))
        XCTAssertNil(queue.takeLaunchSlot(for: double.id))
        XCTAssertEqual(store.loadWorkspace().sessions.first { $0.id == first.id }?.shouldLaunchOnOpen, true)
        XCTAssertNotEqual(store.loadWorkspace().sessions.first { $0.id == double.id }?.shouldLaunchOnOpen, true)
    }

    /// Absturz-Wiederaufnahme unverändert: Sie merkt zum Fortsetzen vor, füllt
    /// die Warteschlange aber nie (unterdrückte Panes warten auf die Auswahl).
    func testCrashRecoveryLeavesTheQueueAlone() throws {
        let store = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let windowStore = AgentWindowStore(persistence: store)
        let chat = try store.upsertSession(AgentChatSession(provider: .claude, projectID: UUID(), title: "c",
                                                            status: .running))
        let markerURL = tempURL("marker")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [chat.id])
        let resumed = AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(termination: .inert), windowStore: windowStore, store: store,
            isEnabled: true)
        XCTAssertEqual(resumed, [chat.id])
        XCTAssertNil(HandoverFallbackLaunchQueue.shared.takeLaunchSlot(for: chat.id))
    }

    // MARK: Reste aus Vics Review (13.11.2026)

    /// (1) Ein Chat, der selbst schon vorgemerkt ist, behält sein Flag; nur
    /// ein Chat, dessen Sitzung ein ANDERER führt, wird zurückgesetzt.
    func testAlreadyScheduledChatKeepsItsFlag() throws {
        let store = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let windowStore = AgentWindowStore(persistence: store)
        let chat = try store.upsertSession(AgentChatSession(provider: .codex, projectID: UUID(),
                                                            externalSessionID: "x", title: "a", status: .running))
        let queue = queue()
        HandoverTakeService.scheduleFallbackResume([chat.id], store: store, windowStore: windowStore,
                                                   runningSessionIDs: [], queue: queue)
        // Zweiter Schub mit demselben Chat (heute nicht möglich, Falle für später).
        HandoverTakeService.scheduleFallbackResume([chat.id], store: store, windowStore: windowStore,
                                                   runningSessionIDs: [], queue: queue)
        XCTAssertEqual(store.loadWorkspace().sessions.first { $0.id == chat.id }?.shouldLaunchOnOpen, true)
        let plan = AgentCollectiveStartPlanner.plan([chat.id], sessions: store.loadWorkspace().sessions,
                                                    alreadyStarted: [chat.id])
        XCTAssertNil(plan.keeperOf[chat.id], "kein anderer Halter")
    }

    /// (2) Die Absturz-Wiederaufnahme im selben Start startet keinen Codex-Chat
    /// auf der Sitzung eines übernommenen Chats.
    func testCrashRecoverySkipsADoubleOfAnAdoptedChat() throws {
        let store = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let windowStore = AgentWindowStore(persistence: store)
        let project = UUID()
        let adopted = try store.upsertSession(AgentChatSession(provider: .codex, projectID: project,
                                                               externalSessionID: "x", title: "übernommen",
                                                               status: .running, createdAt: Date().addingTimeInterval(60)))
        let notHandedOver = try store.upsertSession(AgentChatSession(provider: .codex, projectID: project,
                                                                     externalSessionID: "X", title: "nicht abgegeben",
                                                                     status: .running))
        let other = try store.upsertSession(AgentChatSession(provider: .codex, projectID: project,
                                                             externalSessionID: "y", title: "anderer", status: .running))
        let markerURL = tempURL("marker")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [adopted.id, notHandedOver.id, other.id])
        let resumed = AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(termination: .inert), windowStore: windowStore, store: store,
            isEnabled: true, handledByHandover: [adopted.id], alreadyStarted: [adopted.id])
        XCTAssertEqual(resumed, [other.id], "der ältere, nicht abgegebene Chat startet trotzdem nicht")
        XCTAssertNotEqual(store.loadWorkspace().sessions.first { $0.id == notHandedOver.id }?.shouldLaunchOnOpen, true)
    }

    /// Vic (3): Jeder Start der Ansicht verwirft den Eintrag, nicht nur der
    /// aus der unterdrückten Pane. Alle Startwege laufen über launchAfterCacheWarmup.
    func testEveryLaunchOfTheViewForgetsTheQueueEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("WhisperM8/Views/AgentSessionDetailView.swift"),
                              encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private func launchAfterCacheWarmup("))
        let body = text[start.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("HandoverFallbackLaunchQueue.shared.forget(session.id)"))
    }

    // MARK: Punkt 11: Rückfall für Chats ohne Sitzungs-ID

    private func launched(_ provider: AgentProvider, id: String? = nil, lastTurn: Date? = nil) -> AgentChatSession {
        var session = AgentChatSession(provider: provider, projectID: UUID(), externalSessionID: id, title: "t",
                                       status: .running)
        session.hasLaunchedInitialPrompt = true
        session.lastTurnAt = lastTurn
        return session
    }

    func testDecisionForChatsWithoutSessionID() {
        for provider in [AgentProvider.claude, .codex] {
            XCTAssertEqual(HandoverFallbackStart.decide(for: launched(provider), hadTurn: false, claudeRecoverable: false),
                           .startFresh, "\(provider): ohne Turn frisch")
            XCTAssertEqual(HandoverFallbackStart.decide(for: launched(provider), hadTurn: true, claudeRecoverable: false),
                           .keepStopped, "\(provider): mit Turn gestoppt")
            XCTAssertEqual(HandoverFallbackStart.decide(for: launched(provider, id: "x"), hadTurn: true, claudeRecoverable: false),
                           .resume, "\(provider): mit ID normal fortsetzen")
        }
        XCTAssertEqual(HandoverFallbackStart.decide(for: launched(.claude), hadTurn: true, claudeRecoverable: true),
                       .resume, "Claude: Hook-Ereignisse nennen die Sitzung")
        XCTAssertEqual(HandoverFallbackStart.decide(for: launched(.codex), hadTurn: true, claudeRecoverable: true),
                       .keepStopped, "Codex kennt diesen Weg nicht")
        var neverLaunched = launched(.codex)
        neverLaunched.hasLaunchedInitialPrompt = false
        XCTAssertEqual(HandoverFallbackStart.decide(for: neverLaunched, hadTurn: false, claudeRecoverable: false), .resume,
                       "nie gestartet: startet ohnehin frisch")
    }

    func testTurnEvidence() {
        let plain = launched(.codex)
        XCTAssertFalse(HandoverFallbackStart.hadTurn(plain, journal: [], hookEvents: nil))
        XCTAssertTrue(HandoverFallbackStart.hadTurn(launched(.codex, lastTurn: Date()), journal: [], hookEvents: nil))
        let working = ChatsStatusJournalEntry(at: Date(), sessionID: plain.id, from: "idle", to: "working", signal: "promptSubmitted",
                                              source: "hook")
        XCTAssertTrue(HandoverFallbackStart.hadTurn(plain, journal: [working], hookEvents: nil))
        XCTAssertTrue(HandoverFallbackStart.hadTurn(plain, journal: [],
                                                    hookEvents: Data(#"{"hook_event_name":"UserPromptSubmit"}"#.utf8)))
        XCTAssertFalse(HandoverFallbackStart.hadTurn(plain, journal: [],
                                                     hookEvents: Data(#"{"hook_event_name":"SessionStart"}"#.utf8)))
    }

    /// Im Rückfall: ohne Turn frisch (Flag zurück, vorgemerkt, Hinweis), mit
    /// Turn gestoppt (nicht vorgemerkt, Hinweis), je für Claude und Codex.
    func testFallbackStartsFreshOrKeepsStoppedWithNotice() throws {
        let store = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let windowStore = AgentWindowStore(persistence: store)
        var ids: [AgentProvider: (fresh: UUID, stopped: UUID)] = [:]
        for provider in [AgentProvider.claude, .codex] {
            let fresh = try store.upsertSession(launched(provider))
            let stopped = try store.upsertSession(launched(provider))
            ids[provider] = (fresh.id, stopped.id)
        }
        let withTurns = Set(ids.values.map(\.stopped))
        let queue = queue()
        HandoverTakeService.scheduleFallbackResume(
            ids.values.flatMap { [$0.fresh, $0.stopped] }, store: store, windowStore: windowStore,
            runningSessionIDs: [], queue: queue,
            hadTurn: { withTurns.contains($0.id) }, claudeRecoverable: { _ in false })
        let sessions = Dictionary(uniqueKeysWithValues: store.loadWorkspace().sessions.map { ($0.id, $0) })
        for (provider, pair) in ids {
            XCTAssertEqual(sessions[pair.fresh]?.hasLaunchedInitialPrompt, false, "\(provider): frisch")
            XCTAssertEqual(sessions[pair.fresh]?.shouldLaunchOnOpen, true)
            XCTAssertNotNil(queue.takeLaunchSlot(for: pair.fresh))
            XCTAssertNotNil(queue.takeNotice(for: pair.fresh))
            XCTAssertEqual(sessions[pair.stopped]?.hasLaunchedInitialPrompt, true, "\(provider): Verlauf bleibt")
            XCTAssertNotEqual(sessions[pair.stopped]?.shouldLaunchOnOpen, true, "\(provider): gestoppt")
            XCTAssertNil(queue.takeLaunchSlot(for: pair.stopped))
            XCTAssertNotNil(queue.takeNotice(for: pair.stopped))
        }
    }

    /// Absturz-Wiederaufnahme unverändert: Sie setzt keine Hinweise und setzt
    /// das Start-Flag nicht zurück.
    func testCrashRecoveryDoesNotStartFresh() throws {
        let store = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let windowStore = AgentWindowStore(persistence: store)
        let chat = try store.upsertSession(launched(.codex))
        let markerURL = tempURL("marker")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [chat.id])
        _ = AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(termination: .inert), windowStore: windowStore, store: store,
            isEnabled: true, alreadyStarted: [])
        XCTAssertEqual(store.loadWorkspace().sessions.first { $0.id == chat.id }?.hasLaunchedInitialPrompt, true)
        XCTAssertNil(HandoverFallbackLaunchQueue.shared.takeNotice(for: chat.id))
    }

    // MARK: Vic zu 41f220fc: „kein Turn“ belastbarer

    /// (1) Nach einer Rotation zählen auch die Einträge in `<datei>.1`.
    func testJournalRecentAlsoReadsTheRotatedFile() throws {
        let url = tempURL("journal")
        let chat = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // wie das Journal
        func line(_ to: String, _ at: TimeInterval) throws -> String {
            String(decoding: try encoder.encode(ChatsStatusJournalEntry(
                at: Date(timeIntervalSince1970: at), sessionID: chat, from: nil, to: to, signal: "s", source: "hook")),
                   as: UTF8.self)
        }
        try (try line("working", 1) + "\n").write(to: url.appendingPathExtension("1"), atomically: true, encoding: .utf8)
        try (try line("idle", 2) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let entries = ChatsStatusJournal.recent(sessionID: chat, limit: 10, fileURL: url)
        XCTAssertEqual(entries.map(\.to), ["working", "idle"], "älteste zuerst, auch aus der rotierten Datei")
        XCTAssertTrue(HandoverFallbackStart.hadTurn(launched(.codex), journal: entries, hookEvents: nil))
    }

    /// (2) Unabhängiger Beleg: ein ungebundener Verlauf desselben Anbieters im
    /// Projektordner, entstanden nach dem Anlegen des Chats.
    func testUnboundTranscriptInTheProjectCountsAsATurn() {
        let chat = launched(.codex)
        func indexed(_ id: String, provider: AgentProvider = .codex, cwd: String = "/p/projekt",
                     created: TimeInterval = 10) -> IndexedAgentSession {
            IndexedAgentSession(provider: provider, externalSessionID: id, cwd: cwd, title: "t", model: nil,
                                reasoningEffort: nil, createdAt: chat.createdAt.addingTimeInterval(created),
                                lastActivityAt: chat.createdAt.addingTimeInterval(created))
        }
        func check(_ items: [IndexedAgentSession], bound: Set<String> = []) -> Bool {
            HandoverFallbackStart.hasUnboundTranscript(for: chat, projectPath: "/p/projekt", indexed: items, boundIDs: bound)
        }
        XCTAssertTrue(check([indexed("a")]), "ungebunden, danach entstanden")
        XCTAssertFalse(check([indexed("a", created: 600)], bound: ["a"]), "gehört schon einem Chat, später entstanden")
        XCTAssertTrue(check([indexed("a", created: 20)], bound: ["a"]), "Altlast: gebunden, aber im Fenster um den Start")
        XCTAssertTrue(check([indexed("a", cwd: "/p/projekt/.claude/worktrees/feature-x")]), "Claude-Worktree zählt zum Projekt")
        XCTAssertFalse(check([indexed("a", created: -60)]), "älter als der Chat")
        XCTAssertFalse(check([indexed("a", provider: .claude)]), "anderer Anbieter")
        XCTAssertFalse(check([indexed("a", cwd: "/p/anders")]), "anderer Ordner")
        XCTAssertFalse(check([]))
    }

    /// (3) Der Hinweis sagt ehrlich, dass ein Start-Prompt nicht noch einmal läuft.
    func testFreshStartNoticeMentionsThePrompt() {
        XCTAssertTrue(HandoverFallbackStart.startFresh.notice?.contains("not sent again") == true)
        // Alltagssprache (Jarvis, 13.11.2026): keine Fachwörter im Hinweis.
        for notice in [HandoverFallbackStart.startFresh.notice, HandoverFallbackStart.keepStopped.notice].compactMap({ $0 }) {
            for word in ["session ID", "bound", "turn", "prompt"] {
                XCTAssertFalse(notice.localizedCaseInsensitiveContains(word), "„\(word)“ in: \(notice)")
            }
        }
    }

    /// Vic (Leistung): recent dekodiert nur Zeilen mit der UUID der Sitzung.
    func testLineRangesFindOnlyLinesWithTheNeedle() {
        let text = "aaa\nx-NADEL-1\nbbb\ny NADEL\n\nNADEL"
        let data = Data(text.utf8)
        let lines = ChatsStatusJournal.lineRanges(containing: Array("NADEL".utf8), in: data)
            .map { String(decoding: data.subdata(in: $0), as: UTF8.self) }
        XCTAssertEqual(lines, ["x-NADEL-1", "y NADEL", "NADEL"])
        XCTAssertTrue(ChatsStatusJournal.lineRanges(containing: Array("fehlt".utf8), in: data).isEmpty)
    }
}
