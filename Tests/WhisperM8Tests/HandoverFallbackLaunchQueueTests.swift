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
}
