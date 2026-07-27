import XCTest
@testable import WhisperM8

// MARK: - Send-Bereitschaft (Start-Race)

final class ChatsSendReadinessGuardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testLaunchingBlocksTheWrite() {
        // Der belegte Fall: resume + sofort send meldete Erfolg, während die
        // Transcript-Revision 30 s unverändert blieb.
        let decision = ChatsSendReadinessGuard.decide(
            lifecycle: .launching, launchedAt: now.addingTimeInterval(-2), now: now)
        XCTAssertEqual(decision, .notReady(sinceSec: 2))

        let message = try? XCTUnwrap(ChatsSendReadinessGuard.message(for: decision))
        XCTAssertTrue(message?.contains("startet noch") ?? false)
        XCTAssertTrue(message?.contains("enqueue") ?? false, "der sichere Weg muss genannt werden")
        XCTAssertTrue(message?.contains("2 s") ?? false)
    }

    func testEveryOtherLifecycleIsAllowed() {
        let allowed: [AgentSessionLifecycleState] = [
            .ready, .working, .turnDone, .awaitingInput(.permission), .stopped, .errored, .created,
        ]
        for state in allowed {
            XCTAssertEqual(ChatsSendReadinessGuard.decide(lifecycle: state, now: now), .allowed,
                           "\(state) darf nicht blockieren")
        }
    }

    func testUnknownSessionIsNotBlockedByThisGuard() {
        // Extern gestartete Sessions kennt die App nicht — dort greift wie
        // bisher nur der Runtime-Status, wir blockieren nicht zusätzlich.
        XCTAssertEqual(ChatsSendReadinessGuard.decide(lifecycle: nil, now: now), .allowed)
    }

    func testMessageIsNilWhenAllowed() {
        XCTAssertNil(ChatsSendReadinessGuard.message(for: .allowed))
    }

    func testMissingLaunchTimeStillProducesAUsableMessage() {
        let decision = ChatsSendReadinessGuard.decide(lifecycle: .launching, launchedAt: nil, now: now)
        XCTAssertEqual(decision, .notReady(sinceSec: nil))
        XCTAssertTrue(ChatsSendReadinessGuard.message(for: decision)?.contains("enqueue") ?? false)
    }
}

// MARK: - Fehlercode-Vertrag

final class ChatsControlErrorCodeContractTests: XCTestCase {
    func testNotReadyMapsToConflictExitAndIsRetryable() {
        XCTAssertEqual(ChatsControlErrorCode.notReady.exitCode, ChatsCLIExit.conflict)
        XCTAssertTrue(ChatsControlErrorCode.notReady.isRetryable)
        XCTAssertEqual(ChatsControlErrorCode.notReady.alternative, "enqueue")
    }

    func testTerminalErrorsAreNotRetryable() {
        for code: ChatsControlErrorCode in [.notFound, .selfSend, .invalid, .unsupported, .internalError] {
            XCTAssertFalse(code.isRetryable, code.rawValue)
        }
    }

    func testExitCodesStayStable() {
        // Vertrag: Agenten verlassen sich auf diese Zuordnung.
        XCTAssertEqual(ChatsControlErrorCode.notFound.exitCode, ChatsCLIExit.notFound)
        XCTAssertEqual(ChatsControlErrorCode.conflict.exitCode, ChatsCLIExit.conflict)
        XCTAssertEqual(ChatsControlErrorCode.invalid.exitCode, ChatsCLIExit.usage)
    }
}

// MARK: - Zustandsachsen

