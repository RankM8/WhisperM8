import Security
import XCTest
@testable import WhisperM8

/// Paket 4a: Manifest-Teile, Geheimnis im Schlüsselbund, Marker „übergeben“
/// und die Entscheidungstabellen. Alles ohne echte Prozesse.
final class HandoverManifestPartsTests: XCTestCase {
    func testLaunchCommandSurvivesManifestRoundTrip() throws {
        let command = AgentLaunchCommand(
            executablePath: "/opt/claude",
            arguments: ["--resume", "abc", "--settings", "/tmp/x.json"],
            workingDirectory: "/Users/u/repo",
            keyboardProfile: .codexChat,
            environmentOverrides: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-b"],
            environmentRemovals: ["B", "A"],
            isBackgroundAttachFallback: true,
            reboundExternalSessionID: "fork-1"
        )
        var manifest = HandoverManifest(chatID: UUID().uuidString, kind: "claude", pid: 42, cols: 80, rows: 24,
                                        sendsInterruptOnStop: true)
        manifest.launchCommand = try HandoverJSONValue(encoding: HandoverLaunchCommandSnapshot(command))

        // Weg über das Protokoll: kodieren, dekodieren, zurückwandeln.
        let wire = try JSONDecoder().decode(HandoverManifest.self, from: JSONEncoder().encode(manifest))
        let snapshot = try XCTUnwrap(wire.launchCommand?.decoded(as: HandoverLaunchCommandSnapshot.self))
        XCTAssertEqual(snapshot.launchCommand, command)
    }

    func testEveryKeyboardProfileHasAStableName() {
        let all: [TerminalKeyboardProfile] = [.claudeCodeChat, .codexChat, .claudeAgentsView, .plainShell]
        for profile in all {
            let name = HandoverLaunchCommandSnapshot.name(of: profile)
            XCTAssertEqual(HandoverLaunchCommandSnapshot.profile(named: name), profile)
        }
    }

    func testUnknownKeyboardProfileFromNewerAppGivesNoCommand() throws {
        var snapshot = HandoverLaunchCommandSnapshot(AgentLaunchCommand(
            executablePath: "/bin/zsh", arguments: [], workingDirectory: "/"))
        snapshot.keyboardProfile = "futureProfile"
        XCTAssertNil(snapshot.launchCommand)
    }

    func testForeignJSONDoesNotDecodeAsSnapshot() {
        XCTAssertNil(HandoverJSONValue.string("x").decoded(as: HandoverLaunchCommandSnapshot.self))
    }

    @MainActor
    func testPendingAccountSwitchRoundTrip() throws {
        let pending = AccountSwitchCoordinator.PendingSwitch(
            targetProfile: "work", targetName: "Work", reason: .unsentInput,
            since: Date(timeIntervalSince1970: 1_000))
        let value = try HandoverJSONValue(encoding: HandoverPendingAccountSwitch(pending))
        let back = try XCTUnwrap(value.decoded(as: HandoverPendingAccountSwitch.self))
        XCTAssertEqual(back.pendingSwitch, pending)
    }

    @MainActor
    func testPendingAccountSwitchWithUnknownReasonIsDropped() {
        var part = HandoverPendingAccountSwitch(AccountSwitchCoordinator.PendingSwitch(
            targetProfile: nil, targetName: "Main", reason: .turnRunning))
        part.reason = "somethingNew"
        XCTAssertNil(part.pendingSwitch)
    }

    func testChatKindFollowsSessionAndCommand() {
        let plain = AgentLaunchCommand(executablePath: "/x", arguments: [], workingDirectory: "/")
        let attach = AgentLaunchCommand(executablePath: "/x", arguments: ["attach", "id"], workingDirectory: "/")
        XCTAssertEqual(HandoverChatKind.of(kind: .chat, provider: .claude, command: plain), .claude)
        XCTAssertEqual(HandoverChatKind.of(kind: .chat, provider: .codex, command: plain), .codex)
        XCTAssertEqual(HandoverChatKind.of(kind: .terminal, provider: .claude, command: plain), .terminal)
        XCTAssertEqual(HandoverChatKind.of(kind: .backgroundChat, provider: .claude, command: attach), .attach)
        XCTAssertEqual(HandoverChatKind.of(kind: .chat, provider: .claude, command: attach), .attach)
        XCTAssertNil(HandoverChatKind.of(kind: .agentView, provider: .claude, command: plain))
        XCTAssertNil(HandoverChatKind.of(kind: .subagentJob, provider: .codex, command: plain))
    }
}

