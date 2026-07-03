import XCTest
@testable import WhisperM8

/// Integrationstests des Status-Koordinators: Signale rein → Status im
/// Store + Effekte (Notification/Sound) raus. Notification-Poster und
/// Sound-Player sind Spies, Preferences eine mutierbare Box.
@MainActor
final class AgentSessionStatusCoordinatorTests: XCTestCase {
    private final class NotificationPosterSpy: AgentUserNotificationPosting {
        var posted: [AgentSessionUserNotification] = []
        func post(_ notification: AgentSessionUserNotification) {
            posted.append(notification)
        }
    }

    private final class SoundSpy {
        var played: [String] = []
    }

    private final class PreferencesBox {
        var value = AgentStatusPreferences(
            hooksEnabled: true,
            stopNotificationEnabled: true,
            awaitingNotificationEnabled: true,
            stopSoundEnabled: true,
            stopSoundName: "Glass"
        )
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator() throws -> (
        coordinator: AgentSessionStatusCoordinator,
        sessionID: UUID,
        poster: NotificationPosterSpy,
        sounds: SoundSpy,
        preferences: PreferencesBox
    ) {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let session = try store.createSession(
            provider: .claude,
            projectPath: tempDir.path,
            title: "Statusmaschine-Chat",
            initialPrompt: nil
        )
        let poster = NotificationPosterSpy()
        let sounds = SoundSpy()
        let preferences = PreferencesBox()
        let coordinator = AgentSessionStatusCoordinator(
            store: store,
            hookBridge: ClaudeHookBridge(paths: ClaudeHookPaths(rootDirectory: tempDir)),
            notificationPoster: poster,
            playSound: { sounds.played.append($0) },
            loadPreferences: { preferences.value },
            launchGraceSeconds: 999 // Grace-Timer soll in Tests nie feuern
        )
        coordinator.terminalExternalIDUpdater = { _, _ in }
        return (coordinator, session.id, poster, sounds, preferences)
    }

    private func hookEvent(
        _ name: ClaudeHookEvent.EventName,
        tool: String? = nil,
        sessionID: String? = "ext-1"
    ) -> ClaudeHookEvent {
        ClaudeHookEvent(
            hookEventName: name,
            sessionID: sessionID,
            transcriptPath: nil,
            cwd: nil,
            reason: nil,
            toolName: tool,
            rawJSON: "{}"
        )
    }

    // MARK: Kern-Bugfix

    func testFreshChatWithoutPromptNeverShowsWorking() throws {
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()

        coordinator.sessionLaunched(sessionID: sessionID)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle, "Launch = ruhiger Punkt, kein Puls")

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.sessionStart))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle, "Bereit ohne Prompt bleibt ruhig")
        XCTAssertEqual(coordinator.lifecycleState(for: sessionID), .ready)

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working, "Erst der Prompt startet die Arbeit")
    }

    func testSessionStartBindsExternalSessionID() throws {
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()
        var boundIDs: [(UUID, String)] = []
        coordinator.terminalExternalIDUpdater = { boundIDs.append(($0, $1)) }

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.sessionStart, sessionID: "ext-neu"))

        XCTAssertEqual(boundIDs.count, 1)
        XCTAssertEqual(boundIDs.first?.1, "ext-neu")
    }

    // MARK: Rückfragen + Notifications

    func testPermissionRequestNotifiesOnceAndClearsOnPostToolUse() throws {
        let (coordinator, sessionID, poster, _, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.permissionRequest))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .awaitingInput)
        XCTAssertEqual(poster.posted.count, 1)
        XCTAssertEqual(poster.posted.first?.kind, .inputRequested(.permission))
        XCTAssertEqual(poster.posted.first?.title, "Statusmaschine-Chat")

        // Wiederholtes PermissionRequest: kein Doppel-Post (Zustands-Dedup).
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.permissionRequest))
        XCTAssertEqual(poster.posted.count, 1)

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.postToolUse, tool: "Bash"))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)
    }

    func testAskUserQuestionToolNotifiesAsQuestion() throws {
        let (coordinator, sessionID, poster, _, _) = try makeCoordinator()
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.preToolUse, tool: "AskUserQuestion"))

        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .awaitingInput)
        XCTAssertEqual(poster.posted.last?.kind, .inputRequested(.question))
    }

    // MARK: Turn-Ende: Sound + Notification, dedupliziert

    func testStopPlaysSoundAndNotifiesExactlyOnce() throws {
        let (coordinator, sessionID, poster, sounds, _) = try makeCoordinator()
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.stop))

        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle)
        XCTAssertEqual(sounds.played, ["Glass"])
        XCTAssertEqual(poster.posted.map(\.kind), [.turnCompleted])

        // Decider erkennt dasselbe Turn-Ende später (ohne frisches
        // turnFinished) → kein zweiter Effekt.
        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .idle, turnFinished: false)
        )
        XCTAssertEqual(sounds.played.count, 1)
        XCTAssertEqual(poster.posted.count, 1)
    }

    func testTranscriptActivityCannotOverrideAwaiting() throws {
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.permissionRequest))

        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .working, turnFinished: false)
        )

        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .awaitingInput)
    }

    // MARK: Preferences-Gates

    func testDisabledNotificationsAndSoundAreRespected() throws {
        let (coordinator, sessionID, poster, sounds, preferences) = try makeCoordinator()
        preferences.value.stopNotificationEnabled = false
        preferences.value.awaitingNotificationEnabled = false
        preferences.value.stopSoundEnabled = false

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.permissionRequest))
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.stop))

        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertTrue(sounds.played.isEmpty)
        // Status läuft trotzdem korrekt weiter.
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle)
    }

    func testCustomStopSoundNameIsUsed() throws {
        let (coordinator, sessionID, _, sounds, preferences) = try makeCoordinator()
        preferences.value.stopSoundName = "Submarine"

        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.stop))

        XCTAssertEqual(sounds.played, ["Submarine"])
    }

    func testDisabledHooksYieldNoLaunchArguments() throws {
        let (coordinator, sessionID, _, _, preferences) = try makeCoordinator()

        let enabledArgs = coordinator.prepareLaunchArguments(localSessionID: sessionID)
        XCTAssertEqual(enabledArgs.first, "--settings")

        preferences.value.hooksEnabled = false
        XCTAssertTrue(coordinator.prepareLaunchArguments(localSessionID: sessionID).isEmpty)
        XCTAssertNil(coordinator.prepareBackgroundSettingsFile(localSessionID: sessionID))
    }

    // MARK: Prozessende

    func testTerminationSetsFinalStatusAndIgnoresLateEvents() throws {
        let (coordinator, sessionID, poster, sounds, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))

        coordinator.sessionTerminated(sessionID: sessionID, exitCode: 1)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .errored)

        // Verspätete Events aus dem Event-File-Drain ändern nichts mehr.
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.stop))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .errored)
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertTrue(sounds.played.isEmpty)

        // Relaunch belebt die Session.
        coordinator.sessionLaunched(sessionID: sessionID)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle)
    }
}