final class ChatsSessionAxesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func build(
        status: AgentChatStatus = .running,
        kind: AgentSessionKind = .chat,
        lifecycle: String? = nil,
        runtime: AgentSessionRuntimeStatus? = nil,
        reason: AwaitingInputKind? = nil,
        pty: Bool? = nil,
        source: String = "app",
        since: Date? = nil,
        observedAt: Date? = nil
    ) -> ChatsSessionAxes {
        ChatsSessionAxesBuilder.build(
            status: status, kind: kind, lifecycle: lifecycle, runtimeStatus: runtime,
            awaitingReason: reason, isAttachedPTY: pty, source: source,
            statusSince: since, observedAt: observedAt, now: now)
    }

    func testCatalogSeparatesRetentionFromProcess() {
        XCTAssertEqual(build(status: .running).catalog, .active)
        XCTAssertEqual(build(status: .closed).catalog, .inactive)
        XCTAssertEqual(build(status: .archived).catalog, .archived)
    }

    func testLaunchingSurvivesAsItsOwnState() {
        // Kern der Race-Prävention: launching darf NICHT zu ready/idle werden.
        let axes = build(lifecycle: "launching", runtime: .idle)
        XCTAssertEqual(axes.conversation.state, .launching)
        XCTAssertNotEqual(axes.conversation.state, .ready)
    }

    func testLifecycleWinsOverRuntimeStatus() {
        // Der Lifecycle ist feiner; ohne diesen Vorrang wäre turnDone von
        // ready nicht unterscheidbar.
        XCTAssertEqual(build(lifecycle: "turnDone", runtime: .idle).conversation.state, .turnDone)
        XCTAssertEqual(build(lifecycle: "ready", runtime: .idle).conversation.state, .ready)
    }

    func testRuntimeStatusIsTheFallbackWithoutLifecycle() {
        XCTAssertEqual(build(runtime: .working).conversation.state, .working)
        XCTAssertEqual(build(runtime: .awaitingInput).conversation.state, .needsInput)
        XCTAssertEqual(build(runtime: .idle).conversation.state, .ready)
        XCTAssertEqual(build(runtime: nil).conversation.state, .unknown)
    }

    func testReasonOnlyAppearsWithNeedsInput() {
        let asking = build(lifecycle: "awaitingInput", reason: .question)
        XCTAssertEqual(asking.conversation.reason, .question)
        XCTAssertEqual(asking.conversation.json["reason"] as? String, "question")

        let working = build(lifecycle: "working", reason: .question)
        XCTAssertNil(working.conversation.reason, "ein Grund ohne Rückfrage wäre irreführend")
        XCTAssertNil(working.conversation.json["reason"])
    }

    func testAllAwaitingReasonsSurvive() {
        for reason: AwaitingInputKind in [.permission, .question, .planApproval] {
            XCTAssertEqual(build(lifecycle: "awaitingInput", reason: reason).conversation.reason, reason)
        }
    }

    func testForegroundWorkerFollowsThePTY() {
        XCTAssertEqual(build(pty: true).execution.worker, .alive)
        XCTAssertEqual(build(pty: true).execution.mode, .foreground)
        XCTAssertEqual(build(runtime: .stopped, pty: false).execution.worker, .exited)
        XCTAssertEqual(build(runtime: .idle, pty: false).execution.worker, .missing,
                       "idle ohne PTY ist eine Anomalie, kein sauberer Exit")
    }

    func testBackgroundAttachmentIsNoProofOfWorker() {
        // Das PTY ist dort nur `claude attach` — es zu sehen sagt nichts
        // darüber, ob der Supervisor-Job läuft.
        let axes = build(kind: .backgroundChat, pty: true)
        XCTAssertEqual(axes.execution.mode, .background)
        XCTAssertEqual(axes.execution.attachment, .attached)
        XCTAssertEqual(axes.execution.worker, .unknown, "kein Beleg aus dem Attachment ableiten")
    }

    func testMissingLiveInfoYieldsUnknownNotFalseCertainty() {
        let axes = build(runtime: .working, pty: nil)
        XCTAssertEqual(axes.execution.attachment, .unknown)
        XCTAssertEqual(axes.execution.mode, .unknown)
        XCTAssertEqual(axes.execution.worker, .unknown)
    }

    func testEvidenceDistinguishesObservedFromInferred() {
        XCTAssertEqual(build(source: "app").evidence.quality, .observed)
        XCTAssertEqual(build(source: "hook").evidence.quality, .observed)
        XCTAssertEqual(build(source: "supervisorJob").evidence.quality, .observed)
        XCTAssertEqual(build(source: "transcriptEstimate").evidence.quality, .inferred)
        XCTAssertEqual(build(source: "irgendwas").evidence.quality, .unknown)
    }

    func testEvidenceCarriesObservationAge() {
        let axes = build(observedAt: now.addingTimeInterval(-2.5))
        XCTAssertEqual(axes.evidence.ageMs, 2_500)
        XCTAssertEqual(axes.evidence.json["ageMs"] as? Int, 2_500)
    }

    func testSinceSecIsNeverNegative() {
        // Uhrensprünge dürfen keine negativen Alter erzeugen.
        let axes = build(since: now.addingTimeInterval(60))
        XCTAssertEqual(axes.conversation.sinceSec, 0)
    }

    func testJSONOmitsAbsentOptionalsInsteadOfNullPadding() {
        let axes = build(runtime: .working)
        let json = axes.conversation.json
        XCTAssertEqual(json["state"] as? String, "working")
        XCTAssertNil(json["reason"])
        XCTAssertNil(json["sinceSec"])
        XCTAssertNil(axes.evidence.json["ageMs"])
    }
}
