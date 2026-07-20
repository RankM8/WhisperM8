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
            initialPrompt: nil,
            claudeBackendModel: "gpt-5.5-historical-fast"
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
        coordinator.gptModelsFragmentResolver = { _ in nil }
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

    /// 4-Fälle-Matrix der Settings-Vorbereitung (Hooks-Preference ×
    /// Context-Profil): welche Datei entsteht, welche Keys sie enthält und
    /// ob die Hook-Bridge tracken darf.
    func testPrepareLaunchSettingsMatrix() throws {
        let (coordinator, sessionID, _, _, preferences) = try makeCoordinator()
        let profile = ClaudeContextProfile(
            name: "Coding",
            deniedMcpServers: ["claude.ai Gmail"],
            environment: ["ENABLE_CLAUDEAI_MCP_SERVERS": "false"]
        )

        func settingsKeys(_ path: String?) throws -> Set<String> {
            let path = try XCTUnwrap(path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return Set(dict.keys)
        }

        // Hooks an + Profil → hooks UND Profil-Keys in EINER Datei, Tracking an.
        let both = coordinator.prepareLaunchSettings(localSessionID: sessionID, contextProfile: profile)
        XCTAssertEqual(both.settingsArguments.first, "--settings")
        XCTAssertTrue(both.hooksActive)
        XCTAssertEqual(try settingsKeys(both.settingsFilePath), ["hooks", "deniedMcpServers", "env"])

        // Hooks an + kein Profil → nur hooks (heutiges Verhalten).
        let hooksOnly = coordinator.prepareLaunchSettings(localSessionID: sessionID, contextProfile: nil)
        XCTAssertTrue(hooksOnly.hooksActive)
        XCTAssertEqual(try settingsKeys(hooksOnly.settingsFilePath), ["hooks"])

        // Hooks aus + Profil → NUR Profil-Keys, kein Tracking.
        preferences.value.hooksEnabled = false
        let profileOnly = coordinator.prepareLaunchSettings(localSessionID: sessionID, contextProfile: profile)
        XCTAssertFalse(profileOnly.hooksActive)
        XCTAssertEqual(try settingsKeys(profileOnly.settingsFilePath), ["deniedMcpServers", "env"])

        // Hooks aus + kein Profil → keine Datei, keine Args.
        let nothing = coordinator.prepareLaunchSettings(localSessionID: sessionID, contextProfile: nil)
        XCTAssertNil(nothing.settingsFilePath)
        XCTAssertTrue(nothing.settingsArguments.isEmpty)
        XCTAssertFalse(nothing.hooksActive)

        // Leeres Profil zählt wie kein Profil.
        let empty = coordinator.prepareLaunchSettings(
            localSessionID: sessionID,
            contextProfile: ClaudeContextProfile(name: "Leer")
        )
        XCTAssertNil(empty.settingsFilePath)
    }

    func testPrepareLaunchSettingsMergesInjectedGPTCatalogIndependently() throws {
        let (coordinator, sessionID, _, _, preferences) = try makeCoordinator()
        let profile = ClaudeContextProfile(
            name: "Coding",
            deniedMcpServers: ["claude.ai Gmail"]
        )
        let expectedModels = ["default", "gpt-test", "gpt-test-fast"]
        var resolvedSessionModel: String?
        coordinator.gptModelsFragmentResolver = { sessionModel in
            resolvedSessionModel = sessionModel
            return ["availableModels": expectedModels]
        }

        func settings(_ path: String?) throws -> [String: Any] {
            let path = try XCTUnwrap(path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        // Hooks + Profil + Backend-Fragment landen gemeinsam in einer Datei.
        let allFragments = coordinator.prepareLaunchSettings(
            localSessionID: sessionID,
            contextProfile: profile
        )
        XCTAssertTrue(allFragments.hooksActive)
        XCTAssertEqual(resolvedSessionModel, "gpt-5.5-historical-fast")
        let allSettings = try settings(allFragments.settingsFilePath)
        XCTAssertEqual(Set(allSettings.keys), ["hooks", "deniedMcpServers", "availableModels"])
        XCTAssertEqual(allSettings["availableModels"] as? [String], expectedModels)

        // Ohne Hooks und Profil reicht das Backend-Fragment allein für die Datei.
        preferences.value.hooksEnabled = false
        let modelsOnly = coordinator.prepareLaunchSettings(
            localSessionID: sessionID,
            contextProfile: nil
        )
        XCTAssertFalse(modelsOnly.hooksActive)
        let modelSettings = try settings(modelsOnly.settingsFilePath)
        XCTAssertEqual(Set(modelSettings.keys), ["availableModels"])
        XCTAssertEqual(modelSettings["availableModels"] as? [String], expectedModels)

        let fallback = coordinator.prepareLaunchSettings(
            localSessionID: sessionID,
            contextProfile: nil,
            includeGPTModelCatalog: false
        )
        XCTAssertNil(fallback.settingsFilePath)

        // Backend aus, Hooks aus, kein Profil: unverändert keine Settings-Datei.
        coordinator.gptModelsFragmentResolver = { _ in nil }
        let nothing = coordinator.prepareLaunchSettings(
            localSessionID: sessionID,
            contextProfile: nil
        )
        XCTAssertEqual(nothing.settingsArguments, [])
        XCTAssertFalse(nothing.hooksActive)
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

    // MARK: Hook-Primat (Hooks als alleinige Statusquelle)

    func testTranscriptCannotOverrideHookLiveWorking() throws {
        // Kern der Neuordnung: Sobald die Hook-Bridge Events liefert, sind
        // Transcript-Heuristiken für diese Session stumm. Vorher stufte der
        // 1,5-s-Poll (Meta-Zeilen + 30-s-mtime-Heuristik) arbeitende Chats
        // laufend fälschlich auf idle herab.
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)

        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .idle, turnFinished: false)
        )
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working, "Decider-idle darf Hook-working nicht überschreiben")

        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .idle, turnFinished: true)
        )
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working, "Auch turnFinished-idle bleibt nur Bookkeeping, kein Status-Write")
    }

    func testTranscriptStillDrivesStatusWithoutHooks() throws {
        // Sessions ohne lebendige Hook-Bridge (Codex, extern, Hooks aus)
        // behalten den Transcript-Pfad als Statusquelle.
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)

        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .working, turnFinished: false)
        )
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)

        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .idle, turnFinished: true)
        )
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle)
    }

    func testRelaunchResetsHookPrimacyUntilFirstEvent() throws {
        // Neue Prozessinstanz muss erst wieder beweisen, dass ihre Hooks
        // feuern — bis dahin gilt der Transcript-Fallback.
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        coordinator.sessionTerminated(sessionID: sessionID, exitCode: 0)

        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .working, turnFinished: false)
        )
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working, "Ohne Hook-Event der neuen Instanz zählt das Transkript wieder")
    }

    func testInterruptAbortsTurnEvenWhenHookLive() throws {
        // ESC-Interrupt: Der Stop-Hook feuert nicht — der Transcript-Fakt
        // `turnAborted` muss auch bei hook-live Sessions durchgreifen,
        // sonst pulsiert der abgebrochene Chat für immer als „arbeitet".
        let (coordinator, sessionID, poster, sounds, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)

        coordinator.handleTranscriptDecision(
            sessionID: sessionID,
            decision: .init(status: .idle, turnFinished: false, turnAborted: true)
        )
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle)
        XCTAssertEqual(coordinator.lifecycleState(for: sessionID), .ready)
        XCTAssertTrue(poster.posted.isEmpty, "Abbruch ist keine Fertig-Notification")
        XCTAssertTrue(sounds.played.isEmpty, "Abbruch spielt keinen Fertig-Ton")
    }

    // MARK: SessionEnd & Background-Agents

    func testSessionEndWithTerminalReasonStopsSession() throws {
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.sessionStart))

        var end = hookEvent(.sessionEnd)
        end.reason = "prompt_input_exit"
        coordinator.handleHookEvent(localID: sessionID, event: end)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .stopped)

        // Starkes Lebenszeichen belebt wieder (falsch eingeschätzter Reason).
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.userPromptSubmit))
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)
    }

    func testSessionEndWithClearReasonKeepsSessionAlive() throws {
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()
        coordinator.sessionLaunched(sessionID: sessionID)
        coordinator.handleHookEvent(localID: sessionID, event: hookEvent(.sessionStart))

        var end = hookEvent(.sessionEnd)
        end.reason = "clear"
        coordinator.handleHookEvent(localID: sessionID, event: end)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle, "/clear beendet die Session nicht")
    }

    func testBackgroundAttachExitDoesNotStopBackgroundSession() throws {
        // Der PTY einer BG-Session ist nur ein `claude attach`-Fenster — sein
        // Exit darf den weiterlaufenden Supervisor-Job nicht als beendet
        // markieren. Das echte Ende kommt vom SessionEnd-Hook.
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("bg-workspace.json"))
        let session = try store.createSession(
            provider: .claude,
            projectPath: tempDir.path,
            title: "BG-Agent",
            initialPrompt: nil,
            kind: .backgroundChat
        )
        let coordinator = AgentSessionStatusCoordinator(
            store: store,
            hookBridge: ClaudeHookBridge(paths: ClaudeHookPaths(rootDirectory: tempDir)),
            notificationPoster: NotificationPosterSpy(),
            playSound: { _ in },
            loadPreferences: { PreferencesBox().value },
            launchGraceSeconds: 999
        )
        coordinator.terminalExternalIDUpdater = { _, _ in }

        coordinator.sessionLaunched(sessionID: session.id)
        coordinator.handleHookEvent(
            localID: session.id,
            event: ClaudeHookEvent(hookEventName: .userPromptSubmit, sessionID: "ext-bg", transcriptPath: nil, cwd: nil, reason: nil, toolName: nil, rawJSON: "{}")
        )
        XCTAssertEqual(coordinator.statusStore.status(for: session.id), .working)

        // Attach-PTY geht zu — Agent arbeitet weiter.
        coordinator.sessionTerminated(sessionID: session.id, exitCode: 0)
        XCTAssertEqual(coordinator.statusStore.status(for: session.id), .working, "Attach-Exit ist kein Prozessende des BG-Agenten")

        // Das echte Ende meldet der SessionEnd-Hook.
        var end = ClaudeHookEvent(hookEventName: .sessionEnd, sessionID: "ext-bg", transcriptPath: nil, cwd: nil, reason: nil, toolName: nil, rawJSON: "{}")
        end.reason = "other"
        coordinator.handleHookEvent(localID: session.id, event: end)
        XCTAssertEqual(coordinator.statusStore.status(for: session.id), .stopped)
    }

    // MARK: Subagent-Jobs (state.json → statusStore)

    func testSubagentJobStatusMapsAllPhases() throws {
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()

        coordinator.updateSubagentJobStatus(sessionID: sessionID, state: .spawning)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)

        coordinator.updateSubagentJobStatus(sessionID: sessionID, state: .running)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)

        coordinator.updateSubagentJobStatus(sessionID: sessionID, state: .done)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .idle)

        coordinator.updateSubagentJobStatus(sessionID: sessionID, state: .failed)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .errored)

        coordinator.updateSubagentJobStatus(sessionID: sessionID, state: .stopped)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .stopped)
    }

    func testSubagentJobTakenOverClearsStatus() throws {
        let (coordinator, sessionID, _, _, _) = try makeCoordinator()

        coordinator.updateSubagentJobStatus(sessionID: sessionID, state: .running)
        XCTAssertEqual(coordinator.statusStore.status(for: sessionID), .working)

        // Übernahme: der Job-Status verschwindet — ab jetzt schreibt nur
        // noch der normale PTY-Pfad in den Store.
        coordinator.updateSubagentJobStatus(sessionID: sessionID, state: .takenOver)
        XCTAssertNil(coordinator.statusStore.status(for: sessionID))
    }
}
