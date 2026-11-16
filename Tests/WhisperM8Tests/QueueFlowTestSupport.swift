import XCTest
@testable import WhisperM8

/// Gerüst für Abläufe im Sendeweg über die echten Bausteine (WM8-121,
/// WM8-123): ein laufender Terminal-Controller mit Claude-Profil (hält die
/// Entwurfs-Schätzung und liest den Bildschirm), der Status-Koordinator
/// (meldet den Turn-Start, stößt am Turn-Ende die Warteschlange an) und die
/// Entscheidung der Warteschlange, so zusammengesetzt wie in
/// `AgentPromptQueueDelivery.deliverNow`.
///
/// Nicht über die Tastatur und nicht über `sendPrompt`: Beide fragen den
/// geteilten Status-Koordinator der App.
@MainActor
final class QueueFlowFixture {
    let coordinator: AgentSessionStatusCoordinator
    let sessionID: UUID
    let controller: AgentTerminalController
    private(set) var deliveries: [UUID] = []
    private let tempDir: URL

    private final class PosterSpy: AgentUserNotificationPosting {
        func post(_ notification: AgentSessionUserNotification) {}
    }

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let session = try store.createSession(
            provider: .claude, projectPath: tempDir.path, title: "Jarvis Testlauf", initialPrompt: nil)
        try store.updateSession(id: session.id) { $0.externalSessionID = "ext-flow" }
        sessionID = session.id
        coordinator = AgentSessionStatusCoordinator(
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

        // Echter Controller mit Claude-Profil; der Prozess ist nur ein Platzhalter.
        controller = AgentTerminalController(
            sessionID: session.id,
            command: AgentLaunchCommand(executablePath: "/bin/sh", arguments: ["-c", "sleep 30"],
                                        workingDirectory: NSTemporaryDirectory(), keyboardProfile: .claudeCodeChat),
            onLaunched: {}, onTerminated: { _ in })
        controller.start()
        // Ohne Fenster hat die Ansicht keine Größe; Claude zeichnet in eine echte.
        controller.terminal.getTerminal().resize(cols: 100, rows: 30)

        coordinator.deliverQueued = { [weak self] in self?.deliveries.append($0) }
        coordinator.noteTurnStartedInTerminal = { [weak controller] id in
            if id == controller?.sessionID { controller?.noteTurnStarted() }
        }
        coordinator.sessionLaunched(sessionID: session.id)
        coordinator.handleRegistryRecord(record("idle"))
    }

    func tearDown() {
        controller.terminate()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func record(_ status: String) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            profileName: "RankM8", pid: 4711, sessionID: "ext-flow", cwd: nil, kind: "interactive",
            name: "repo", rawStatus: status, status: ClaudeRegistryStatus(rawValue: status),
            waitingFor: nil, statusUpdatedAt: Date(timeIntervalSince1970: 1_794_000_000),
            messagingSocketPath: "/tmp/cc-socks/4711.sock", procStart: nil, version: "2.1.325")
    }

    /// Ein Turn, den der Chat von selbst beginnt (Hintergrund-Befehl fertig).
    func ownTurn() {
        coordinator.handleRegistryRecord(record("busy"))
        coordinator.handleRegistryRecord(record("idle"))
    }

    var status: AgentSessionRuntimeStatus? { coordinator.statusStore.status(for: sessionID) }

    /// Wie `deliverNow` entscheidet, mit dem Feld so gelesen wie dort.
    func queueDecision() -> PromptDeliveryGate.Decision {
        AgentPromptQueueDelivery.gateDecision(
            draft: controller.composerDraft,
            reading: controller.composerFieldForSendCheck(),
            profile: controller.command.keyboardProfile,
            runtime: status,
            lifecycle: coordinator.lifecycleState(for: sessionID),
            inputPending: coordinator.startupInputPending(sessionID))
    }

    /// Verlauf, dann `bottom` (Claudes unterer Rand); danach ganz unten. Zwei
    /// Leerzeilen Platz und zurück: Das Feld darf beim Zeichnen nicht scrollen,
    /// sonst landet der gespeicherte Cursor auf der Linie darunter.
    func draw(bottom: String, spare: Int = 2) {
        let history = (1...200).map { "Verlauf \($0)" }.joined(separator: "\r\n")
            + String(repeating: "\r\n", count: spare + 1) + "\u{1b}[\(spare)A"
        controller.terminal.feed(text: history + bottom)
        controller.scrollHistoryToBottom()
    }

    func drawClaude(fieldText text: String) {
        draw(bottom: InsertedTextScreen.bottom(text: text))
    }

    func scrollUp() {
        controller.terminal.scrollUp(lines: 40)
    }

    func scrollToBottom() {
        controller.scrollHistoryToBottom()
    }
}
