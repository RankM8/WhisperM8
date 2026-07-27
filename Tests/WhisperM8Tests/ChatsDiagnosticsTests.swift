import XCTest
@testable import WhisperM8

// MARK: - Blockadeerklärung für wartende Folgeaufträge

final class ChatsQueueBlockExplainerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func testNothingWaitingNeedsNoExplanation() {
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 0, runtimeStatus: "working", statusSince: ago(9_999),
            transcriptModifiedAt: ago(9_999), hasProcess: true, now: now)
        XCTAssertEqual(reason, .none)
        XCTAssertNil(ChatsQueueBlockExplainer.line(for: reason))
        XCTAssertNil(ChatsQueueBlockExplainer.code(for: reason))
    }

    func testIdleTargetIsNotWarnedAbout() {
        // idle + wartender Auftrag ist ein Übergangszustand — eine Warnung
        // wäre hier Dauerrauschen.
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 1, runtimeStatus: "idle", statusSince: ago(600),
            transcriptModifiedAt: ago(600), hasProcess: true, now: now)
        XCTAssertEqual(reason, .none)
    }

    func testActivelyWorkingTargetIsNormalWaiting() {
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 2, runtimeStatus: "working", statusSince: ago(30),
            transcriptModifiedAt: ago(5), hasProcess: true, now: now)
        XCTAssertEqual(reason, .waitingForTurnEnd(status: "working"))
        XCTAssertEqual(ChatsQueueBlockExplainer.code(for: reason), "waitingForTurnEnd")
        XCTAssertFalse(ChatsQueueBlockExplainer.line(for: reason)?.contains("⚠︎") ?? true)
    }

    func testLongRunningToolIsNotFlaggedWhileTranscriptGrows() {
        // Der Kernschutz gegen Fehlalarm: Ein 20-Minuten-Build, der weiter
        // schreibt, ist gesund — auch wenn der Status lange „working" ist.
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 1, runtimeStatus: "working", statusSince: ago(1_200),
            transcriptModifiedAt: ago(20), hasProcess: true, now: now)
        XCTAssertEqual(reason, .waitingForTurnEnd(status: "working"))
    }

    func testStalledOnlyWhenBothStatusAndTranscriptAreOld() {
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 1, runtimeStatus: "working", statusSince: ago(2_700),
            transcriptModifiedAt: ago(2_700), hasProcess: true, now: now)
        guard case .stalled(let status, let statusAge, let transcriptAge) = reason else {
            return XCTFail("erwartet: stalled, war: \(reason)")
        }
        XCTAssertEqual(status, "working")
        XCTAssertEqual(statusAge, 2_700)
        XCTAssertEqual(transcriptAge, 2_700)

        let line = try? XCTUnwrap(ChatsQueueBlockExplainer.line(for: reason))
        XCTAssertTrue(line?.contains("⚠︎") ?? false)
        XCTAssertTrue(line?.contains("unglaubwürdig") ?? false)
        XCTAssertTrue(line?.contains("erzwinge nichts") ?? false, "die Meldung darf nie zum Erzwingen einladen")
        XCTAssertEqual(ChatsQueueBlockExplainer.code(for: reason), "stalled")
    }

    func testFreshStatusWithOldTranscriptIsNotYetStalled() {
        // Status gerade erst gewechselt → der Turn kann eben erst begonnen
        // haben; noch kein Grund für eine Warnung.
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 1, runtimeStatus: "working", statusSince: ago(10),
            transcriptModifiedAt: ago(3_000), hasProcess: true, now: now)
        XCTAssertEqual(reason, .waitingForTurnEnd(status: "working"))
    }

    func testMissingProcessIsItsOwnReason() {
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 1, runtimeStatus: "stopped", statusSince: ago(60),
            transcriptModifiedAt: ago(60), hasProcess: false, now: now)
        XCTAssertEqual(reason, .noProcess)
        XCTAssertTrue(ChatsQueueBlockExplainer.line(for: reason)?.contains("resume") ?? false)
    }

    func testUnknownStatusAndMissingTimestampsDoNotCrash() {
        let reason = ChatsQueueBlockExplainer.reason(
            openCount: 1, runtimeStatus: nil, statusSince: nil,
            transcriptModifiedAt: nil, hasProcess: true, now: now)
        XCTAssertEqual(reason, .none, "ohne Statusmeinung wird nichts behauptet")
    }
}

