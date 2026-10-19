import XCTest
@testable import WhisperM8

/// Claudes Registry als Statusquelle (Plan claude-status-aus-registry.md,
/// S2–S4): Reducer, Coordinator-Gating, Quelle, CLI-Vorrang, Hook-Satz.
@MainActor
final class ClaudeRegistryStatusTests: XCTestCase {
    // MARK: Reducer

    private func reduce(_ state: AgentSessionLifecycleState, _ observation: ClaudeRegistryObservation)
        -> AgentSessionStateMachine.Transition {
        AgentSessionStateMachine.reduce(state: state, signal: .registryStatus(observation))
    }

    func testReducerTransitions() {
        XCTAssertEqual(reduce(.ready, .busy), .init(state: .working))
        XCTAssertEqual(reduce(.working, .idle(interrupted: false)),
                       .init(state: .turnDone, effects: [.turnCompleted]))
        // Abbruch: kein „fertig“, keine Queue-Zustellung.
        XCTAssertEqual(reduce(.working, .idle(interrupted: true)), .init(state: .ready))
        // Erste Sicht nach App-Start erzeugt kein Turn-Ende.
        XCTAssertEqual(reduce(.created, .idle(interrupted: false)), .init(state: .ready))
        XCTAssertEqual(reduce(.launching, .idle(interrupted: false)), .init(state: .ready))
        XCTAssertEqual(reduce(.turnDone, .idle(interrupted: false)), .init(state: .turnDone))
        // Dialog weggeklickt → bereit, kein Turn-Ende.
        XCTAssertEqual(reduce(.awaitingInput(.question), .idle(interrupted: false)), .init(state: .ready))
    }

    func testReducerWaitingFiresOnceAndRefinesSilently() {
        XCTAssertEqual(reduce(.working, .waiting(.permission)),
                       .init(state: .awaitingInput(.permission), effects: [.inputRequested(.permission)]))
        XCTAssertEqual(reduce(.awaitingInput(.permission), .waiting(.permission)),
                       .init(state: .awaitingInput(.permission)))
        XCTAssertEqual(reduce(.awaitingInput(.permission), .waiting(.planApproval)),
                       .init(state: .awaitingInput(.planApproval)))
    }

    func testReducerRevivesStoppedSessionOnLiveRecord() {
        XCTAssertEqual(reduce(.stopped, .busy), .init(state: .working))
        XCTAssertEqual(reduce(.errored, .idle(interrupted: false)), .init(state: .ready))
    }

    func testAwaitingKindFromWaitingForAndDetail() {
        typealias C = AgentSessionStatusCoordinator
        XCTAssertEqual(C.registryAwaitingKind(waitingFor: "input needed", detail: .question("Rot?")), .question)
        XCTAssertEqual(C.registryAwaitingKind(waitingFor: "permission prompt",
                                              detail: .tool(name: "ExitPlanMode", argument: nil)), .planApproval)
        XCTAssertEqual(C.registryAwaitingKind(waitingFor: "input needed",
                                              detail: .tool(name: "Bash", argument: "ls")), .permission)
        XCTAssertEqual(C.registryAwaitingKind(waitingFor: "input needed", detail: nil), .question)
        XCTAssertEqual(C.registryAwaitingKind(waitingFor: "permission prompt", detail: .reply("ok")), .permission)
        XCTAssertEqual(C.registryAwaitingKind(waitingFor: nil, detail: nil), .permission)
    }

    // MARK: Coordinator

    private final class PosterSpy: AgentUserNotificationPosting {
        var posted: [AgentSessionUserNotification] = []
        func post(_ notification: AgentSessionUserNotification) { posted.append(notification) }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private struct Fixture {
        var coordinator: AgentSessionStatusCoordinator
        var store: AgentSessionStore
        var sessionID: UUID
        var poster: PosterSpy
        var sounds: [String] { soundBox.played }
        var soundBox: SoundBox
        var registryEnabled: FlagBox
    }

    final class SoundBox { var played: [String] = [] }
    final class FlagBox { var value = true }

