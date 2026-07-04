import XCTest
@testable import WhisperM8

/// Übergangsmatrix der Session-State-Machine — inklusive der Out-of-order-
/// und Degraded-Fälle (fehlende/verspätete Hooks), die den früheren
/// „neuer Chat pulsiert als aktiv"-Bug ausgemacht haben.
final class AgentSessionStateMachineTests: XCTestCase {
    private func reduce(
        _ state: AgentSessionLifecycleState,
        _ signal: AgentSessionSignal
    ) -> AgentSessionStateMachine.Transition {
        AgentSessionStateMachine.reduce(state: state, signal: signal)
    }

    // MARK: Der Kern-Bugfix: neuer Chat ohne Prompt pulsiert nicht

    func testFreshLaunchIsNotWorking() {
        let launched = reduce(.created, .processLaunched)
        XCTAssertEqual(launched.state, .launching)
        XCTAssertEqual(launched.state.runtimeStatus, .idle, "Launch darf keinen Arbeits-Puls zeigen")
        XCTAssertTrue(launched.effects.isEmpty)

        let started = reduce(.launching, .sessionStarted)
        XCTAssertEqual(started.state, .ready)
        XCTAssertEqual(started.state.runtimeStatus, .idle)
        XCTAssertTrue(started.effects.isEmpty)
    }

    func testLaunchGraceDegradesToReadyOnlyFromLaunching() {
        XCTAssertEqual(reduce(.launching, .launchGraceExpired).state, .ready)
        XCTAssertEqual(reduce(.working, .launchGraceExpired).state, .working)
        XCTAssertEqual(reduce(.awaitingInput(.permission), .launchGraceExpired).state, .awaitingInput(.permission))
    }

    func testFirstPromptStartsWorking() {
        let transition = reduce(.ready, .userPromptSubmitted)
        XCTAssertEqual(transition.state, .working)
        XCTAssertEqual(transition.state.runtimeStatus, .working)
    }

    // MARK: Turn-Ende + Effekte

    func testStopFromWorkingCompletesTurnWithEffect() {
        let transition = reduce(.working, .turnStopped)
        XCTAssertEqual(transition.state, .turnDone)
        XCTAssertEqual(transition.effects, [.turnCompleted])
    }

    func testDuplicateStopHasNoEffect() {
        let transition = reduce(.turnDone, .turnStopped)
        XCTAssertEqual(transition.state, .turnDone)
        XCTAssertTrue(transition.effects.isEmpty, "Doppel-Stop darf nicht doppelt benachrichtigen")
    }

