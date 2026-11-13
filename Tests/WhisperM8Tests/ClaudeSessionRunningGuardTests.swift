import XCTest
@testable import WhisperM8

/// Nie zwei Prozesse auf einer Claude-Sitzung (Paket 0 aus
/// `docs/plans/neustart-ohne-chatverlust.md`). Vor diesem Stand baute der
/// Builder `--resume` auch dann, wenn die Sitzung in einem anderen lebenden
/// Vordergrund-Prozess lief; geschützt waren nur Hintergrund-Worker.
final class ClaudeSessionRunningGuardTests: XCTestCase {
    private func record(_ sessionID: String, pid: Int32, kind: String? = "interactive") -> ClaudeSessionRecord {
        ClaudeSessionRecord(profileName: "main", pid: pid, sessionID: sessionID, kind: kind)
    }

    private func makeBuilder(running: ClaudeSessionRecord?) -> AgentCommandBuilder {
        var builder = AgentCommandBuilder(commandResolver: { "/usr/local/bin/\($0)" })
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.backgroundWorkerResolver = { _, _ in nil }
        builder.runningSessionProcessResolver = { sessionID in
            running?.sessionID == sessionID ? running : nil
        }
        return builder
    }

    private let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)

    private func resumeSession(_ externalID: String) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: project.id, externalSessionID: externalID,
                         title: "Claude", hasLaunchedInitialPrompt: true)
    }

    // MARK: Builder

    func testResumeIsRefusedWhileTheSessionRunsInAnotherProcess() {
        let builder = makeBuilder(running: record("abc", pid: 4242))
        XCTAssertThrowsError(try builder.command(for: resumeSession("abc"), project: project)) { error in
            XCTAssertEqual(error as? AgentCommandError, .sessionAlreadyRunning(title: "Claude", pid: 4242))
            XCTAssertTrue(error.localizedDescription.contains("4242"))
        }
    }

    func testResumeProceedsWhenNoProcessRunsTheSession() throws {
        let builder = makeBuilder(running: nil)
        let command = try builder.command(for: resumeSession("abc"), project: project)
        XCTAssertEqual(command.arguments, ["--resume", "abc"])
    }

    func testOtherSessionsDoNotBlock() throws {
        let builder = makeBuilder(running: record("other", pid: 4242))
        let command = try builder.command(for: resumeSession("abc"), project: project)
        XCTAssertEqual(command.arguments, ["--resume", "abc"])
    }

    func testForkMayStartWhileTheSourceRuns() throws {
        // Ein Abzweig bekommt eine neue Sitzungs-ID, das Original läuft bewusst weiter.
        let builder = makeBuilder(running: record("source", pid: 4242))
        var fork = AgentChatSession(provider: .claude, projectID: project.id, title: "Abzweig",
                                    hasLaunchedInitialPrompt: true)
        fork.forkSourceSessionID = "source"
        let command = try builder.command(for: fork, project: project)
        XCTAssertEqual(command.arguments, ["--resume", "source", "--fork-session"])
    }

    func testBackgroundWorkerStillAttachesInsteadOfBeingRefused() throws {
        var builder = makeBuilder(running: record("abc", pid: 4242))
        builder.backgroundWorkerResolver = { sessionID, _ in .init(shortID: "1f353dce", sessionID: sessionID) }
        let command = try builder.command(for: resumeSession("abc"), project: project)
        XCTAssertEqual(command.arguments, ["attach", "1f353dce"])
    }

    // MARK: Auswahl

    func testBackgroundRecordsAreLeftToTheAttachFallback() {
        let found = ClaudeSessionRunningGuard.runningForegroundProcess(
            sessionID: "abc", records: [record("abc", pid: 1, kind: "bg")], isBeingTerminated: { _ in false })
        XCTAssertNil(found)
    }

    func testSessionIDMatchIgnoresCase() {
        let found = ClaudeSessionRunningGuard.runningForegroundProcess(
            sessionID: "ABC", records: [record("abc", pid: 7)], isBeingTerminated: { _ in false })
        XCTAssertEqual(found?.pid, 7)
    }

    func testProcessTheAppIsTerminatingDoesNotBlockARestart() {
        let found = ClaudeSessionRunningGuard.runningForegroundProcess(
            sessionID: "abc", records: [record("abc", pid: 7)], isBeingTerminated: { $0 == 7 })
        XCTAssertNil(found)
    }

    func testLiveLookupIsOffOutsideTheApp() {
        // Unter `swift test` kein Blick auf echte Claude-Prozesse des Rechners.
        XCTAssertNil(ClaudeSessionRunningGuard.liveLookup(sessionID: "abc"))
        XCTAssertTrue(ClaudeSessionRunningGuard.liveForegroundRecords().isEmpty)
    }

    func testPrescannedListIsCheckedAgainstTheTerminationLedger() {
        let records = [record("abc", pid: 31_337)]
        XCTAssertEqual(ClaudeSessionRunningGuard.runningForegroundProcess(sessionID: "abc", in: records)?.pid, 31_337)
        ProcessTerminationLedger.shared.noteTerminating(pid: 31_337)
        XCTAssertNil(ClaudeSessionRunningGuard.runningForegroundProcess(sessionID: "abc", in: records),
                     "erst beim Bauen gefragt: ein gerade beendeter Prozess sperrt nicht")
    }

    // MARK: Zweites Fenster

    /// Derselbe Chat in zwei Fenstern: Der zweite Start darf gar nicht erst bauen,
    /// wenn der Controller dieser App schon läuft, sonst meldet die Sperre den
    /// eigenen Prozess als fremd. Die Detailansicht fragt vor dem Bauen genau
    /// dieses Tor (`prepareCommand`).
    @MainActor
    func testRunningControllerOfThisAppStopsTheLaunchBeforeTheBuilder() {
        let registry = AgentTerminalRegistry(sleep: { _ in })
        let id = UUID()
        XCTAssertTrue(AgentCommandBuilder.allowsTriggeredLaunch(
            controllerIsRunning: registry.controller(for: id)?.isRunning))
        registry.startController(
            sessionID: id,
            command: AgentLaunchCommand(executablePath: "/bin/sleep", arguments: ["30"],
                                        workingDirectory: NSTemporaryDirectory(), keyboardProfile: .claudeCodeChat),
            onLaunched: {}, onTerminated: { _ in })
        defer { _ = registry.terminateAll() }
        XCTAssertFalse(AgentCommandBuilder.allowsTriggeredLaunch(
            controllerIsRunning: registry.controller(for: id)?.isRunning))
    }

    // MARK: Vermerk „wird beendet“

    func testLedgerForgetsAfterItsWindow() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let ledger = ProcessTerminationLedger(window: 30, now: { clock })
        ledger.noteTerminating(pid: 99)
        XCTAssertTrue(ledger.isBeingTerminated(pid: 99))
        XCTAssertFalse(ledger.isBeingTerminated(pid: 100))
        clock = clock.addingTimeInterval(31)
        XCTAssertFalse(ledger.isBeingTerminated(pid: 99))
    }

    func testLedgerIgnoresInvalidPIDs() {
        let ledger = ProcessTerminationLedger()
        ledger.noteTerminating(pid: 0)
        XCTAssertFalse(ledger.isBeingTerminated(pid: 0))
    }
}