    private func makeFixture(background: Bool = false) throws -> Fixture {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let session = try store.createSession(
            provider: .claude, projectPath: tempDir.path, title: "Registry-Chat", initialPrompt: nil)
        try store.updateSession(id: session.id) { session in
            session.externalSessionID = "ext-1"
            if background { session.kind = .backgroundChat }
        }
        let poster = PosterSpy()
        let sounds = SoundBox()
        let flag = FlagBox()
        let coordinator = AgentSessionStatusCoordinator(
            store: store,
            hookBridge: ClaudeHookBridge(paths: ClaudeHookPaths(rootDirectory: tempDir)),
            notificationPoster: poster,
            playSound: { sounds.played.append($0) },
            loadPreferences: {
                AgentStatusPreferences(hooksEnabled: true, stopNotificationEnabled: true,
                                       awaitingNotificationEnabled: true, stopSoundEnabled: true,
                                       stopSoundName: "Glass")
            },
            launchGraceSeconds: 999)
        coordinator.terminalExternalIDUpdater = { _, _ in }
        coordinator.gptModelsFragmentResolver = { _ in nil }
        coordinator.sharedMemoryFragmentResolver = { _, _ in nil }
        coordinator.isRegistryStatusEnabled = { flag.value }
        coordinator.registryRecordLookup = { _ in nil }
        coordinator.hasRunningTerminal = { _ in true }
        return Fixture(coordinator: coordinator, store: store, sessionID: session.id,
                       poster: poster, soundBox: sounds, registryEnabled: flag)
    }

    private func record(
        _ status: String, waitingFor: String? = nil, sessionID: String = "ext-1",
        pid: Int32 = 4711, kind: String = "interactive",
        updatedAt: Date = Date(timeIntervalSince1970: 1_792_000_000)
    ) -> ClaudeSessionRecord {
        ClaudeSessionRecord(
            profileName: "ai2", pid: pid, sessionID: sessionID, cwd: nil, kind: kind,
            name: "repo-ab", rawStatus: status, status: ClaudeRegistryStatus(rawValue: status),
            waitingFor: waitingFor, statusUpdatedAt: updatedAt,
            messagingSocketPath: "/tmp/cc-socks/4711.sock",
            procStart: nil, version: "2.1.302")
    }

    private func hook(_ name: ClaudeHookEvent.EventName, tool: String? = nil) -> ClaudeHookEvent {
        ClaudeHookEvent(hookEventName: name, sessionID: "ext-1", transcriptPath: nil, cwd: nil,
                        reason: nil, toolName: tool, rawJSON: "{}")
    }

    func testRegistryDrivesStatusAndTurnEndEffects() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertTrue(f.coordinator.registryLiveSessions.contains(f.sessionID))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .idle)
        XCTAssertTrue(f.poster.posted.isEmpty, "erste Sicht ist kein Turn-Ende")

