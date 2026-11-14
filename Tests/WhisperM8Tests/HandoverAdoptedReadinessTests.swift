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

    /// Wartet bis zu 5 s darauf, dass `condition` wahr wird (statt fester
    /// Schlafzeit: die volle Suite läuft auf Akku deutlich langsamer).
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func testRestedAtHandoverFallsBackAfterTheUsualGrace() async throws {
        let f = try makeFixture(launchGrace: 0.05)
        f.coordinator.adoptedUnconfirmedGraceSeconds = 999
        f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: .idle)
        let released = try await eventually { f.coordinator.lifecycleState(for: f.sessionID) == .ready }
        XCTAssertTrue(released, "ohne Signal nach der Startfrist bereit")
        XCTAssertEqual(f.deliveries.ids, [f.sessionID])
    }

    func testWorkingOrUnknownAtHandoverUsesTheLongGrace() async throws {
        for status in [AgentSessionRuntimeStatus.working, .awaitingInput, nil] {
            // Kurze Startfrist, lange Notfrist: die kurze gibt nicht frei …
            let f = try makeFixture(launchGrace: 0.05)
            f.coordinator.adoptedUnconfirmedGraceSeconds = 999
            f.coordinator.sessionAdopted(sessionID: f.sessionID, handedOverStatus: status)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .launching,
                           "\(status?.rawValue ?? "unbekannt"): die kurze Startfrist gibt nicht frei")
            XCTAssertTrue(f.deliveries.ids.isEmpty)

            // … umgekehrt gibt die lange Notfrist frei, auch ganz ohne Signal.
            let g = try makeFixture(launchGrace: 999)
            g.coordinator.adoptedUnconfirmedGraceSeconds = 0.05
            g.coordinator.sessionAdopted(sessionID: g.sessionID, handedOverStatus: status)
            let released = try await eventually { g.coordinator.lifecycleState(for: g.sessionID) == .ready }
            XCTAssertTrue(released, "\(status?.rawValue ?? "unbekannt"): die Notfrist gibt am Ende frei")
        }
    }

    // MARK: Verlauf als Beleg (Review)

    private func transcript(_ status: AgentSessionRuntimeStatus) -> AgentTranscriptStatusDecider.Decision {
        AgentTranscriptStatusDecider.Decision(status: status, turnFinished: false)
    }

    /// Der Verlauf hält eine offene Frage oder ein langes stilles Tool für
    /// „ruht“: Das gibt einen übernommenen Claude-Chat nicht frei, solange die
    /// Registry ihn noch nicht kennt.
    func testTranscriptIdleDoesNotReleaseAnAdoptedClaudeChat() throws {
        let f = try makeFixture()
        f.coordinator.sessionAdopted(sessionID: f.sessionID)
        f.coordinator.handleTranscriptDecision(sessionID: f.sessionID, decision: transcript(.idle))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .launching)
        XCTAssertEqual(queueDecision(f), .notReady)
        XCTAssertTrue(f.deliveries.ids.isEmpty)

        // Aktivität aus dem Verlauf zählt: der Chat arbeitet.
        f.coordinator.handleTranscriptDecision(sessionID: f.sessionID, decision: transcript(.working))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .working)
        XCTAssertTrue(f.deliveries.ids.isEmpty)
    }

    /// Ohne Registry-Status (Schalter aus) bleibt der Verlauf der Beleg.
    func testTranscriptIdleReleasesWhenRegistryStatusIsOff() throws {
        let f = try makeFixture()
        f.coordinator.isRegistryStatusEnabled = { false }
        f.coordinator.sessionAdopted(sessionID: f.sessionID)
        f.coordinator.handleTranscriptDecision(sessionID: f.sessionID, decision: transcript(.idle))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .ready)
        XCTAssertEqual(f.deliveries.ids, [f.sessionID])
    }

    func testManifestWritesUnknownForAChatStillWithoutEvidence() {
        XCTAssertNil(HandoverManifestFactory.handedOverRuntimeStatus(lifecycle: .launching, runtime: .idle))
        XCTAssertEqual(HandoverManifestFactory.handedOverRuntimeStatus(lifecycle: .ready, runtime: .idle), "idle")
        XCTAssertEqual(HandoverManifestFactory.handedOverRuntimeStatus(lifecycle: .working, runtime: .working), "working")
        XCTAssertNil(HandoverManifestFactory.handedOverRuntimeStatus(lifecycle: nil, runtime: nil))
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

    // MARK: Wortlaut (Vic, WM8-97)

    func testSendMessageNamesTheRestartForAnAdoptedChat() {
        let decision = ChatsSendReadinessGuard.Decision.notReady(sinceSec: nil)
        let adopted = ChatsSendReadinessGuard.message(for: decision, adopted: true) ?? ""
        XCTAssertTrue(adopted.contains("übernommen"))
        XCTAssertTrue(adopted.contains("enqueue"))
        XCTAssertFalse(adopted.contains("startet noch"))
        XCTAssertTrue(ChatsSendReadinessGuard.message(for: decision)?.contains("startet noch") ?? false)
    }
}