// MARK: - Statushistorie

final class ChatsStatusJournalTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private let session = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("journal.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTransitionsArePersistedInOrder() {
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: session, from: nil, to: "idle", signal: "sessionStarted", source: "hook")
        journal.append(sessionID: session, from: "idle", to: "working", signal: "userPromptSubmitted", source: "hook")
        journal.append(sessionID: session, from: "working", to: "idle", signal: "turnStopped", source: "hook")

        let history = ChatsStatusJournal.recent(sessionID: session, fileURL: url)
        XCTAssertEqual(history.map(\.to), ["idle", "working", "idle"], "älteste zuerst")
        XCTAssertEqual(history.map(\.signal), ["sessionStarted", "userPromptSubmitted", "turnStopped"])
        XCTAssertEqual(history.first?.from, nil)
    }

    func testUnchangedStatusIsNotRecorded() {
        // Ein Journal voller identischer Zeilen verdeckt die echten Wechsel.
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: session, from: "working", to: "working", signal: "toolWillRun", source: "hook")
        XCTAssertTrue(ChatsStatusJournal.recent(sessionID: session, fileURL: url).isEmpty)
    }

    func testForeignSessionsAreFilteredOut() {
        let journal = ChatsStatusJournal(fileURL: url)
        let other = UUID()
        journal.append(sessionID: other, from: "idle", to: "working", signal: "x", source: "hook")
        journal.append(sessionID: session, from: "idle", to: "working", signal: "y", source: "hook")
        let history = ChatsStatusJournal.recent(sessionID: session, fileURL: url)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.signal, "y")
    }

    func testLimitKeepsTheNewestEntries() {
        let journal = ChatsStatusJournal(fileURL: url)
        for index in 0..<10 {
            journal.append(sessionID: session, from: "\(index)", to: "\(index + 1)",
                           signal: "s\(index)", source: "hook")
        }
        let history = ChatsStatusJournal.recent(sessionID: session, limit: 3, fileURL: url)
        XCTAssertEqual(history.map(\.signal), ["s7", "s8", "s9"], "die jüngsten, in Reihenfolge")
    }

    func testSourceDistinguishesHookFromEstimate() {
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: session, from: "idle", to: "working", signal: "transcriptActivity", source: "transcript")
        XCTAssertEqual(ChatsStatusJournal.recent(sessionID: session, fileURL: url).first?.source, "transcript")
    }

    func testMissingFileYieldsEmptyHistory() {
        let missing = directory.appendingPathComponent("gibt-es-nicht.jsonl")
        XCTAssertTrue(ChatsStatusJournal.recent(sessionID: session, fileURL: missing).isEmpty)
    }

    func testCorruptLinesAreSkippedNotFatal() throws {
        let journal = ChatsStatusJournal(fileURL: url)
        journal.append(sessionID: session, from: "idle", to: "working", signal: "gut", source: "hook")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{kaputt\n".utf8))
        try handle.close()
        XCTAssertEqual(ChatsStatusJournal.recent(sessionID: session, fileURL: url).count, 1)
    }
}

// MARK: - Signal-Beschriftung (Neustart, Resume, fehlende Hooks)

final class ChatsStatusJournalLabelTests: XCTestCase {
    func testEveryLifecycleSignalHasAStableLabel() {
        let cases: [(AgentSessionSignal, String)] = [
            (.processLaunched, "processLaunched"),
            (.launchGraceExpired, "launchGraceExpired"),
            (.sessionStarted, "sessionStarted"),
            (.userPromptSubmitted, "userPromptSubmitted"),
            (.toolWillRun(toolName: "Bash"), "toolWillRun"),
            (.toolDidRun, "toolDidRun"),
            (.turnStopped, "turnStopped"),
            (.sessionEnded(reason: "clear"), "sessionEnded"),
            (.transcriptActivity, "transcriptActivity"),
            (.transcriptIdle(turnFinished: true), "transcriptIdle"),
            (.turnAborted, "turnAborted"),
        ]
        for (signal, expected) in cases {
            XCTAssertEqual(AgentSessionStatusCoordinator.journalLabel(for: signal), expected)
        }
    }

