import Foundation
import XCTest
@testable import WhisperM8

/// Paddle-Aktionen im Ausführer (Plan `controller-xbox-paddles.md`, Schritt 4).
@MainActor
final class ControllerActionDispatcherPaddleTests: XCTestCase {
    private var window: ControllerWindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: ControllerTerminalSpy!
    private var dictation: ControllerDictationSpy!
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var chat = UUID()
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        dictation = ControllerDictationSpy()
        haptics = []
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation,
            environment: ControllerEnvironmentSpy(), ui: ControllerUIModel(), island: ControllerIslandSpy(),
            now: { [now] in now })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        chat = UUID()
        window.selected = chat
        setTerminal(.idle)
    }

    private func setTerminal(
        _ status: AgentSessionRuntimeStatus?, profile: ControllerChatState.Profile = .claude,
        draft: Bool = false, queued: Int = 0, for id: UUID? = nil
    ) {
        var state = ControllerTerminalState(
            isRunning: true, profile: profile, status: status, statusSince: nil,
            draftSuspected: draft, lastEnterAt: nil, lastEscapeAt: nil)
        state.queuedOwnPrompts = queued
        terminals.states[id ?? chat] = state
    }

    private func perform(_ action: ControllerAction) {
        dispatcher.perform(action, in: dispatcher.snapshot().chat.map { .chat($0) } ?? .list)
    }

    // MARK: Nächster wartender Chat

    func testNextWaitingUsesTheKeyboardWay() {
        perform(.nextWaitingChat)
        XCTAssertEqual(window.commands.last, .nextWaitingChat)
        XCTAssertTrue(haptics.isEmpty)
        window.failing = [String(describing: AgentChatsCommand.nextWaitingChat)]
        perform(.nextWaitingChat)
        XCTAssertEqual(haptics, [.rejected])
    }

    // MARK: Antworten

    func testAnswerGoesToTheFreshDoneChatAndDictates() {
        let fresh = UUID()
        setTerminal(.idle, for: fresh)
        dispatcher.freshDoneChats = { [fresh] }
        perform(.answerNextWaiting)
        XCTAssertEqual(window.selected, fresh)
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: fresh)])
    }

    func testAnswerOnlyJumpsIntoAQuestion() {
        let fresh = UUID()
        setTerminal(.awaitingInput, for: fresh)
        dispatcher.freshDoneChats = { [fresh] }
        perform(.answerNextWaiting)
        XCTAssertEqual(window.selected, fresh)
        XCTAssertTrue(dictation.started.isEmpty, "nie in eine Rückfrage diktieren")
    }

    func testAnswerDoesNotDictateWhenTheSwitchFailed() {
        let fresh = UUID()
        setTerminal(.idle, for: fresh)
        dispatcher.freshDoneChats = { [fresh] }
        window.failing = [String(describing: AgentChatsCommand.selectSession(fresh))]
        perform(.answerNextWaiting)
        XCTAssertTrue(dictation.started.isEmpty)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testAnswerWithoutFreshChatJumpsToTheNextWaitingOne() {
        dispatcher.freshDoneChats = { [] }
        perform(.answerNextWaiting)
        XCTAssertEqual(window.commands.last, .nextWaitingChat)
        XCTAssertTrue(dictation.started.isEmpty)
    }

    func testAnswerDictatesHereWhenTheCurrentChatIsTheOnlyCandidate() {
        dispatcher.freshDoneChats = { [self.chat] }
        window.failing = [String(describing: AgentChatsCommand.nextWaitingChat)]
        perform(.answerNextWaiting)
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: chat)])
    }

    func testAnswerWithNothingToDoIsRejected() {
        window.failing = [String(describing: AgentChatsCommand.nextWaitingChat)]
        perform(.answerNextWaiting)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertTrue(dictation.started.isEmpty)
    }

    // MARK: Jetzt senden / Weiter

    func testSendNowWhileWorkingWithText() {
        setTerminal(.working, draft: true)
        perform(.sendNowOrContinue)
        XCTAssertEqual(terminals.keys, [.sendNow])
    }

    /// Claude: wie R1 + Kreuz immer „Jetzt senden“ (wie Ctrl+Enter), auch
    /// ruhend und bei leerem Feld; kein „Weiter“ als Text.
    func testClaudeAlwaysSendsNow() {
        setTerminal(.idle, draft: true)
        perform(.sendNowOrContinue)
        setTerminal(.idle)
        perform(.sendNowOrContinue)
        XCTAssertEqual(terminals.keys, [.sendNow, .sendNow])
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    func testSendWhileIdleWithTextInCodex() {
        setTerminal(.idle, profile: .codex, draft: true)
        perform(.sendNowOrContinue)
        XCTAssertEqual(terminals.keys, [.enter])
    }

    func testContinueWhenEmptyAndIdleInCodex() {
        setTerminal(.idle, profile: .codex)
        perform(.sendNowOrContinue)
        XCTAssertEqual(terminals.texts.map(\.text), [ControllerMenuText.continueWork])
    }

    func testRejectedWhenCodexWorks() {
        setTerminal(.working, profile: .codex)
        perform(.sendNowOrContinue)
        XCTAssertTrue(terminals.keys.isEmpty)
        XCTAssertTrue(terminals.texts.isEmpty)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testRejectedInAQuestionAndInAShell() {
        setTerminal(.awaitingInput, draft: true)
        perform(.sendNowOrContinue)
        setTerminal(.idle, profile: .shell)
        perform(.sendNowOrContinue)
        XCTAssertTrue(terminals.keys.isEmpty)
        XCTAssertTrue(terminals.texts.isEmpty)
        XCTAssertEqual(haptics, [.rejected, .rejected])
    }

    // MARK: Modus, Befehle

    func testCycleModeOnlyWhileIdle() {
        perform(.cycleMode)
        XCTAssertEqual(terminals.keys, [.backTab])
        setTerminal(.working)
        perform(.cycleMode)
        setTerminal(.awaitingInput)
        perform(.cycleMode)
        XCTAssertEqual(terminals.keys, [.backTab])
        XCTAssertEqual(haptics, [.rejected, .rejected])
    }

    func testSlashCommandOnlyInClaude() {
        perform(.slashCommand("/workflows"))
        XCTAssertEqual(terminals.texts.map(\.text), ["/workflows"])
        setTerminal(.idle, profile: .codex)
        perform(.slashCommand("/tasks"))
        XCTAssertEqual(terminals.texts.count, 1)
        XCTAssertEqual(haptics, [.rejected])
    }

    // MARK: Frisch fertig

    func testFreshDoneOrder() {
        let older = UUID(), newer = UUID(), working = UUID(), stale = UUID()
        let moment = Date(timeIntervalSince1970: 10_000)
        func input(_ id: UUID, _ status: AgentSessionRuntimeStatus, turn: TimeInterval) -> NotchChatInput {
            NotchChatInput(id: id, title: "", project: nil, status: status, statusSince: nil,
                           lastTurnAt: moment.addingTimeInterval(-turn), lastActivityAt: moment)
        }
        let result = ControllerIslandRows.freshDone(inputs: [
            input(older, .idle, turn: 600), input(newer, .idle, turn: 60),
            input(working, .working, turn: 30), input(stale, .idle, turn: 3_600),
        ], now: moment)
        XCTAssertEqual(result, [newer, older])
    }
}