// MARK: - Geheimnis

private final class FakeHandoverKeychain: HandoverKeychainBackend, @unchecked Sendable {
    var items: [String: Data] = [:]
    var addStatus: OSStatus = errSecSuccess
    var copyStatus: OSStatus?
    var copyDelay: TimeInterval = 0
    private(set) var deletes = 0

    func add(service: String, account: String, data: Data) -> OSStatus {
        guard addStatus == errSecSuccess else { return addStatus }
        if items["\(service)/\(account)"] != nil { return errSecDuplicateItem }
        items["\(service)/\(account)"] = data
        return errSecSuccess
    }

    func copyData(service: String, account: String) -> (status: OSStatus, data: Data?) {
        if copyDelay > 0 { Thread.sleep(forTimeInterval: copyDelay) }
        if let copyStatus { return (copyStatus, nil) }
        guard let data = items["\(service)/\(account)"] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func delete(service: String, account: String) -> OSStatus {
        deletes += 1
        return items.removeValue(forKey: "\(service)/\(account)") == nil ? errSecItemNotFound : errSecSuccess
    }
}

final class HandoverSecretStoreTests: XCTestCase {
    private func store(_ backend: FakeHandoverKeychain, timeout: TimeInterval = 2) -> HandoverSecretStore {
        HandoverSecretStore(service: "test.handover", account: "keeper-x", backend: backend, timeout: timeout)
    }

    func testStoreLoadRemove() {
        let backend = FakeHandoverKeychain()
        let secret = HandoverSecret.make()
        XCTAssertTrue(store(backend).store(secret))
        XCTAssertEqual(store(backend).load(), .found(secret))
        store(backend).remove()
        XCTAssertEqual(store(backend).load(), .missing)
    }

    func testStoreReplacesOldSecretOfSameInstance() {
        let backend = FakeHandoverKeychain()
        XCTAssertTrue(store(backend).store(HandoverSecret.make()))
        let newer = HandoverSecret.make()
        XCTAssertTrue(store(backend).store(newer))
        XCTAssertEqual(store(backend).load(), .found(newer))
    }

    func testMalformedSecretIsNeitherStoredNorReturned() {
        let backend = FakeHandoverKeychain()
        XCTAssertFalse(store(backend).store("kurz"))
        backend.items["test.handover/keeper-x"] = Data("nicht hex, nicht lang genug".utf8)
        XCTAssertEqual(store(backend).load(), .missing)
    }

    func testRefusedAddReportsFailure() {
        let backend = FakeHandoverKeychain()
        backend.addStatus = errSecAuthFailed
        XCTAssertFalse(store(backend).store(HandoverSecret.make()))
    }

    /// Anders signierter Build: Der Schlüsselbund verlangt eine Bestätigung,
    /// die wir abschalten. Ergebnis ist „verweigert“, kein Dialog.
    func testInteractionNotAllowedIsDenied() {
        let backend = FakeHandoverKeychain()
        backend.copyStatus = errSecInteractionNotAllowed
        XCTAssertEqual(store(backend).load(), .denied(status: errSecInteractionNotAllowed))
    }

    func testSlowKeychainTimesOutInsteadOfHanging() {
        let backend = FakeHandoverKeychain()
        backend.copyDelay = 1
        let started = Date()
        XCTAssertEqual(store(backend, timeout: 0.1).load(), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
    }

    func testAccountDependsOnInstanceAndSignature() {
        let a = HandoverPaths(directory: URL(fileURLWithPath: "/tmp/a"))
        let b = HandoverPaths(directory: URL(fileURLWithPath: "/tmp/b"))
        let devA = HandoverSecretStore.account(for: a, signature: "dev")
        XCTAssertEqual(devA, HandoverSecretStore.account(for: a, signature: "dev"))
        XCTAssertNotEqual(devA, HandoverSecretStore.account(for: b, signature: "dev"))
        XCTAssertNotEqual(devA, HandoverSecretStore.account(for: a, signature: "brew"))
        XCTAssertFalse(devA.contains("/tmp"))
    }
}

// MARK: - Marker „übergeben“

final class HandoverMarkerTests: XCTestCase {
    private var markerURL: URL!