    func testDeciderTurnFinishedAfterStopHookHasNoSecondEffect() {
        // Stop-Hook war schneller; der Transcript-Decider erkennt dasselbe
        // Turn-Ende kurz danach → kein zweiter Effekt (Dedup über Zustand).
        let transition = reduce(.turnDone, .transcriptIdle(turnFinished: true))
        XCTAssertEqual(transition.state, .turnDone)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testDeciderTurnFinishedWithoutStopHookCompletesTurn() {
        // Degraded (Hooks stumm): der Decider allein beendet den Turn.
        let transition = reduce(.working, .transcriptIdle(turnFinished: true))
        XCTAssertEqual(transition.state, .turnDone)
        XCTAssertEqual(transition.effects, [.turnCompleted])
    }

    func testStopFromAwaitingCompletesTurn() {
        let transition = reduce(.awaitingInput(.permission), .turnStopped)
        XCTAssertEqual(transition.state, .turnDone)
        XCTAssertEqual(transition.effects, [.turnCompleted])
    }

    // MARK: Rückfragen (awaitingInput)

    func testPermissionRequestAsksForInputWithEffect() {
        let transition = reduce(.working, .permissionRequested)
        XCTAssertEqual(transition.state, .awaitingInput(.permission))
        XCTAssertEqual(transition.effects, [.inputRequested(.permission)])
    }

    func testRepeatedPermissionRequestHasNoEffect() {
        let transition = reduce(.awaitingInput(.permission), .permissionRequested)
        XCTAssertEqual(transition.state, .awaitingInput(.permission))
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testAskUserQuestionToolBecomesAwaiting() {
        let transition = reduce(.working, .toolWillRun(toolName: "AskUserQuestion"))
        XCTAssertEqual(transition.state, .awaitingInput(.question))
        XCTAssertEqual(transition.effects, [.inputRequested(.question)])
    }

    func testExitPlanModeToolBecomesAwaiting() {
        let transition = reduce(.working, .toolWillRun(toolName: "ExitPlanMode"))
        XCTAssertEqual(transition.state, .awaitingInput(.planApproval))
        XCTAssertEqual(transition.effects, [.inputRequested(.planApproval)])
    }

    func testRegularToolUseIsJustWorking() {
        let transition = reduce(.ready, .toolWillRun(toolName: "Bash"))
        XCTAssertEqual(transition.state, .working)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testPostToolUseResolvesAwaiting() {
        let transition = reduce(.awaitingInput(.question), .toolDidRun)
        XCTAssertEqual(transition.state, .working)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testTranscriptCannotOverrideAwaiting() {
        // Während eines Permission-Dialogs zeigt die JSONL „working" —
        // der Hook weiß es besser.
        XCTAssertEqual(reduce(.awaitingInput(.permission), .transcriptActivity).state, .awaitingInput(.permission))
        XCTAssertEqual(reduce(.awaitingInput(.permission), .transcriptIdle(turnFinished: true)).state, .awaitingInput(.permission))
    }

    // MARK: SessionStart-Sonderfälle

    func testSessionStartDoesNotDowngradeRunningTurn() {
        // Auto-Compact feuert SessionStart mitten im Turn.
        XCTAssertEqual(reduce(.working, .sessionStarted).state, .working)
        XCTAssertEqual(reduce(.awaitingInput(.question), .sessionStarted).state, .awaitingInput(.question))
        XCTAssertEqual(reduce(.turnDone, .sessionStarted).state, .turnDone)
    }

    // MARK: Transcript-Fallback

    func testTranscriptActivityMovesLaunchingToWorking() {
        // Resume mit Initial-Prompt, Hooks verspätet: Transcript zeigt Arbeit.
        XCTAssertEqual(reduce(.launching, .transcriptActivity).state, .working)
        XCTAssertEqual(reduce(.ready, .transcriptActivity).state, .working)
    }

    func testStaleTranscriptIdleMeansReadyWithoutEffects() {
        // Resume einer alten Session: letzter Turn längst vorbei
        // (turnFinished == false) → bereit, aber kein „fertig"-Effekt.
        let transition = reduce(.launching, .transcriptIdle(turnFinished: false))
        XCTAssertEqual(transition.state, .ready)
        XCTAssertTrue(transition.effects.isEmpty)
    }

    func testTurnDoneStaysTurnDoneOnStaleIdle() {
        XCTAssertEqual(reduce(.turnDone, .transcriptIdle(turnFinished: false)).state, .turnDone)
    }

    // MARK: Prozessende

    func testCleanExitStops() {
        XCTAssertEqual(reduce(.working, .processTerminated(exitCode: 0)).state, .stopped)
        XCTAssertEqual(reduce(.ready, .processTerminated(exitCode: nil)).state, .stopped)
    }

    func testFailedExitErrors() {
        XCTAssertEqual(reduce(.working, .processTerminated(exitCode: 1)).state, .errored)
    }

    func testTerminatedSessionIgnoresWeakLateSignals() {
        // Verspätete schwache Signale (Decider, Tool-Events, Stop) nach
        // Prozessende dürfen den finalen Zustand nicht wiederbeleben.
        XCTAssertEqual(reduce(.stopped, .turnStopped).state, .stopped)
        XCTAssertEqual(reduce(.stopped, .transcriptActivity).state, .stopped)
        XCTAssertEqual(reduce(.stopped, .toolDidRun).state, .stopped)
        XCTAssertEqual(reduce(.stopped, .transcriptIdle(turnFinished: true)).state, .stopped)
        XCTAssertEqual(reduce(.stopped, .turnAborted).state, .stopped)
        XCTAssertTrue(reduce(.stopped, .turnStopped).effects.isEmpty)

        XCTAssertEqual(reduce(.stopped, .processLaunched).state, .launching, "Relaunch belebt die Session")
    }

    func testStrongHookSignalsReviveTerminatedSession() {
        // Hook-Events kommen nur von einem lebenden Prozess: SessionStart/
        // UserPromptSubmit nach `stopped` beweisen, dass die Session lebt
        // (falsch eingeschätzter SessionEnd-Reason, BG-Respawn).
        XCTAssertEqual(reduce(.stopped, .sessionStarted).state, .ready)
        XCTAssertEqual(reduce(.stopped, .userPromptSubmitted).state, .working)
        XCTAssertEqual(reduce(.errored, .userPromptSubmitted).state, .working)
    }

    func testSessionEndWithInPlaceReasonKeepsSessionAlive() {
        // /clear, /resume, Auto-Compact: Prozess lebt weiter, gleich kommt
        // ein frisches SessionStart — nur awaiting wird aufgeräumt.
        XCTAssertEqual(reduce(.awaitingInput(.permission), .sessionEnded(reason: "clear")).state, .ready)
        XCTAssertEqual(reduce(.working, .sessionEnded(reason: "resume")).state, .working)
        XCTAssertEqual(reduce(.turnDone, .sessionEnded(reason: "compact")).state, .turnDone)
    }

    func testSessionEndWithTerminalReasonStops() {
        // Alle anderen Reasons SIND das Prozessende aus Hook-Sicht — ohne
        // diesen Übergang blieben Background-Agents (kein PTY → nie
        // processTerminated) für immer auf .idle = grüner Punkt.
        XCTAssertEqual(reduce(.working, .sessionEnded(reason: "prompt_input_exit")).state, .stopped)
        XCTAssertEqual(reduce(.turnDone, .sessionEnded(reason: "logout")).state, .stopped)
        XCTAssertEqual(reduce(.ready, .sessionEnded(reason: "other")).state, .stopped)
        XCTAssertEqual(reduce(.awaitingInput(.question), .sessionEnded(reason: nil)).state, .stopped)
        XCTAssertTrue(reduce(.working, .sessionEnded(reason: "other")).effects.isEmpty, "Session-Ende ist kein Turn-Ende — keine Fertig-Notification")
    }

    func testTurnAbortedReturnsToReadyWithoutEffects() {
        // ESC-Interrupt: Stop-Hook feuert nicht — das Transcript-Signal muss
        // den Chat aus working/awaiting holen, ohne Fertig-Notification.
        let fromWorking = reduce(.working, .turnAborted)
        XCTAssertEqual(fromWorking.state, .ready)
        XCTAssertTrue(fromWorking.effects.isEmpty)

        let fromAwaiting = reduce(.awaitingInput(.permission), .turnAborted)
        XCTAssertEqual(fromAwaiting.state, .ready)
        XCTAssertTrue(fromAwaiting.effects.isEmpty)

        // Außerhalb eines Turns ist ein (alter) Interrupt-Marker bedeutungslos.
        XCTAssertEqual(reduce(.turnDone, .turnAborted).state, .turnDone)
        XCTAssertEqual(reduce(.ready, .turnAborted).state, .ready)
    }

    // MARK: UI-Mapping

    func testRuntimeStatusMapping() {
        XCTAssertNil(AgentSessionLifecycleState.created.runtimeStatus)
        XCTAssertEqual(AgentSessionLifecycleState.launching.runtimeStatus, .idle)
        XCTAssertEqual(AgentSessionLifecycleState.ready.runtimeStatus, .idle)
        XCTAssertEqual(AgentSessionLifecycleState.working.runtimeStatus, .working)
        XCTAssertEqual(AgentSessionLifecycleState.awaitingInput(.question).runtimeStatus, .awaitingInput)
        XCTAssertEqual(AgentSessionLifecycleState.turnDone.runtimeStatus, .idle)
        XCTAssertEqual(AgentSessionLifecycleState.stopped.runtimeStatus, .stopped)
        XCTAssertEqual(AgentSessionLifecycleState.errored.runtimeStatus, .errored)
    }

    // MARK: Hook-Event → Signal-Mapping

    func testHookEventSignalMapping() {
        func event(_ name: ClaudeHookEvent.EventName, tool: String? = nil, reason: String? = nil) -> ClaudeHookEvent {
            ClaudeHookEvent(
                hookEventName: name,
                sessionID: "abc",
                transcriptPath: nil,
                cwd: nil,
                reason: reason,
                toolName: tool,
                rawJSON: "{}"
            )
        }

        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.sessionStart)), .sessionStarted)
        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.userPromptSubmit)), .userPromptSubmitted)
        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.preToolUse, tool: "AskUserQuestion")), .toolWillRun(toolName: "AskUserQuestion"))
        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.postToolUse, tool: "Bash")), .toolDidRun)
        // Fehlgeschlagenes Tool = weiterhin Aktivität (Claude verarbeitet den Fehler).
        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.postToolUseFailure, tool: "Bash")), .toolDidRun)
        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.permissionRequest)), .permissionRequested)
        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.stop)), .turnStopped)
        XCTAssertEqual(AgentSessionSignal(hookEvent: event(.sessionEnd, reason: "resume")), .sessionEnded(reason: "resume"))
        XCTAssertNil(AgentSessionSignal(hookEvent: event(.notification)), "Defensive Notification-Events bleiben statuslos")
        XCTAssertNil(AgentSessionSignal(hookEvent: event(.other)))
    }

    // MARK: Notification-Drossel

    func testNotificationThrottleSuppressesFlutterButAllowsDistinctKinds() {
        var throttle = AgentNotificationThrottle(minimumInterval: 2.0)
        let sessionID = UUID()
        let base = Date()
        let awaiting = AgentSessionUserNotification(
            kind: .inputRequested(.permission), localSessionID: sessionID, title: "T", projectName: nil
        )
        let done = AgentSessionUserNotification(
            kind: .turnCompleted, localSessionID: sessionID, title: "T", projectName: nil
        )

        XCTAssertTrue(throttle.shouldPost(awaiting, now: base))
        XCTAssertFalse(throttle.shouldPost(awaiting, now: base.addingTimeInterval(0.5)), "Flattern gleicher Art wird gedrosselt")
        XCTAssertTrue(throttle.shouldPost(done, now: base.addingTimeInterval(0.6)), "Andere Art ist echte Information")
        XCTAssertTrue(throttle.shouldPost(awaiting, now: base.addingTimeInterval(3.0)), "Nach Ablauf wieder erlaubt")
    }
}