    func testLabelIgnoresAssociatedValues() {
        // Stabil über Versionen: derselbe Signaltyp ergibt dieselbe Zeile,
        // egal welches Tool oder welcher Grund dranhängt.
        XCTAssertEqual(
            AgentSessionStatusCoordinator.journalLabel(for: .toolWillRun(toolName: "Read")),
            AgentSessionStatusCoordinator.journalLabel(for: .toolWillRun(toolName: "Bash")))
        XCTAssertEqual(
            AgentSessionStatusCoordinator.journalLabel(for: .sessionEnded(reason: "a")),
            AgentSessionStatusCoordinator.journalLabel(for: .sessionEnded(reason: nil)))
    }
}

// MARK: - Neustart, Resume und fehlende Hook-Events auf Ebene der State-Machine

final class AgentSessionResumeStateTests: XCTestCase {
    /// Der reproduzierte Ablauf: Session gestoppt → resume → SessionStart-Hook.
    /// Danach MUSS idle stehen, sonst blockiert ein vorgemerkter Auftrag.
    func testResumeWithHookLeadsToIdleNotWorking() {
        var state = AgentSessionLifecycleState.stopped
        state = AgentSessionStateMachine.reduce(state: state, signal: .processLaunched).state
        XCTAssertEqual(state, .launching)
        XCTAssertEqual(state.runtimeStatus, .idle)

        state = AgentSessionStateMachine.reduce(state: state, signal: .sessionStarted).state
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(state.runtimeStatus, .idle, "ein Resume allein ist kein laufender Turn")
    }

    /// Fehlende Hook-Events (Hooks aus, Codex): der Grace-Timer muss dieselbe
    /// Landung erzeugen — sonst bliebe die Session in `launching` hängen.
    func testResumeWithoutHooksAlsoLandsOnIdle() {
        var state = AgentSessionLifecycleState.stopped
        state = AgentSessionStateMachine.reduce(state: state, signal: .processLaunched).state
        state = AgentSessionStateMachine.reduce(state: state, signal: .launchGraceExpired).state
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(state.runtimeStatus, .idle)
    }

    /// Der Vorfall vom 2026-07-26: Nach dem Resume wurde eine Systemmeldung
    /// eingespeist und als echter Turn verarbeitet. Das ist KEIN Fehler — der
    /// Chat arbeitet wirklich — und muss sauber wieder auf idle enden.
    func testInjectedSystemMessageIsARealTurnThatEndsCleanly() {
        var state = AgentSessionLifecycleState.ready
        state = AgentSessionStateMachine.reduce(state: state, signal: .userPromptSubmitted).state
        XCTAssertEqual(state.runtimeStatus, .working)

        state = AgentSessionStateMachine.reduce(state: state, signal: .turnStopped).state
        XCTAssertEqual(state.runtimeStatus, .idle, "nach dem Turn steht die Queue-Zustellung an")
    }

    /// Ein Tool-Lauf direkt nach dem Resume — ohne Prompt — setzt working.
    /// Genau dieser Pfad ist der Verdachtsfall; der Test hält fest, dass ein
    /// späterer Stop ihn wieder auflöst.
    func testToolRunAfterResumeSetsWorkingAndStopResolvesIt() {
        var state = AgentSessionLifecycleState.ready
        state = AgentSessionStateMachine.reduce(state: state, signal: .toolWillRun(toolName: "Bash")).state
        XCTAssertEqual(state.runtimeStatus, .working)

        state = AgentSessionStateMachine.reduce(state: state, signal: .turnStopped).state
        XCTAssertEqual(state.runtimeStatus, .idle)
    }
}