    override func setUp() {
        super.setUp()
        markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-handover-marker-\(UUID().uuidString)")
            .appendingPathComponent("running-sessions.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: markerURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func marker(pid: Int32) -> AgentCrashRecoveryMarker {
        AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: pid, isProcessAlive: { _ in false })
    }

    private func handover(_ ids: [UUID]) -> AgentCrashRecoveryMarker.HandedOver {
        AgentCrashRecoveryMarker.HandedOver(
            keeperPID: 900, keeperStartTime: 1.5, runID: "run-1",
            chats: ids.enumerated().map { .init(sessionID: $1, pid: Int32(1000 + $0), pidStartTime: 2.5) })
    }

    func testHandedOverMarkerReachesNextStart() {
        let a = UUID(), b = UUID(), failed = UUID()
        let old = marker(pid: 100)
        _ = old.beginRun()
        old.record(runningSessionIDs: [a, b, failed])
        old.markHandedOver(handover([a, b]), alsoResume: [failed])
        // Späte PTY-Ereignisse beim Beenden ändern nichts mehr.
        old.record(runningSessionIDs: [])
        old.endRunCleanly()

        let previous = marker(pid: 200).beginRunDetailed()
        XCTAssertEqual(previous.handover, handover([a, b]))
        XCTAssertEqual(Set(previous.runningSessionIDs), [a, b, failed])
    }

    func testCrashBeforeTakeKeepsHandoverForTheStartAfter() {
        let a = UUID()
        let old = marker(pid: 100)
        _ = old.beginRun()
        old.markHandedOver(handover([a]))

        let crashed = marker(pid: 200)
        XCTAssertNotNil(crashed.beginRunDetailed().handover)
        crashed.record(runningSessionIDs: [UUID()])
        // Absturz vor `finishHandoverTake`.

        XCTAssertEqual(marker(pid: 300).beginRunDetailed().handover, handover([a]))
    }

    func testFinishedTakeClearsHandover() {
        let old = marker(pid: 100)
        _ = old.beginRun()
        old.markHandedOver(handover([UUID()]))

        let next = marker(pid: 200)
        _ = next.beginRunDetailed()
        let adopted = UUID()
        next.record(runningSessionIDs: [adopted])
        next.finishHandoverTake()
        // Absturz danach: nur noch die laufenden Chats, kein „übergeben“ mehr.
        let after = marker(pid: 300).beginRunDetailed()
        XCTAssertNil(after.handover)
        XCTAssertEqual(after.runningSessionIDs, [adopted])
    }

    func testCleanQuitBeforeFinishedTakeKeepsHandover() {
        let a = UUID()
        let old = marker(pid: 100)
        _ = old.beginRun()
        old.markHandedOver(handover([a]))

        let next = marker(pid: 200)
        _ = next.beginRunDetailed()
        next.endRunCleanly()
        XCTAssertEqual(marker(pid: 300).beginRunDetailed().handover, handover([a]))
    }

    func testOldMarkerWithoutHandoverFieldStillReads() throws {
        let a = UUID()
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"{"pid":100,"runningSessionIDs":["\#(a.uuidString)"],"updatedAt":0}"#
        try Data(legacy.utf8).write(to: markerURL)
        let previous = marker(pid: 200).beginRunDetailed()
        XCTAssertEqual(previous.runningSessionIDs, [a])
        XCTAssertNil(previous.handover)
    }
}

// MARK: - Entscheidungen

final class HandoverPlanningTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    private var candidates: [HandoverQuitCandidate] {
        [
            HandoverQuitCandidate(sessionID: a, kind: .claude, hasLiveProcess: true),
            HandoverQuitCandidate(sessionID: b, kind: .terminal, hasLiveProcess: true),
            HandoverQuitCandidate(sessionID: c, kind: nil, hasLiveProcess: true),
            HandoverQuitCandidate(sessionID: d, kind: .codex, hasLiveProcess: false),
        ]
    }

