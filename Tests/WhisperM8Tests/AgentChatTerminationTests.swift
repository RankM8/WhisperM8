import XCTest
@testable import WhisperM8

/// Ende-Meldung eines Chats ohne Ansicht (Umbau 13.11.2026, Auflage 3 der
/// zweiten Meinung zum Neustart ohne Chatverlust). Belegt, dass Start, Ende
/// und gescheitertes Andocken sich wie vorher verhalten: Store `running` →
/// `closed`, danach der Statuskoordinator, danach die Ansicht; bei einem
/// Store-Fehler kein Koordinator; schnell gescheitertes `claude attach` wird
/// wie bisher erkannt.
@MainActor
final class AgentChatTerminationTests: XCTestCase {
    private var storeURL: URL!
    private var store: AgentSessionStore!

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-chat-ende-\(UUID().uuidString)")
            .appendingPathComponent("AgentSessions.json")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        store = AgentSessionStore(fileURL: storeURL,
                                  uiStateFileURL: storeURL.deletingLastPathComponent().appendingPathComponent("ui.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    private func session(_ status: AgentChatStatus) throws -> AgentChatSession {
        try store.upsertSession(AgentChatSession(provider: .claude, projectID: UUID(), title: "t", status: status))
    }

    private func status(of id: UUID) -> AgentChatStatus? {
        store.loadWorkspace().sessions.first { $0.id == id }?.status
    }

    /// Protokoll der Reihenfolge: Start, Laufend-Satz; beim Ende Store,
    /// Koordinator, Ansicht, Laufend-Satz.
    private final class Log {
        var entries: [String] = []
    }

    private func termination(_ log: Log, failing: Bool = false) -> AgentChatTermination {
        let backed = AgentChatTermination.storeBacked(store) { _, exitCode in
            log.entries.append("status \(exitCode.map(String.init) ?? "nil")")
        }
        return AgentChatTermination(
            markClosed: { id in
                if failing { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "kaputt"]) }
                try backed.markClosed(id)
                log.entries.append("store")
            },
            notifyStatus: backed.notifyStatus)
    }

    private func command(_ script: String, attachFallback: Bool = false) -> AgentLaunchCommand {
        AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", script],
                           workingDirectory: NSTemporaryDirectory(), keyboardProfile: .plainShell,
                           isBackgroundAttachFallback: attachFallback)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    // MARK: Ende über die Registry, ohne Ansicht

    func testNaturalEndClosesSessionThenNotifiesStatusThenView() throws {
        let chat = try session(.running)
        let log = Log()
        let registry = AgentTerminalRegistry(sleep: { _ in }, termination: termination(log))
        registry.onRunningSetChanged = { log.entries.append("running \($0.count)") }
        var outcome: AgentChatTermination.Outcome?
        registry.startController(sessionID: chat.id, command: command("exit 3"),
                                 onLaunched: { log.entries.append("launched") },
                                 onTerminated: { outcome = $0; log.entries.append("view") })

        XCTAssertTrue(waitFor { outcome != nil })
        XCTAssertEqual(status(of: chat.id), .closed)
        XCTAssertEqual(outcome?.exitCode, 3 << 8, "Wartestatus wie bisher (waitpid-Format)")
        XCTAssertEqual(outcome?.quickFailedAttach, false)
        XCTAssertNil(outcome?.errorDescription)
        XCTAssertEqual(log.entries, ["launched", "running 1", "store", "status 768", "view", "running 0"])
    }

    func testEndWithoutAnyViewStillClosesSession() throws {
        let chat = try session(.running)
        let log = Log()
        let registry = AgentTerminalRegistry(sleep: { _ in }, termination: termination(log))
        // Keine Ansicht: der Aufrufer reicht leere Closures (wie ein Chat,
        // dessen Tab nie geöffnet war).
        registry.startController(sessionID: chat.id, command: command("exit 0"),
                                 onLaunched: {}, onTerminated: { _ in })
        XCTAssertTrue(waitFor { self.status(of: chat.id) == .closed })
        XCTAssertTrue(waitFor { log.entries.contains("status 0") })
    }

    func testOnlyRunningSessionsAreClosed() throws {
        let archived = try session(.archived)
        _ = termination(Log()).handle(sessionID: archived.id, exitCode: 0, endedController: nil)
        XCTAssertEqual(status(of: archived.id), .archived)
    }

    func testStoreErrorSkipsStatusAndHandsErrorToView() {
        let log = Log()
        let outcome = termination(log, failing: true).handle(sessionID: UUID(), exitCode: 0, endedController: nil)
        XCTAssertEqual(outcome.errorDescription, "kaputt")
        XCTAssertTrue(log.entries.isEmpty, "Koordinator nur nach geschriebenem Status (wie bisher)")
    }

    // MARK: Gescheitertes Andocken

    func testQuickFailedAttachIsDetectedForSelfEndedAttachFallback() throws {
        let chat = try session(.running)
        let registry = AgentTerminalRegistry(sleep: { _ in }, termination: termination(Log()))
        var outcome: AgentChatTermination.Outcome?
        registry.startController(sessionID: chat.id, command: command("exit 1", attachFallback: true),
                                 onLaunched: {}, onTerminated: { outcome = $0 })
        XCTAssertTrue(waitFor { outcome != nil })
        XCTAssertEqual(outcome?.quickFailedAttach, true)
        XCTAssertEqual(status(of: chat.id), .closed)
    }

    func testAttachEndedByTheAppIsNoFailure() throws {
        // `terminate()` nimmt den Controller vorher aus der Registry; dann
        // kommt kein Controller an und es ist kein gescheitertes Andocken.
        let outcome = termination(Log()).handle(sessionID: UUID(), exitCode: 1 << 8, endedController: nil)
        XCTAssertFalse(outcome.quickFailedAttach)
    }

    func testAttachFailureRulesMatchTheRecoveryHelper() throws {
        let controller = AgentTerminalController(
            sessionID: UUID(), command: command("sleep 30", attachFallback: true),
            onLaunched: {}, onTerminated: { _ in })
        controller.start()
        defer { controller.terminate() }
        let started = try XCTUnwrap(controller.startedAt)
        func outcome(exit: Int32?, after seconds: TimeInterval, attach: AgentTerminalController? = nil) -> Bool {
            var handler = termination(Log())
            handler.now = { started.addingTimeInterval(seconds) }
            return handler.handle(sessionID: UUID(), exitCode: exit, endedController: attach ?? controller).quickFailedAttach
        }
        XCTAssertTrue(outcome(exit: 1 << 8, after: 1))
        XCTAssertFalse(outcome(exit: 0, after: 1), "Exit 0 ist kein Scheitern")
        XCTAssertFalse(outcome(exit: 1 << 8, after: AgentAttachRecovery.quickFailureWindow + 1), "lief zu lange")
        XCTAssertFalse(outcome(exit: SIGKILL, after: 1), "Signal statt Exit-Code")

        let plain = AgentTerminalController(sessionID: UUID(), command: command("sleep 30"),
                                            onLaunched: {}, onTerminated: { _ in })
        plain.start()
        defer { plain.terminate() }
        XCTAssertFalse(outcome(exit: 1 << 8, after: 1, attach: plain), "nur der Attach-Rückweg zählt")
    }

    // MARK: Start

    func testStartReportsLaunchAndRunningSetAndReturnsRunningController() throws {
        let chat = try session(.pending)
        let log = Log()
        let registry = AgentTerminalRegistry(sleep: { _ in }, termination: termination(log))
        registry.onRunningSetChanged = { log.entries.append("running \($0.count)") }
        let controller = registry.startController(sessionID: chat.id, command: command("sleep 30"),
                                                  onLaunched: { log.entries.append("launched") },
                                                  onTerminated: { _ in })
        defer { registry.terminate(sessionID: chat.id) }
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(registry.activeSessionIDs, [chat.id])
        XCTAssertEqual(log.entries, ["launched", "running 1"], "onLaunched läuft in start(), vor der Meldung des Laufend-Satzes")
        // Zweiter Start liefert denselben laufenden Controller (Doppelstart-Schutz).
        let again = registry.startController(sessionID: chat.id, command: command("sleep 30"),
                                             onLaunched: { log.entries.append("launched again") },
                                             onTerminated: { _ in })
        XCTAssertTrue(again === controller)
        XCTAssertFalse(log.entries.contains("launched again"))
    }

    func testTerminateByTheAppSkipsViewOutcome() throws {
        let chat = try session(.running)
        let log = Log()
        let registry = AgentTerminalRegistry(sleep: { _ in }, termination: termination(log))
        var outcomes = 0
        registry.startController(sessionID: chat.id, command: command("sleep 30"),
                                 onLaunched: {}, onTerminated: { _ in outcomes += 1 })
        registry.terminate(sessionID: chat.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // Wie vorher: SwiftTerm meldet nach `terminate()` kein Prozessende.
        XCTAssertEqual(outcomes, 0)
        XCTAssertFalse(log.entries.contains("store"))
    }
}
