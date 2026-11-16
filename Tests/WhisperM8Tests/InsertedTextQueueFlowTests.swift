import XCTest
@testable import WhisperM8

/// WM8-121, der Ablauf aus dem Befund über die echten Bausteine: ein laufender
/// Terminal-Controller (hält die Entwurfs-Schätzung und liest den Bildschirm),
/// der Status-Koordinator (meldet den Turn-Start, stößt am Turn-Ende die
/// Warteschlange an) und die Entscheidung der Warteschlange, so
/// zusammengesetzt wie in `AgentPromptQueueDelivery.deliverNow`.
///
/// Nicht über die Tastatur und nicht über `sendPrompt`: Beide fragen den
/// geteilten Status-Koordinator der App. Eingefügt wird deshalb über
/// `noteComposerTextInserted` (dieselbe Schätzung wie beim Einfügen ohne
/// Enter), abgeschickt über `submitComposer` (`chats submit`).
@MainActor
final class InsertedTextQueueFlowTests: XCTestCase {
    private var tempDir: URL!
    private var controller: AgentTerminalController!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inserted-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controller?.terminate()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private final class PosterSpy: AgentUserNotificationPosting {
        func post(_ notification: AgentSessionUserNotification) {}
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private struct Fixture {
        var coordinator: AgentSessionStatusCoordinator
        var sessionID: UUID
        var deliveries: Box<[UUID]>
    }

    private func makeFixture() throws -> Fixture {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let session = try store.createSession(
            provider: .claude, projectPath: tempDir.path, title: "Jarvis Testlauf", initialPrompt: nil)
        try store.updateSession(id: session.id) { $0.externalSessionID = "ext-121" }
        let coordinator = AgentSessionStatusCoordinator(
            store: store,
            hookBridge: ClaudeHookBridge(paths: ClaudeHookPaths(rootDirectory: tempDir)),
            notificationPoster: PosterSpy(),
            playSound: { _ in },
            loadPreferences: {
                AgentStatusPreferences(hooksEnabled: true, stopNotificationEnabled: false,
                                       awaitingNotificationEnabled: false, stopSoundEnabled: false,
                                       stopSoundName: "Glass")
            },
            launchGraceSeconds: 999)
        coordinator.terminalExternalIDUpdater = { _, _ in }
        coordinator.gptModelsFragmentResolver = { _ in nil }
        coordinator.sharedMemoryFragmentResolver = { _, _ in nil }
        coordinator.isRegistryStatusEnabled = { true }
        coordinator.registryRecordLookup = { _ in nil }
        coordinator.registryAwaitingNotificationDelay = 0
        coordinator.hasRunningTerminal = { _ in true }
        coordinator.freshTranscriptBeforeTurnEnd = { _, action in action() }
        coordinator.startupInputVisible = { _ in true }
        let deliveries = Box<[UUID]>([])
        coordinator.deliverQueued = { deliveries.value.append($0) }

        // Echter Controller mit Claude-Profil; der Prozess ist nur ein Platzhalter.
        let controller = AgentTerminalController(
            sessionID: session.id,
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", "sleep 30"],
                                        workingDirectory: NSTemporaryDirectory(), keyboardProfile: .claudeCodeChat),
            onLaunched: {}, onTerminated: { _ in })
        controller.start()
        // Ohne Fenster hat die Ansicht keine Größe; Claude zeichnet in eine echte.
        controller.terminal.getTerminal().resize(cols: 100, rows: 30)
        self.controller = controller
        coordinator.noteTurnStartedInTerminal = { [weak controller] id in
            if id == controller?.sessionID { controller?.noteTurnStarted() }
        }

        coordinator.sessionLaunched(sessionID: session.id)
        coordinator.handleRegistryRecord(record("idle"))
        return Fixture(coordinator: coordinator, sessionID: session.id, deliveries: deliveries)
    }