    func testQuitTable() {
        XCTAssertEqual(HandoverPlanning.quitPlan(featureEnabled: false, trigger: .restartRequest, keeper: .none,
                                                 candidates: candidates), .classic(.featureDisabled))
        XCTAssertEqual(HandoverPlanning.quitPlan(featureEnabled: true, trigger: .userQuit, keeper: .none,
                                                 candidates: candidates), .classic(.notARestart))
        XCTAssertEqual(HandoverPlanning.quitPlan(featureEnabled: true, trigger: .systemQuit, keeper: .none,
                                                 candidates: candidates), .classic(.notARestart))
        XCTAssertEqual(HandoverPlanning.quitPlan(featureEnabled: true, trigger: .restartRequest,
                                                 keeper: .holdingUntakenChats, candidates: candidates),
                       .classic(.keeperStillHolding))
        XCTAssertEqual(HandoverPlanning.quitPlan(featureEnabled: true, trigger: .restartRequest, keeper: .unknown,
                                                 candidates: candidates), .classic(.keeperUnknown))
        XCTAssertEqual(
            HandoverPlanning.quitPlan(featureEnabled: true, trigger: .restartRequest, keeper: .none,
                                      candidates: candidates + [candidates[0]]),
            .restart(handOver: [a, b], excluded: [c: .kindNotHandedOver, d: .notRunning]))
    }

    func testRestartWithoutChatsStillRestarts() {
        XCTAssertEqual(HandoverPlanning.quitPlan(featureEnabled: true, trigger: .restartRequest, keeper: .none,
                                                 candidates: []),
                       .restart(handOver: [], excluded: [:]))
    }

    private let marker = AgentCrashRecoveryMarker.HandedOver(keeperPID: 900, keeperStartTime: nil, runID: "run-1",
                                                             chats: [])

    func testLaunchTable() {
        let secret = HandoverSecret.make()
        let keeper = HandoverKeeperObservation(runID: "run-1", pid: 900, compatible: true)
        XCTAssertEqual(HandoverPlanning.launchPlan(markerHandover: nil, keeper: nil, secret: .missing), .nothing)
        XCTAssertEqual(HandoverPlanning.launchPlan(markerHandover: marker, keeper: nil, secret: .found(secret)),
                       .keeperGone)
        XCTAssertEqual(HandoverPlanning.launchPlan(markerHandover: marker, keeper: keeper, secret: .found(secret)),
                       .take(secret: secret))
        var incompatible = keeper
        incompatible.compatible = false
        XCTAssertEqual(HandoverPlanning.launchPlan(markerHandover: marker, keeper: incompatible, secret: .found(secret)),
                       .release(secret: secret))
        // Ohne Geheimnis (anders signiert, Schlüsselbund verweigert oder hängt)
        // und bei fremdem Lauf: geordnet beenden lassen, dann fortsetzen.
        for lookup in [HandoverSecretLookup.missing, .denied(status: errSecInteractionNotAllowed), .timedOut] {
            XCTAssertEqual(HandoverPlanning.launchPlan(markerHandover: marker, keeper: keeper, secret: lookup),
                           .terminateKeeper(pid: 900))
        }
        var foreign = keeper
        foreign.runID = "run-0"
        XCTAssertEqual(HandoverPlanning.launchPlan(markerHandover: marker, keeper: foreign, secret: .found(secret)),
                       .terminateKeeper(pid: 900))
        // Aufbewahrer ohne Marker: niemand kennt seine Chats, er wird beendet.
        XCTAssertEqual(HandoverPlanning.launchPlan(markerHandover: nil, keeper: keeper, secret: .missing),
                       .terminateKeeper(pid: 900))
    }