/// Was die Sperre tut, wenn zwei Chats dieselbe Sitzung tragen (Befund
/// 13.11.2026, „soak bash“/„soak question“ auf cd00c6c0). Der Builder sieht nur
/// die Registry: Läuft die Sitzung schon, verweigert er den zweiten Resume.
/// Starten beide im selben Augenblick (Wiederaufnahme, Grid), steht der erste
/// Prozess noch nicht in der Registry — dann greift die Reservierung der App
/// (`ClaudeSessionLaunchReservations`, Paket a).
final class ClaudeSessionRunningGuardSharedBindingTests: XCTestCase {
    private let project = AgentProject(name: "Repo", path: FileManager.default.temporaryDirectory.path)

    private func builder(registry: [ClaudeSessionRecord],
                         reservations: ClaudeSessionLaunchReservations? = nil) -> AgentCommandBuilder {
        var builder = AgentCommandBuilder(commandResolver: { "/usr/local/bin/\($0)" })
        if let reservations {
            builder.launchReservation = { reservations.reserve(sessionID: $0, for: $1) }
        }
        builder.gptFastModeEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.backgroundWorkerResolver = { _, _ in nil }
        builder.runningSessionProcessResolver = { id in registry.first(where: { $0.sessionID == id }) }
        return builder
    }