    private func record(_ status: String) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            profileName: "RankM8", pid: 4711, sessionID: "ext-121", cwd: nil, kind: "interactive",
            name: "repo", rawStatus: status, status: ClaudeRegistryStatus(rawValue: status),
            waitingFor: nil, statusUpdatedAt: Date(timeIntervalSince1970: 1_794_000_000),
            messagingSocketPath: "/tmp/cc-socks/4711.sock", procStart: nil, version: "2.1.325")
    }

    /// Ein Turn, den der Chat von selbst beginnt (Hintergrund-Befehl fertig).
    private func ownTurn(_ f: Fixture) {
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.handleRegistryRecord(record("idle"))
    }

    private func queueDecision(_ f: Fixture) -> PromptDeliveryGate.Decision {
        AgentPromptQueueDelivery.gateDecision(
            draft: controller.composerDraft,
            field: controller.controllerScreenSnapshot()?.promptField,
            profile: controller.command.keyboardProfile,
            runtime: f.coordinator.statusStore.status(for: f.sessionID),
            lifecycle: f.coordinator.lifecycleState(for: f.sessionID),
            inputPending: f.coordinator.startupInputPending(f.sessionID))
    }

    /// Verlauf, dann Claudes Eingabefeld mit `text`; danach ganz unten.
    private func drawClaude(fieldText text: String) {
        // Zwei Leerzeilen Platz und zurück: Das Feld darf beim Zeichnen nicht
        // scrollen, sonst landet der gespeicherte Cursor auf der Linie darunter.
        let history = (1...200).map { "Verlauf \($0)" }.joined(separator: "\r\n") + "\r\n\r\n\r\n\u{1b}[2A"
        controller.terminal.feed(text: history + InsertedTextScreen.bottom(text: text))
        controller.scrollHistoryToBottom()
    }

    private func scrollUp() {
        controller.terminal.scrollUp(lines: 40)
    }

    // MARK: Text darf nicht hinaus

    func testInsertedTextHoldsTheQueueAfterTheChatsOwnTurnWhileScrolledUp() throws {
        let f = try makeFixture()
        XCTAssertTrue(controller.isRunning)
        drawClaude(fieldText: "Triage: WM8-12 schließen, WM8-13 zurückstellen")
        controller.noteComposerTextInserted()   // „→ Jarvis“ / Diktat ohne Senden
        XCTAssertEqual(queueDecision(f), .draftPending)

        let before = f.deliveries.value.count
        ownTurn(f)
        XCTAssertEqual(f.deliveries.value.count, before + 1, "das Turn-Ende stößt die Warteschlange an")
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .idle)

        // Ganz unten fängt auch die Bildschirmprüfung den Text ab …
        XCTAssertEqual(queueDecision(f), .draftPending)
        XCTAssertTrue(PromptSubmitCheck.visibleDraft(
            field: controller.controllerScreenSnapshot()?.promptField, profile: .claudeCodeChat,
            clearsBeforeSubmit: false), "Gegenprobe: der Bildschirm ist richtig nachgebaut")
        // … hochgescrollt liest sie nichts ab; dann hält allein der Vermerk.
        scrollUp()
        XCTAssertTrue(controller.isScrolledBack)
        XCTAssertNil(controller.controllerScreenSnapshot())
        XCTAssertEqual(queueDecision(f), .draftPending, "vorher: .deliver, und die Meldung hing am Text")
        XCTAssertEqual(AgentPromptQueueDelivery.draftPendingError(controller.composerDraft),
                       AgentPromptQueueDelivery.insertedTextError)
    }

    // MARK: Die Schlange darf nicht verstopfen

    func testSubmittedTextDoesNotHoldTheQueueAfterTheTurn() throws {
        let f = try makeFixture()
        drawClaude(fieldText: "Weiter mit WM8-12")
        controller.noteComposerTextInserted()
        controller.submitComposer()            // abgeschickt
        drawClaude(fieldText: "")
        ownTurn(f)
        scrollUp()
        XCTAssertNil(controller.controllerScreenSnapshot())
        XCTAssertEqual(queueDecision(f), .deliver, "stellt zu wie bisher")
    }

    /// Weg ins Freie, wenn der Vermerk falsch stehen bleibt (Text mit der
    /// Rücktaste gelöscht): Sobald das Terminal unten steht und das Feld leer
    /// ist, geht die Meldung beim nächsten Versuch raus.
    func testEmptyFieldAtTheBottomReleasesAStaleMark() throws {
        let f = try makeFixture()
        drawClaude(fieldText: "Triage: WM8-12 schließen")
        controller.noteComposerTextInserted()
        ownTurn(f)
        drawClaude(fieldText: "")              // per Rücktaste geleert
        scrollUp()
        XCTAssertEqual(queueDecision(f), .draftPending, "hochgescrollt: nicht ablesbar, wartet")
        controller.scrollHistoryToBottom()
        XCTAssertFalse(controller.isScrolledBack)
        XCTAssertEqual(queueDecision(f), .deliver)
    }

    func testControlCReleasesInsertedText() throws {
        let f = try makeFixture()
        drawClaude(fieldText: "Triage: WM8-12 schließen")
        controller.noteComposerTextInserted()
        ownTurn(f)
        controller.noteComposerCleared()       // Feld geleert (Controller R3 halten)
        scrollUp()
        XCTAssertEqual(queueDecision(f), .deliver)
    }
}