        f.coordinator.handleRegistryRecord(record("busy"))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .working)
        f.coordinator.handleRegistryRecord(record("shell"))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .idle)
        XCTAssertEqual(f.sounds, ["Glass"])
        XCTAssertEqual(f.poster.posted.count, 1)
    }

    func testHooksAndTranscriptNoLongerDriveRegistryLiveSession() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy"))
        // Stop-Hook würde früher „fertig“ melden — jetzt zählt nur Claude.
        f.coordinator.handleHookEvent(localID: f.sessionID, event: hook(.stop))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .working)
        XCTAssertTrue(f.poster.posted.isEmpty)
        f.coordinator.handleTranscriptDecision(
            sessionID: f.sessionID,
            decision: .init(status: .idle, turnFinished: false, turnAborted: true))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .working)
    }

    func testInterruptMarkSuppressesTurnCompleted() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.suspectTurnAborted(f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .idle)
        XCTAssertTrue(f.poster.posted.isEmpty)
        XCTAssertTrue(f.sounds.isEmpty)
        // Der Merker ist verbraucht: der nächste Turn meldet wieder „fertig“.
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.poster.posted.count, 1)
    }

    /// LR-AK-034: ESC kurz vor dem echten Turn-Ende — ohne Abbruch-Marker im
    /// Transcript ist das „idle“ ein normales Fertig (Meldung, Queue).
    func testUnconfirmedInterruptMarkDoesNotSwallowTurnEnd() throws {
        let f = try makeFixture()
        f.coordinator.interruptConfirmationOverride = { _ in false }
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.suspectTurnAborted(f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.poster.posted.count, 1, "echtes Turn-Ende wird gemeldet")
    }

    func testTranscriptTailInterruptDetection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"type":"assistant","message":{}}"# .appending("\n")
            .appending(#"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#).appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSessionStatusCoordinator.transcriptTailShowsInterrupt(url: url), true)
        try #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"# .appending("\n")
            .appending(#"{"type":"assistant","message":{}}"#).appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSessionStatusCoordinator.transcriptTailShowsInterrupt(url: url), false)
    }

    func testNewTurnClearsStaleInterruptMark() throws {
        let f = try makeFixture()
        let clock = Date(timeIntervalSince1970: 1_792_000_000)
        f.coordinator.now = { clock }
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle"))
        f.coordinator.suspectTurnAborted(f.sessionID) // ESC im Leerlauf
        f.coordinator.handleRegistryRecord(record("busy", updatedAt: clock.addingTimeInterval(3)))
        f.coordinator.handleRegistryRecord(record("idle", updatedAt: clock.addingTimeInterval(9)))
        XCTAssertEqual(f.poster.posted.count, 1)
    }

    func testInterruptRightAfterSendSurvivesLateBusyEvent() throws {
        // Prompt geschickt, sofort ESC — Claudes busy-Eintrag (geschrieben vor
        // dem ESC) kommt erst danach an und darf den Merker nicht löschen.
        let f = try makeFixture()
        let clock = Date(timeIntervalSince1970: 1_792_000_000)
        f.coordinator.now = { clock }
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle", updatedAt: clock.addingTimeInterval(-10)))
        f.coordinator.suspectTurnAborted(f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy", updatedAt: clock.addingTimeInterval(-0.5)))
        f.coordinator.handleRegistryRecord(record("idle", updatedAt: clock.addingTimeInterval(0.5)))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .idle)
        XCTAssertTrue(f.poster.posted.isEmpty, "Abbruch ist kein „fertig“")
        XCTAssertTrue(f.sounds.isEmpty)
    }

    func testWaitingUsesTranscriptDetailForKind() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.handleRegistryRecord(record("waiting", waitingFor: "permission prompt"))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .awaitingInput(.permission))
        // Tail kommt nach der Registry → Art wird nachgezogen.
        f.coordinator.handleTranscriptActivity(
            sessionID: f.sessionID, activity: AgentSessionActivity(detail: .tool(name: "ExitPlanMode", argument: nil)))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .awaitingInput(.planApproval))
        XCTAssertEqual(f.poster.posted.count, 1, "Rückfrage-Meldung nur einmal")
    }

    func testPermissionToolNameComesFromTail() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleTranscriptActivity(
            sessionID: f.sessionID, activity: AgentSessionActivity(detail: .tool(name: "Bash", argument: "rm x")))
        f.coordinator.handleRegistryRecord(record("waiting", waitingFor: "input needed"))
        XCTAssertEqual(f.coordinator.lifecycleState(for: f.sessionID), .awaitingInput(.permission))
        XCTAssertEqual(f.coordinator.activityStore.activity(for: f.sessionID)?.awaitingToolName, "Bash")
    }

    func testKillSwitchOffIgnoresRegistry() throws {
        let off = try makeFixture()
        off.registryEnabled.value = false
        off.coordinator.handleRegistryRecord(record("busy"))
        XCTAssertFalse(off.coordinator.registryLiveSessions.contains(off.sessionID))
    }

    func testBackgroundAndUnknownSessionsAreIgnored() throws {
        let bg = try makeFixture(background: true)
        bg.coordinator.handleRegistryRecord(record("busy"))
        XCTAssertFalse(bg.coordinator.registryLiveSessions.contains(bg.sessionID))
        bg.coordinator.handleRegistryRecord(record("busy", sessionID: "fremd"))
        XCTAssertTrue(bg.coordinator.registryLiveSessions.isEmpty)
    }

    func testTerminationEndsRegistryLiveAndIgnoresLateEvents() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.sessionTerminated(sessionID: f.sessionID, exitCode: 0)
        XCTAssertFalse(f.coordinator.registryLiveSessions.contains(f.sessionID))
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .stopped)
    }

    func testRemovedRecordFallsBackToOldPath() throws {
        let f = try makeFixture()
        f.coordinator.handleRegistryRecord(record("idle"))
        f.coordinator.handleRegistryRecordRemoved(record("idle"))
        XCTAssertFalse(f.coordinator.registryLiveSessions.contains(f.sessionID))
    }

    func testEndOfOldProcessKeepsResumedChatRegistryLive() throws {
        let f = try makeFixture()
        f.coordinator.handleRegistryRecord(record("idle", pid: 4711))
        f.coordinator.handleRegistryRecord(record("busy", pid: 4712)) // Resume, neuer Prozess
        f.coordinator.handleRegistryRecordRemoved(record("idle", pid: 4711))
        XCTAssertTrue(f.coordinator.registryLiveSessions.contains(f.sessionID))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .working)
    }

    func testClearBindsNewSessionIDOnFirstRegistryTurn() throws {
        // `/clear`: gleicher Prozess, neue Session-ID ohne Transcript — die
        // Bindung wird zurückgestellt; kein Turn-Hook mehr, der sie auflöst.
        let f = try makeFixture()
        f.coordinator.transcriptExistsOverride = { _, ext, _ in ext == "ext-1" }
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle"))
        var clear = hook(.sessionStart)
        clear.sessionID = "ext-2"
        clear.source = "clear"
        f.coordinator.handleHookEvent(localID: f.sessionID, event: clear)
        f.coordinator.handleRegistryRecord(record("idle", sessionID: "ext-2"))
        XCTAssertEqual(try currentExternalID(f), "ext-1", "ohne Turn bleibt die alte ID")

        f.coordinator.handleRegistryRecord(record("busy", sessionID: "ext-2"))
        XCTAssertEqual(try currentExternalID(f), "ext-2")
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .working)
        f.coordinator.handleRegistryRecord(record("idle", sessionID: "ext-2"))
        XCTAssertEqual(f.poster.posted.count, 1, "Turn-Ende nach /clear meldet „fertig“")
    }

    private func currentExternalID(_ f: Fixture) throws -> String? {
        try XCTUnwrap(f.store.loadWorkspace().sessions.first { $0.id == f.sessionID }).externalSessionID
    }

    func testPromptGuardBlockIsNoTurnEnd() throws {
        let f = try makeFixture()
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("idle", updatedAt: Date().addingTimeInterval(-10)))
        f.coordinator.handleRegistryRecord(record("busy", updatedAt: Date().addingTimeInterval(-1)))
        f.coordinator.handleHookEvent(localID: f.sessionID, event: hook(.promptGuardBlock))
        f.coordinator.handleRegistryRecord(record("idle", updatedAt: Date()))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .idle)
        XCTAssertTrue(f.poster.posted.isEmpty, "geblockter Prompt ist kein „fertig“")
        XCTAssertTrue(f.sounds.isEmpty)
    }

    func testRecordWithoutOwnTerminalIsIgnored() throws {
        // Dieselbe Session läuft in einem fremden Terminal (`claude --resume`).
        let f = try makeFixture()
        f.coordinator.hasRunningTerminal = { _ in false }
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.handleRegistryRecord(record("idle"))
        XCTAssertFalse(f.coordinator.registryLiveSessions.contains(f.sessionID))
        XCTAssertTrue(f.poster.posted.isEmpty)
        XCTAssertTrue(f.sounds.isEmpty)
    }

    func testBackgroundRecordNeverRevivesStoppedChat() throws {
        // `/background`: Die Session läuft beim Supervisor mit derselben ID
        // weiter, der PTY-Chat ist beendet.
        let f = try makeFixture()
        var clock = Date(timeIntervalSince1970: 1_792_000_000)
        f.coordinator.now = { clock }
        f.coordinator.sessionLaunched(sessionID: f.sessionID)
        f.coordinator.handleRegistryRecord(record("busy"))
        f.coordinator.sessionTerminated(sessionID: f.sessionID, exitCode: 0)
        clock = clock.addingTimeInterval(30)
        f.coordinator.handleRegistryRecord(record("busy", pid: 5000, kind: "bg"))
        f.coordinator.handleRegistryRecord(record("idle", pid: 5000, kind: "bg"))
        XCTAssertEqual(f.coordinator.statusStore.status(for: f.sessionID), .stopped)
        XCTAssertFalse(f.coordinator.registryLiveSessions.contains(f.sessionID))
        XCTAssertTrue(f.poster.posted.isEmpty)
    }

    // MARK: S4 — Hook-Satz

    func testReducedHookSetKeepsBindingAndGuardOnly() throws {
        let settings = ClaudeHookSettingsBuilder.makeSettings(
            eventFilePath: "/tmp/events.jsonl", promptGuardCommand: "guard",
            eventNames: ClaudeHookSettingsBuilder.registryModeEventNames)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["SessionStart", "SessionEnd", "UserPromptSubmit"])
        let guardEntries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(guardEntries.count, 1, "nur der Send-Guard, kein Status-Append")
        XCTAssertTrue(AgentSessionStatusCoordinator.usesReducedHooks(registryEnabled: true, isBackground: false))
        XCTAssertFalse(AgentSessionStatusCoordinator.usesReducedHooks(registryEnabled: true, isBackground: true))
        XCTAssertFalse(AgentSessionStatusCoordinator.usesReducedHooks(registryEnabled: false, isBackground: false))
    }

    func testPrepareLaunchWritesReducedHooksAndSessionStartIsNotHookLive() throws {
        let f = try makeFixture()
        let prep = f.coordinator.prepareLaunchSettings(localSessionID: f.sessionID)
        let path = try XCTUnwrap(prep.settingsFilePath)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["Stop"])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertTrue(f.coordinator.reducedHookSessions.contains(f.sessionID))

        // Kill-Switch aus → voller Satz.
        f.registryEnabled.value = false
        let full = f.coordinator.prepareLaunchSettings(localSessionID: f.sessionID)
        let fullJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(full.settingsFilePath)))) as? [String: Any])
        XCTAssertNotNil((fullJSON["hooks"] as? [String: Any])?["PreToolUse"])
        XCTAssertFalse(f.coordinator.reducedHookSessions.contains(f.sessionID))
    }

    // MARK: Quelle

    func testSourceDiffsScansAndReportsRemovals() {
        let source = ClaudeRegistryStatusSource(rootsProvider: { [] }, isAlive: { _, _ in true })
        var changed: [String] = []
        var removed: [String] = []
        source.onRecord = { changed.append("\($0.sessionID):\($0.rawStatus ?? "-")") }
        source.onRemoved = { removed.append($0.sessionID) }
        source.apply(scanned: [record("busy")])
        source.apply(scanned: [record("busy")])
        XCTAssertEqual(changed, ["ext-1:busy"], "unveränderter Eintrag meldet nichts")
        source.apply(pid: 4711, record: record("idle"))
        XCTAssertEqual(changed.last, "ext-1:idle")
        source.apply(scanned: [], startedAt: Date().addingTimeInterval(60))
        XCTAssertEqual(removed, ["ext-1"])
        XCTAssertNil(source.record(forExternalSessionID: "ext-1"))
    }

    func testOlderScanNeverOverridesNewerFileEvent() {
        let source = ClaudeRegistryStatusSource(rootsProvider: { [] }, isAlive: { _, _ in true })
        var clock = Date(timeIntervalSince1970: 1000)
        source.now = { clock }
        var removed: [String] = []
        source.onRemoved = { removed.append($0.sessionID) }
        let scanStart = clock
        clock = clock.addingTimeInterval(1)
        source.apply(pid: 4711, record: record("busy"))   // Ereignis nach Scan-Beginn
        source.apply(scanned: [], startedAt: scanStart)     // Scan sah die Datei noch nicht
        XCTAssertTrue(removed.isEmpty)
        source.apply(scanned: [record("idle")], startedAt: scanStart)
        XCTAssertEqual(source.recordsByPID[4711]?.status, .busy, "älterer Scan überschreibt nicht")
        // Ein späterer Scan darf wieder entfernen.
        source.apply(scanned: [], startedAt: clock.addingTimeInterval(1))
        XCTAssertEqual(removed, ["ext-1"])
    }

    func testScanBeforeDeletionNeverRevivesEndedProcess() {
        // Scan liest die Datei, Claude beendet sich und löscht sie, das
        // Lösch-Ereignis kommt vor dem Scan-Ergebnis an.
        let source = ClaudeRegistryStatusSource(rootsProvider: { [] }, isAlive: { _, _ in true })
        var clock = Date(timeIntervalSince1970: 1000)
        source.now = { clock }
        var changed = 0
        var removed = 0
        source.onRecord = { _ in changed += 1 }
        source.onRemoved = { _ in removed += 1 }
        source.apply(pid: 4711, record: record("busy"))
        clock = clock.addingTimeInterval(1)
        let scanStart = clock
        clock = clock.addingTimeInterval(1)
        source.apply(pid: 4711, record: nil)
        source.apply(scanned: [record("idle")], startedAt: scanStart)
        XCTAssertNil(source.recordsByPID[4711], "toter Eintrag kommt nicht zurück")
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(removed, 1)
        // Ein Scan nach dem Löschen sieht die Wahrheit; der Grabstein ist weg.
        source.apply(scanned: [], startedAt: clock.addingTimeInterval(1))
        XCTAssertEqual(removed, 1)
        source.apply(scanned: [record("busy")], startedAt: clock.addingTimeInterval(2))
        XCTAssertEqual(source.recordsByPID[4711]?.status, .busy, "neuer Prozess mit gleicher PID")
    }

    func testRescanWatchesSessionsFolderCreatedLater() async throws {
        let root = ClaudeSessionRegistry.Root(
            profileName: "neu", url: tempDir.appendingPathComponent("neu/sessions", isDirectory: true))
        let source = ClaudeRegistryStatusSource(rootsProvider: { [root] }, isAlive: { _, _ in true })
        await source.rescan()
        XCTAssertTrue(source.watchedPaths.isEmpty)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        await source.rescan()
        XCTAssertEqual(source.watchedPaths, [root.url.path])
        source.stop()
    }

    func testReadChangeSeparatesUnreadableFromRemoved() throws {
        let file = tempDir.appendingPathComponent("4711.json")
        XCTAssertEqual(ClaudeRegistryStatusSource.readChange(fileURL: file, profileName: "ai2", isAlive: { _, _ in true }),
                       .removed)
        try Data("{\"pid\": 47".utf8).write(to: file) // gerade beschrieben
        XCTAssertEqual(ClaudeRegistryStatusSource.readChange(fileURL: file, profileName: "ai2", isAlive: { _, _ in true }),
                       .unreadable)
        try Data("{\"pid\": 4711, \"sessionId\": \"ext-1\", \"status\": \"idle\"}".utf8).write(to: file)
        XCTAssertEqual(ClaudeRegistryStatusSource.readChange(fileURL: file, profileName: "ai2", isAlive: { _, _ in false }),
                       .removed)
        if case .record(let parsed) = ClaudeRegistryStatusSource.readChange(
            fileURL: file, profileName: "ai2", isAlive: { _, _ in true }) {
            XCTAssertEqual(parsed.status, .idle)
        } else {
            XCTFail("lebender Eintrag erwartet")
        }
    }

    func testScanCostStaysWithinBudget() throws {
        let dir = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        for index in 0..<20 {
            let json = "{\"pid\": \(pid), \"sessionId\": \"s\(index)\", \"status\": \"busy\", \"procStart\": \"Sat Oct 17 10:12:17 2026\", \"cwd\": \"/x\", \"name\": \"x-\(index)\"}"
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(100 + index).json"))
        }
        let started = Date()
        let records = ClaudeSessionRegistry.scan(roots: [.init(profileName: "main", url: dir)],
                                                 isAlive: ClaudeSessionRegistry.isProcessAlive)
        let perFileMs = Date().timeIntervalSince(started) * 1000 / 20
        XCTAssertEqual(records.count, 0, "Startzeit passt nicht → kein lebender Eintrag")
        XCTAssertLessThan(perFileMs, 1, "Budget: < 1 ms pro Datei inkl. sysctl")
    }

    // MARK: CLI

    func testProbeOverlayPrefersRegistry() {
        let estimate = ChatsRuntimeInfo(status: .idle, source: "transcriptEstimate", since: nil, revision: 42,
                                        transcriptPath: "/x.jsonl", transcriptSizeBytes: 42, availability: .available)
        let overlaid = ChatsStatusProbe.overlayRegistry(estimate, record: record("busy"))
        XCTAssertEqual(overlaid.status, .working)
        XCTAssertEqual(overlaid.source, "claudeRegistry")
        XCTAssertEqual(overlaid.revision, 42)
        XCTAssertEqual(ChatsStatusProbe.overlayRegistry(estimate, record: nil), estimate)
        XCTAssertEqual(ChatsStatusProbe.overlayRegistry(estimate, record: record("dreaming")), estimate)
        XCTAssertEqual(ChatsStatusProbe.overlayRegistry(estimate, record: record("busy", kind: "bg")), estimate,
                       "bg-Eintrag gehört nicht zum Chat")
    }

    func testRegistryCacheRefreshesAfterMaxAge() {
        var builds = 0
        let cache = ChatsRegistryCache(maxAge: 1) { builds += 1; return [:] }
        let start = Date()
        _ = cache.index(now: start)
        _ = cache.index(now: start.addingTimeInterval(0.5))
        XCTAssertEqual(builds, 1)
        _ = cache.index(now: start.addingTimeInterval(1.5))
        XCTAssertEqual(builds, 2)
    }
}