    private func chat(_ title: String) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: project.id, externalSessionID: "cd00c6c0",
                         title: title, hasLaunchedInitialPrompt: true)
    }

    func testSecondResumeOfSharedSessionIsRefusedOnceTheFirstRuns() {
        let running = ClaudeSessionRecord(profileName: "main", pid: 777, sessionID: "cd00c6c0", kind: "interactive")
        XCTAssertThrowsError(try builder(registry: [running]).command(for: chat("soak question"), project: project)) {
            XCTAssertEqual($0 as? AgentCommandError, .sessionAlreadyRunning(title: "soak question", pid: 777))
        }
    }

    func testSimultaneousResumesOfSharedSessionStartOnlyOnce() throws {
        // Leere Registry beim Start beider — früher bauten beide `--resume`.
        let empty = builder(registry: [], reservations: ClaudeSessionLaunchReservations())
        XCTAssertEqual(try empty.command(for: chat("soak bash"), project: project).arguments, ["--resume", "cd00c6c0"])
        XCTAssertThrowsError(try empty.command(for: chat("soak question"), project: project)) {
            XCTAssertEqual($0 as? AgentCommandError, .sessionStartingElsewhere(title: "soak question"))
            XCTAssertTrue($0.localizedDescription.contains("soak question"))
        }
    }

    func testRegistryBlockComesFirstAndForkIsNeverReserved() throws {
        let reservations = ClaudeSessionLaunchReservations()
        let running = ClaudeSessionRecord(profileName: "main", pid: 777, sessionID: "cd00c6c0", kind: "interactive")
        XCTAssertThrowsError(try builder(registry: [running], reservations: reservations)
            .command(for: chat("soak bash"), project: project)) {
            XCTAssertEqual($0 as? AgentCommandError, .sessionAlreadyRunning(title: "soak bash", pid: 777))
        }
        XCTAssertNil(reservations.reserve(sessionID: "cd00c6c0", for: UUID()), "abgelehnter Start reserviert nichts")

        let fresh = ClaudeSessionLaunchReservations()
        _ = fresh.reserve(sessionID: "quelle", for: UUID())
        var fork = AgentChatSession(provider: .claude, projectID: project.id, title: "Abzweig", hasLaunchedInitialPrompt: true)
        fork.forkSourceSessionID = "quelle"
        XCTAssertEqual(try builder(registry: [], reservations: fresh).command(for: fork, project: project).arguments,
                       ["--resume", "quelle", "--fork-session"], "Abzweig bekommt eine neue ID")
    }
}

final class ClaudeSessionLaunchReservationsTests: XCTestCase {
    func testOtherChatIsRefusedSameChatMayRestart() {
        let reservations = ClaudeSessionLaunchReservations()
        let first = UUID(), second = UUID()
        XCTAssertNil(reservations.reserve(sessionID: "cd00c6c0", for: first))
        XCTAssertNil(reservations.reserve(sessionID: "cd00c6c0", for: first), "Tab-Neustart desselben Chats")
        XCTAssertEqual(reservations.reserve(sessionID: "CD00C6C0", for: second), first)
        XCTAssertNil(reservations.reserve(sessionID: "aa82d0ba", for: second), "andere Sitzung unberührt")
    }

    func testReservationEndsAfterWindow() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let reservations = ClaudeSessionLaunchReservations(window: 30, now: { clock })
        let first = UUID(), second = UUID()
        XCTAssertNil(reservations.reserve(sessionID: "cd00c6c0", for: first))
        clock = clock.addingTimeInterval(29)
        XCTAssertEqual(reservations.reserve(sessionID: "cd00c6c0", for: second), first)
        clock = clock.addingTimeInterval(2)
        XCTAssertNil(reservations.reserve(sessionID: "cd00c6c0", for: second), "danach entscheidet die Registry")
    }
}