    func testChatActionTable() {
        typealias P = HandoverPlanning
        XCTAssertEqual(P.chatAction(outcome: .adopted, processAlive: true, resumable: true), .adopt)
        XCTAssertEqual(P.chatAction(outcome: .endedInGap(exitStatus: 0), processAlive: false, resumable: true),
                       .showEnded)
        XCTAssertEqual(P.chatAction(outcome: .notTaken, processAlive: true, resumable: true), .terminateThenResume)
        XCTAssertEqual(P.chatAction(outcome: .notTaken, processAlive: true, resumable: false), .terminate)
        XCTAssertEqual(P.chatAction(outcome: .notTaken, processAlive: false, resumable: true), .resume)
        XCTAssertEqual(P.chatAction(outcome: .notTaken, processAlive: false, resumable: false), .none)
    }

    func testSameProcessNeedsMatchingStartTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(HandoverPlanning.isSameProcess(pid: 50, expectedStartTime: 1_000,
                                                     isAlive: { _ in true }, startTime: { _ in start }))
        // PID neu vergeben.
        XCTAssertFalse(HandoverPlanning.isSameProcess(pid: 50, expectedStartTime: 999,
                                                      isAlive: { _ in true }, startTime: { _ in start }))
        XCTAssertFalse(HandoverPlanning.isSameProcess(pid: 50, expectedStartTime: 1_000,
                                                      isAlive: { _ in false }, startTime: { _ in start }))
        // Startzeit unbekannt: im Zweifel „lebt“, damit kein zweiter Prozess startet.
        XCTAssertTrue(HandoverPlanning.isSameProcess(pid: 50, expectedStartTime: nil,
                                                     isAlive: { _ in true }, startTime: { _ in nil }))
        XCTAssertFalse(HandoverPlanning.isSameProcess(pid: 1, expectedStartTime: nil,
                                                      isAlive: { _ in true }, startTime: { _ in nil }))
    }

    func testSameProcessAgainstRealOwnProcess() {
        let own = getpid()
        let start = ProcessStartTime.of(pid: own)?.timeIntervalSince1970
        XCTAssertNotNil(start)
        XCTAssertTrue(HandoverPlanning.isSameProcess(pid: own, expectedStartTime: start))
        XCTAssertFalse(HandoverPlanning.isSameProcess(pid: own, expectedStartTime: (start ?? 0) - 10))
    }

    func testResumableKinds() {
        XCTAssertTrue(HandoverPlanning.isResumable(.chat))
        XCTAssertTrue(HandoverPlanning.isResumable(.backgroundChat))
        XCTAssertFalse(HandoverPlanning.isResumable(.terminal))
        XCTAssertFalse(HandoverPlanning.isResumable(.agentView))
        XCTAssertFalse(HandoverPlanning.isResumable(.subagentJob))
    }
}

// MARK: - Token

final class HandoverTokenRegistryTests: XCTestCase {
    func testRegisteredTokenVerifiesAndBindsProcess() {
        let id = UUID()
        defer { AgentSessionTokenRegistry.shared.revoke(sessionID: id) }
        AgentSessionTokenRegistry.shared.register(token: "tok-1", for: id, pid: 4242, isAttach: true)
        XCTAssertTrue(AgentSessionTokenRegistry.shared.verify(sessionID: id, token: "tok-1"))
        XCTAssertFalse(AgentSessionTokenRegistry.shared.verify(sessionID: id, token: "tok-2"))
        XCTAssertEqual(AgentSessionTokenRegistry.shared.processID(for: id), 4242)
        XCTAssertTrue(AgentSessionTokenRegistry.shared.attachSessionIDs().contains(id))
        // Spätes Ende des übernommenen Laufs widerruft genau dieses Token.
        AgentSessionTokenRegistry.shared.revoke(sessionID: id, ifToken: "tok-1")
        XCTAssertFalse(AgentSessionTokenRegistry.shared.verify(sessionID: id, token: "tok-1"))
    }

    func testEmptyTokenIsIgnored() {
        let id = UUID()
        AgentSessionTokenRegistry.shared.register(token: "", for: id, pid: 1, isAttach: false)
        XCTAssertNil(AgentSessionTokenRegistry.shared.processID(for: id))
    }
}

