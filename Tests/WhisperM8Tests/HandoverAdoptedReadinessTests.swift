import XCTest
@testable import WhisperM8

/// WM8-97 (Befund aus Vics zweitem Gesamt-Review): Ein übernommener Chat galt
/// sofort als „bereit“, ohne Beleg. Die Warteschlange stellte 3 s nach der
/// Übernahme zu und `chats send` war sofort erlaubt; arbeitete der Chat oder
/// stand eine Frage offen, ging der Text in laufende Arbeit oder den Dialog.
/// Alle Tests schreiben in ein Temp-Verzeichnis.
@MainActor
final class HandoverAdoptedReadinessTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adopted-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private final class PosterSpy: AgentUserNotificationPosting {
        var posted: [AgentSessionUserNotification] = []
        func post(_ notification: AgentSessionUserNotification) { posted.append(notification) }
    }

    private final class Deliveries { var ids: [UUID] = [] }

    private struct Fixture {
        var coordinator: AgentSessionStatusCoordinator
        var sessionID: UUID
        var deliveries: Deliveries
        var poster: PosterSpy
    }

    private func makeFixture(launchGrace: TimeInterval = 999) throws -> Fixture {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let session = try store.createSession(
            provider: .claude, projectPath: tempDir.path, title: "Übernommener Chat", initialPrompt: nil)
        try store.updateSession(id: session.id) { $0.externalSessionID = "ext-1" }
        let poster = PosterSpy()
        let coordinator = AgentSessionStatusCoordinator(
            store: store,
            hookBridge: ClaudeHookBridge(paths: ClaudeHookPaths(rootDirectory: tempDir)),
            notificationPoster: poster,
            playSound: { _ in },
            loadPreferences: {
                AgentStatusPreferences(hooksEnabled: true, stopNotificationEnabled: true,
                                       awaitingNotificationEnabled: true, stopSoundEnabled: false,
                                       stopSoundName: "Glass")
            },
            launchGraceSeconds: launchGrace)
        coordinator.terminalExternalIDUpdater = { _, _ in }
        coordinator.gptModelsFragmentResolver = { _ in nil }
        coordinator.sharedMemoryFragmentResolver = { _, _ in nil }
        coordinator.isRegistryStatusEnabled = { true }
        coordinator.registryRecordLookup = { _ in nil }
        coordinator.registryAwaitingNotificationDelay = 0
        coordinator.hasRunningTerminal = { _ in true }
        coordinator.freshTranscriptBeforeTurnEnd = { _, action in action() }
        let deliveries = Deliveries()
        coordinator.deliverQueued = { deliveries.ids.append($0) }
        return Fixture(coordinator: coordinator, sessionID: session.id, deliveries: deliveries, poster: poster)
    }

    private func record(_ status: String, waitingFor: String? = nil) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            profileName: "ai2", pid: 4711, sessionID: "ext-1", cwd: nil, kind: "interactive",
            name: "repo", rawStatus: status, status: ClaudeRegistryStatus(rawValue: status),
            waitingFor: waitingFor, statusUpdatedAt: Date(timeIntervalSince1970: 1_792_000_000),
            messagingSocketPath: "/tmp/cc-socks/4711.sock", procStart: nil, version: "2.1.302")
    }

    private func queueDecision(_ f: Fixture) -> PromptDeliveryGate.Decision {
        PromptDeliveryGate.forQueue(
            runtime: f.coordinator.statusStore.status(for: f.sessionID),
            lifecycle: f.coordinator.lifecycleState(for: f.sessionID),
            mayHaveUnsentInput: false)
    }

    private func sendDecision(_ f: Fixture) -> ChatsSendReadinessGuard.Decision {
        ChatsSendReadinessGuard.decide(lifecycle: f.coordinator.lifecycleState(for: f.sessionID))
    }

    // MARK: Das Fenster (vorher offen)

    func testAdoptedChatIsNotReadyBeforeTheFirstRealSignal() throws {
        let f = try makeFixture()
        f.coordinator.sessionAdopted(sessionID: f.sessionID)
        XCTAssertEqual(queueDecision(f), .notReady, "Warteschlange darf vor dem ersten Beleg nicht zustellen")
        XCTAssertEqual(sendDecision(f), .notReady(sinceSec: nil), "chats send lehnt im Fenster ab")
        XCTAssertTrue(f.deliveries.ids.isEmpty)

        // Erster echter Abgleich: Claude meldet „ruht“ → bereit, Zustellung angestoßen.
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready)
        XCTAssertEqual(queueDecision(f), .deliver)
        XCTAssertEqual(sendDecision(f), .allowed)
        XCTAssertEqual(f.deliveries.ids, [f.sessionID], "mit dem Beleg genau einmal anstoßen")
    }

    // MARK: Fälle aus dem Ticket

    /// Chat arbeitet bei der Übergabe und hat einen vorgemerkten Auftrag: Der
    /// Auftrag wartet, bis der Turn wirklich endet.
    func testWorkingAtHandoverKeepsTheQueuedPromptUntilTheTurnEnds() throws {
        let f = try makeFixture()
        f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: .working)
        XCTAssertEqual(queueDecision(f), .notReady)
        XCTAssertEqual(sendDecision(f), .notReady(sinceSec: nil))

        f.coordinator.handleRegistryRecord(record("busy"))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .working)
        XCTAssertEqual(queueDecision(f), .busy("working"))
        XCTAssertTrue(f.deliveries.ids.isEmpty, "mitten im Turn nie zustellen")
        XCTAssertTrue(f.poster.posted.isEmpty, "mitten im Turn übernommen: keine Meldung")

        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .turnDone)
        XCTAssertEqual(f.deliveries.ids, [f.sessionID], "erst das echte Turn-Ende stellt zu")
    }

    /// Turn endete in der Lücke: Der erste Abgleich zeigt „ruht“; Zustellung
    /// genau einmal, ohne festes Nachfassen nach 3 s.
    func testTurnThatEndedInTheGapDeliversOnceOnFirstSight() throws {
        let f = try makeFixture()
        f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: .working)
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready)
        XCTAssertEqual(f.deliveries.ids, [f.sessionID])
    }

    /// Chat hat bei der Übergabe eine offene Frage: Kein Auftrag und kein
    /// `chats send` landet im Dialog, weder vor noch nach dem ersten Abgleich.
    func testOpenQuestionAtHandoverNeverReceivesTheQueuedPrompt() throws {
        let f = try makeFixture()
        f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: .awaitingInput)
        XCTAssertEqual(queueDecision(f), .notReady)
        XCTAssertEqual(sendDecision(f), .notReady(sinceSec: nil))

        f.coordinator.handleRegistryRecord(record("waiting", waitingFor: "input needed"))
        guard case .awaitingInput = f.coordinator.lifecycleState(for: f.sessionID) else {
            return XCTFail("offene Frage erwartet, ist \(String(describing: f.coordinator.lifecycleState(for: f.sessionID)))")
        }
        XCTAssertEqual(queueDecision(f), .busy("awaitingInput"))
        XCTAssertTrue(f.deliveries.ids.isEmpty, "eine offene Frage bekommt nie den Folgeauftrag")
    }

    // MARK: Notfrist ohne Signal

    func testRestedAtHandoverFallsBackAfterTheUsualGrace() async throws {
        let f = try makeFixture(launchGrace: 0.05)
        f.coordinator.adoptedUnconfirmedGraceSeconds = 999
        f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: .idle)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready, "ohne Signal nach der Startfrist bereit")
        XCTAssertEqual(f.deliveries.ids, [f.sessionID])
    }

    func testWorkingOrUnknownAtHandoverWaitsForTheLongGrace() async throws {
        for status in [AgentSessionRuntimeStatus.working, .awaitingInput, nil] {
            let f = try makeFixture(launchGrace: 0.05)
            f.coordinator.adoptedUnconfirmedGraceSeconds = 999
            f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: status)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .launching,
                           "\(status?.rawValue ?? "unbekannt"): die kurze Startfrist gibt nicht frei")
            XCTAssertTrue(f.deliveries.ids.isEmpty)
        }
    }

    // MARK: Manifest

    func testHandedOverStatusComesFromTheManifestOrFromWorkingSince() {
        var manifest = HandoverManifest(chatID: "c", kind: "claude", pid: 7, cols: 100, rows: 30, sendsInterruptOnStop: true)
        XCTAssertNil(HandoverTakeService.handedOverStatus(manifest))
        manifest.workingSince = 1_792_000_000
        XCTAssertEqual(HandoverTakeService.handedOverStatus(manifest), .working, "ältere Manifeste")
        manifest.runtimeStatus = "awaitingInput"
        XCTAssertEqual(HandoverTakeService.handedOverStatus(manifest), .awaitingInput)
        manifest.runtimeStatus = "idle"
        manifest.workingSince = nil
        XCTAssertEqual(HandoverTakeService.handedOverStatus(manifest), .idle)
    }
}