final class HandoverProcessLivenessTests: XCTestCase {
    func testZombieCountsAsEnded() throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, nil), 0)
        XCTAssertGreaterThan(pid, 0)
        defer { var status: Int32 = 0; waitpid(pid, &status, 0) }
        // Kurz warten, bis das Kind beendet ist (Zombie, nicht abgeholt).
        let end = Date().addingTimeInterval(5)
        while HandoverPlanning.isRunningProcess(pid), Date() < end { usleep(10_000) }
        XCTAssertFalse(HandoverPlanning.isRunningProcess(pid))
        XCTAssertEqual(kill(pid, 0), 0, "der Zombie existiert noch")
        XCTAssertTrue(HandoverPlanning.isRunningProcess(getpid()))
    }
}

// MARK: - Stellschrauben und debug state

final class HandoverTestKnobsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "handover-knobs-\(UUID().uuidString)")!
    }

    func testKnobsOnlyWorkInTheTestInstance() {
        let d = defaults()
        d.set(5.0, forKey: HandoverTestKnobs.holdSecondsKey)
        d.set(250, forKey: HandoverTestKnobs.takeDelayKey)
        d.set("missing", forKey: HandoverTestKnobs.secretOverrideKey)
        let secret = HandoverSecret.make()

        XCTAssertNil(HandoverTestKnobs.holdSeconds(defaults: d, active: false))
        XCTAssertEqual(HandoverTestKnobs.takeDelay(defaults: d, active: false), 0)
        XCTAssertEqual(HandoverTestKnobs.secret(.found(secret), defaults: d, active: false), .found(secret))

        XCTAssertEqual(HandoverTestKnobs.holdSeconds(defaults: d, active: true), 5)
        XCTAssertEqual(HandoverTestKnobs.takeDelay(defaults: d, active: true), 0.25)
        XCTAssertEqual(HandoverTestKnobs.secret(.found(secret), defaults: d, active: true), .missing)
        d.set("wrong", forKey: HandoverTestKnobs.secretOverrideKey)
        guard case .found(let wrong) = HandoverTestKnobs.secret(.found(secret), defaults: d, active: true) else {
            return XCTFail("falsches Geheimnis erwartet")
        }
        XCTAssertNotEqual(wrong, secret)
    }

    func testUnsetKnobsChangeNothing() {
        let d = defaults()
        XCTAssertNil(HandoverTestKnobs.holdSeconds(defaults: d, active: true))
        XCTAssertEqual(HandoverTestKnobs.takeDelay(defaults: d, active: true), 0)
        XCTAssertEqual(HandoverTestKnobs.secret(.missing, defaults: d, active: true), .missing)
    }

    func testPreviousRunKinds() {
        typealias M = AgentCrashRecoveryMarker
        XCTAssertEqual(M.PreviousRun.none.kind, "clean")
        XCTAssertEqual(M.PreviousRun(runningSessionIDs: [UUID()], handover: nil).kind, "resume")
        let handover = M.HandedOver(keeperPID: 1, keeperStartTime: nil, runID: "r", chats: [])
        XCTAssertEqual(M.PreviousRun(runningSessionIDs: [], handover: handover).kind, "handedOver")
    }

    func testDebugStateNamesPreviousRunAndTake() {
        typealias M = AgentCrashRecoveryMarker
        let adopted = UUID()
        var summary = HandoverTakeService.Summary(previous: M.PreviousRun(
            runningSessionIDs: [adopted],
            handover: M.HandedOver(keeperPID: 1, keeperStartTime: nil, runID: "r9", chats: [])))
        summary.adopted = [adopted]
        let state = AgentControlRequestHandler.restartDebugState(summary)
        XCTAssertEqual(state["previousRun"] as? String, "handedOver")
        let take = state["take"] as? [String: Any]
        XCTAssertEqual(take?["runID"] as? String, "r9")
        XCTAssertEqual(take?["adopted"] as? [String], [adopted.uuidString])
        XCTAssertEqual(AgentControlRequestHandler.restartDebugState(nil)["previousRun"] as? String, "unknown")
    }
}
