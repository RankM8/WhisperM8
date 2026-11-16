import Foundation
import XCTest
@testable import WhisperM8

/// WM8-91 Paket 3a: Wechsel zwischen Board und Board-Chat am Controller.
///
/// Entschieden am 16.11.2026: Rechts über den Rand in den Board-Chat, Stick ◀
/// zurück aufs Ticket (das Steuerkreuz bleibt Pfeiltasten, nur im leeren
/// Claude-Feld führt auch es zurück). Im Board-Chat die gewohnten Tasten mit
/// der Ankunftssperre von 1 s an seiner Kennung; L1/R1 blättern Tickets.
/// Giuliano: „Das muss auf jeden Fall perfekt funktionieren.“ Kein Weg darf
/// Kreuz oder Kreis ohne Sperre in einen Chat bringen, den er nicht ansieht.
@MainActor
final class ControllerBoardChatFocusTests: XCTestCase {
    // MARK: - Belegung, pur

    private static let boardChatID = UUID()

    private static func place(_ view: ControllerTicketView = .board, boardChat: Bool = true) -> ControllerTicketsPlace {
        var place = ControllerTicketsPlace(projectID: UUID(), team: "WM8")
        place.view = view
        place.hasTicket = true
        place.boardChatID = boardChat ? boardChatID : nil
        place.boardChatName = boardChat ? "Jarvis" : nil
        return place
    }

    private static func inBoardChat(_ chat: ControllerChatState, view: ControllerTicketView = .board) -> ControllerContext {
        var state = ControllerTicketState(place: place(view), area: .content, backTarget: nil)
        state.boardChat = chat
        return .tickets(state)
    }

    private static let idleClaude = ControllerChatState(status: .idle, profile: .claude)
    private static let claudeWithText = ControllerChatState(
        status: .idle, profile: .claude, draftSuspected: true, fieldMayHaveText: true)

    private func action(_ gesture: ControllerGesture, _ context: ControllerContext) -> ControllerAction? {
        ControllerBindingResolver.action(for: gesture, in: context)
    }

    func testChatKeysWorkOnTheBoardChat() {
        let context = Self.inBoardChat(Self.claudeWithText)
        XCTAssertEqual(action(.press(.cross), context), .chatKey(.enter))
        XCTAssertEqual(action(.tap(.circle), context), .chatKey(.escape))
        XCTAssertEqual(action(.tap(.square), context), .chatKey(.backspace))
        XCTAssertEqual(action(.press(.triangle), context), .chatKey(.space))
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), context), .chatKey(.up))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: false), context), .chatKey(.down))
        XCTAssertEqual(action(.move(.right, source: .dpad, isRepeat: false), context), .chatKey(.right))
        XCTAssertEqual(action(.scroll(lines: 3), context), .scroll(lines: 3))
        XCTAssertEqual(action(.holdBegan(.r3), context), .chatClearInput)
    }

    /// E2: L1/R1 blättern Tickets, auch im Board-Chat — kein Chatwechsel.
    func testBumpersStepTicketsNotChats() {
        let context = Self.inBoardChat(Self.idleClaude)
        XCTAssertEqual(action(.tap(.l1), context), .ticket(.adjacent(-1)))
        XCTAssertEqual(action(.tap(.r1), context), .ticket(.adjacent(1)))
    }

    /// Entscheidung 16.11.2026: Stick ◀ zurück aufs Ticket. Steuerkreuz ◀ ist
    /// ein Pfeil, wo im Feld etwas steht oder eine Auswahl offen ist; im leeren
    /// Claude-Feld (← dort gesperrt) führt auch es zurück.
    func testLeftStickLeavesDpadLeftIsAnArrowWhereItMayBe() {
        XCTAssertEqual(action(.move(.left, source: .leftStick, isRepeat: false), Self.inBoardChat(Self.idleClaude)),
                       .ticket(.leaveBoardChat))
        XCTAssertEqual(action(.move(.left, source: .dpad, isRepeat: false), Self.inBoardChat(Self.claudeWithText)),
                       .chatKey(.left))
        XCTAssertEqual(action(.move(.left, source: .dpad, isRepeat: false), Self.inBoardChat(Self.idleClaude)),
                       .ticket(.leaveBoardChat), "leeres Claude-Feld: zurück aufs Ticket")
        XCTAssertNil(action(.move(.left, source: .dpad, isRepeat: true), Self.inBoardChat(Self.idleClaude)),
                     "gehalten nicht hinaus")
        XCTAssertNil(action(.move(.left, source: .leftStick, isRepeat: true), Self.inBoardChat(Self.idleClaude)))
        let ended = ControllerChatState(status: .ended, profile: .claude, hasTerminal: false)
        XCTAssertEqual(action(.move(.left, source: .dpad, isRepeat: false), Self.inBoardChat(ended)),
                       .ticket(.leaveBoardChat))
    }

    /// Ankunftssperre: in der ersten Sekunde tun Kreuz und Kreis nichts.
    func testArrivalLockInTheBoardChat() {
        var chat = ControllerChatState(
            status: .awaitingInput, profile: .claude, secondsSinceAwaitingBegan: 60)
        chat.secondsSinceControllerArrival = 0.2
        let context = Self.inBoardChat(chat)
        XCTAssertNil(action(.press(.cross), context))
        XCTAssertNil(action(.tap(.circle), context))
        chat.secondsSinceControllerArrival = ControllerBindingResolver.arrivalLock + 0.1
        XCTAssertEqual(action(.press(.cross), Self.inBoardChat(chat)), .chatKey(.enter))
    }

    /// Nichts aus dem Board-Chat wählt einen anderen Chat, startet einen,
    /// öffnet die Liste oder wechselt die Ansicht. Geprüft für jede Geste,
    /// mit und ohne Ebene, an einem lebenden und einem beendeten Board-Chat.
    func testNothingInTheBoardChatLeadsToAnotherChat() {
        var inputs: [ControllerLegendInput] = ControllerButton.allCases.map { .button($0) }
        inputs += [.leftStick, .rightStick, .dpad, .bumpers]
        let plain = Array(Set(inputs.flatMap(ControllerLegend.gestures(for:))))
        let gestures = plain + ControllerLayer.allCases.flatMap { layer in plain.map { ControllerGesture.inLayer(layer, $0) } }
        let ended = ControllerChatState(status: .ended, profile: .claude, hasTerminal: false)
        for chat in [Self.idleClaude, Self.claudeWithText, ended] {
            for view in [ControllerTicketView.board, .list, .triage, .chatLine] {
                let context = Self.inBoardChat(chat, view: view)
                for gesture in gestures {
                    guard let action = action(gesture, context) else { continue }
                    switch action {
                    // R2 (`dictationToggle`) ist erlaubt: Der Ausführer diktiert im
                    // Ticket-Modus ausdrücklich an den Board-Chat (Paket 3b,
                    // `testR2DictatesIntoTheBoardChatAndNeverSubmits`).
                    case .chatResume, .adjacentChat, .moveInContent, .toggleMaximize, .enterList, .listActivate,
                         .listStartRow, .listCloseRow, .pasteNewest, .bridgeKey, .sendNowOrContinue, .cycleMode,
                         .slashCommand, .dictationStopAndSubmit:
                        XCTFail("\(gesture) → \(action) in \(view)")
                    case let .ticket(command) where command == .open:
                        XCTFail("Kreuz öffnet im Board-Chat kein Ticket und keinen Chat: \(gesture)")
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Ohne Fokus im Board-Chat bleibt das Board wie in Paket 2: ▶ bewegt die
    /// Auswahl, gehalten nur innerhalb des Boards.
    func testHeldStickNeverCrossesIntoTheBoardChat() {
        let board = ControllerContext.tickets(ControllerTicketState(place: Self.place(), area: .content))
        XCTAssertEqual(action(.move(.right, source: .dpad, isRepeat: false), board), .ticket(.move(.right)))
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: true), board), .ticket(.repeatMove(.right)))
        XCTAssertEqual(action(.move(.down, source: .leftStick, isRepeat: true), board), .ticket(.move(.down)))
    }

    func testFocusIsValidOnlyForTheShownBoardChat() {
        let window = UUID()
        let focus = ControllerBoardChatFocus(windowID: window, sessionID: Self.boardChatID)
        XCTAssertTrue(focus.isValid(windowID: window, place: Self.place()))
        XCTAssertFalse(focus.isValid(windowID: UUID(), place: Self.place()), "anderes Fenster")
        XCTAssertFalse(focus.isValid(windowID: window, place: nil), "Tickets zu")
        XCTAssertFalse(focus.isValid(windowID: window, place: Self.place(boardChat: false)), "Spalte zu oder leer")
        var other = Self.place()
        other.boardChatID = UUID()
        XCTAssertFalse(focus.isValid(windowID: window, place: other), "anderer Board-Chat")
        XCTAssertTrue(BoardChatControllerFocusFrame.isShown(focus: focus, windowID: window, shownSessionID: Self.boardChatID))
        XCTAssertFalse(BoardChatControllerFocusFrame.isShown(focus: focus, windowID: window, shownSessionID: UUID()))
        XCTAssertFalse(BoardChatControllerFocusFrame.isShown(focus: nil, windowID: window, shownSessionID: Self.boardChatID))
    }

    // MARK: - Paket 3b: R2 und Dreieck

    func testR2DictatesOnlyWithAVisibleBoardChat() {
        let with = ControllerContext.tickets(ControllerTicketState(place: Self.place(), area: .content))
        let without = ControllerContext.tickets(ControllerTicketState(place: Self.place(boardChat: false), area: .content))
        XCTAssertEqual(action(.press(.r2), with), .dictationToggle)
        XCTAssertEqual(action(.press(.r2), without), .ticket(.dictationUnavailable))
        XCTAssertEqual(action(.press(.r2), Self.inBoardChat(Self.idleClaude)), .dictationToggle)
        // Auch mit der Seitenleiste im Fokus: Ziel ist der Board-Chat, nie die Zeile.
        let sidebar = ControllerContext.tickets(ControllerTicketState(place: Self.place(), area: .list))
        XCTAssertEqual(action(.press(.r2), sidebar), .dictationToggle)
        // R1 + R2 bleibt aus.
        XCTAssertEqual(action(.inLayer(.quickDraw, .press(.r2)), with), .rejected)
    }

    func testTriangleHandsTheTicketToTheBoardChat() {
        for view in [ControllerTicketView.board, .list, .triage, .chatLine] {
            let context = ControllerContext.tickets(ControllerTicketState(place: Self.place(view), area: .content))
            XCTAssertEqual(action(.press(.triangle), context), .ticket(.handOff), "\(view)")
        }
        var noTicket = Self.place()
        noTicket.hasTicket = false
        XCTAssertEqual(action(.press(.triangle), .tickets(ControllerTicketState(place: noTicket, area: .content))), .rejected)
        XCTAssertEqual(action(.press(.triangle), .tickets(ControllerTicketState(place: Self.place(boardChat: false),
                                                                                area: .content))), .rejected)
        // Im Board-Chat selbst bleibt Dreieck das Leerzeichen.
        XCTAssertEqual(action(.press(.triangle), Self.inBoardChat(Self.idleClaude)), .chatKey(.space))
    }

    // MARK: - Leiste

    func testLegendShowsTheBoardChatKeys() {
        let labels = ControllerLegend.entries(for: Self.inBoardChat(Self.claudeWithText)).map(\.label)
        XCTAssertTrue(labels.contains(.leaveBoardChat), "\(labels)")
        XCTAssertTrue(labels.contains(.send))
        XCTAssertTrue(labels.contains(.arrows))
        XCTAssertTrue(labels.contains(.ticketPreviousNext))
        XCTAssertFalse(labels.contains(.previousNextChat))
        XCTAssertFalse(labels.contains(.startChat))
        XCTAssertFalse(labels.contains(.ticketSelection))
        // Auch gleich nach der Ankunft (Sperre) nennt die Leiste Kreuz.
        var arriving = Self.claudeWithText
        arriving.secondsSinceControllerArrival = 0.1
        XCTAssertTrue(ControllerLegend.entries(for: Self.inBoardChat(arriving)).map(\.label).contains(.send))
    }

    func testBoardLegendNamesTheWayIntoTheBoardChatOnlyWhenOneIsShown() {
        let with = ControllerLegend.entries(
            for: .tickets(ControllerTicketState(place: Self.place(), area: .content)))
        XCTAssertEqual(with.first { $0.label == .intoBoardChat }?.name, "Jarvis")
        XCTAssertEqual(with.first { $0.label == .handOffToBoardChat }?.title, "→ Jarvis")
        XCTAssertTrue(with.contains { $0.label == .dictate })
        let without = ControllerLegend.entries(
            for: .tickets(ControllerTicketState(place: Self.place(boardChat: false), area: .content)))
        XCTAssertFalse(without.contains { $0.label == .intoBoardChat })
        XCTAssertFalse(without.contains { $0.label == .handOffToBoardChat })
        XCTAssertFalse(without.contains { $0.label == .dictate })
        let inChat = ControllerLegend.entries(for: Self.inBoardChat(Self.idleClaude)).map(\.label)
        XCTAssertTrue(inChat.contains(.dictate))
    }

    // MARK: - Ablauf durch Erkenner, Belegung und Ausführer

    private var window = ControllerWindowFake()
    private var center = AgentChatsCommandCenter(keyWindowID: { nil })
    private var terminals = ControllerTerminalSpy()
    private var dictation = ControllerDictationSpy()
    private var island = ControllerIslandSpy()
    private var environment = ControllerEnvironmentSpy()
    private var ui = ControllerUIModel()
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var recognizer = ControllerGestureRecognizer()
    /// Chat hinter den Tickets, mit offener Freigabe: Dort darf nie etwas ankommen.
    private var hidden = UUID()
    private var clock: TimeInterval = 0
    private var nowValue = Date(timeIntervalSince1970: 1_000)

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        dictation = ControllerDictationSpy()
        island = ControllerIslandSpy()
        environment = ControllerEnvironmentSpy()
        ui = ControllerUIModel()
        haptics = []
        recognizer = ControllerGestureRecognizer()
        clock = 0
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation, environment: environment,
            ui: ui, island: island, now: { [unowned self] in nowValue })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        dispatcher.togglePause = {}
        dispatcher.titleForSession = { _ in "Vic" }
        dispatcher.islandStatus = { _ in .idle }
        hidden = UUID()
        window.selected = hidden
        window.rows = [AgentChatsListRow(row: .chat(hidden))]
        for id in [hidden, Self.boardChatID] {
            terminals.states[id] = ControllerTerminalState(
                isRunning: true, profile: .claude, status: .awaitingInput,
                statusSince: nowValue.addingTimeInterval(-60), draftSuspected: false, lastEnterAt: nil, lastEscapeAt: nil)
        }
        window.tickets = Self.place()
    }

    private var context: ControllerContext { ControllerContextResolver.context(for: dispatcher.snapshot()) }

    private func run(_ gestures: [ControllerGesture]) {
        for gesture in gestures {
            let current = context
            guard let action = ControllerBindingResolver.action(for: gesture, in: current) else { continue }
            dispatcher.perform(action, in: current)
        }
    }

    private func feed(_ event: ControllerInputEvent) {
        clock += 0.05
        run(recognizer.handle(event, at: clock))
    }

    private func tap(_ button: ControllerButton) {
        feed(button.isTrigger ? .trigger(button, value: 1) : .button(button, pressed: true))
        feed(button.isTrigger ? .trigger(button, value: 0) : .button(button, pressed: false))
    }

    private func stickLeft() {
        feed(.stick(.left, x: -1, y: 0))
        feed(.stick(.left, x: 0, y: 0))
    }

    private func afterArrivalLock() {
        nowValue = nowValue.addingTimeInterval(ControllerBindingResolver.arrivalLock + 0.1)
    }

    /// ▶ am rechten Rand: das Board meldet den Rand.
    private func enterFromTheRightEdge() {
        window.ticketOutcome = .rightEdge
        tap(.dpadRight)
        window.ticketOutcome = .done
    }

    func testRightEdgeEntersTheBoardChatAndCrossWaitsForTheLock() {
        enterFromTheRightEdge()
        XCTAssertEqual(ui.boardChatFocus, ControllerBoardChatFocus(windowID: window.id, sessionID: Self.boardChatID))
        guard case let .tickets(state) = context, state.boardChat != nil else { return XCTFail("\(context)") }
        // Reflex-Doppeldruck gleich nach dem Sprung: nichts geht hinein.
        tap(.cross)
        tap(.cross)
        tap(.circle)
        XCTAssertTrue(terminals.keys.isEmpty, "\(terminals.keys)")
        afterArrivalLock()
        tap(.cross)
        XCTAssertEqual(terminals.keys, [.enter])
        XCTAssertEqual(terminals.keyTargets, [Self.boardChatID], "nur an den Board-Chat")
    }

    /// Jede Taste im Board-Chat geht an ihn, keine an den Chat hinter den Tickets.
    func testKeysNeverReachTheHiddenChat() {
        enterFromTheRightEdge()
        afterArrivalLock()
        for button in [ControllerButton.cross, .circle, .square, .triangle, .dpadUp, .dpadDown, .dpadRight] {
            tap(button)
        }
        feed(.stick(.right, x: 0, y: 1))
        feed(.stick(.right, x: 0, y: 0))
        XCTAssertFalse(terminals.keys.isEmpty)
        XCTAssertFalse(terminals.keyTargets.contains(hidden), "Taste am verdeckten Chat: \(terminals.keys)")
        XCTAssertTrue(terminals.keyTargets.allSatisfy { $0 == Self.boardChatID })
        XCTAssertFalse(terminals.scrolledTargets.contains(hidden))
        XCTAssertTrue(dictation.started.isEmpty)
    }

    func testStickLeftGoesBackToTheTicket() {
        enterFromTheRightEdge()
        stickLeft()
        XCTAssertNil(ui.boardChatFocus)
        guard case let .tickets(state) = context else { return XCTFail("\(context)") }
        XCTAssertNil(state.boardChat)
        afterArrivalLock()
        tap(.cross)
        XCTAssertTrue(terminals.keys.isEmpty, "Kreuz gehört wieder dem Board")
    }

    func testWithoutABoardChatTheRightEdgeIsRejected() {
        window.tickets = Self.place(boardChat: false)
        enterFromTheRightEdge()
        XCTAssertNil(ui.boardChatFocus)
        XCTAssertEqual(haptics.last, .rejected)
    }

    /// Zeigt die Spalte einen anderen Chat, gilt der Fokus nicht mehr: Kreuz
    /// geht nicht ohne neue Ankunft in den neuen Chat.
    func testAnotherBoardChatEndsTheFocus() {
        enterFromTheRightEdge()
        afterArrivalLock()
        let other = UUID()
        terminals.states[other] = terminals.states[Self.boardChatID]
        var place = Self.place()
        place.boardChatID = other
        window.tickets = place
        tap(.cross)
        XCTAssertTrue(terminals.keys.isEmpty, "\(terminals.keys)")
        XCTAssertNil(ui.boardChatFocus)
    }

    /// Tickets zu und wieder auf: Der Fokus lebt nicht wieder auf.
    func testLeavingTheTicketsEndsTheFocus() {
        enterFromTheRightEdge()
        afterArrivalLock()
        window.tickets = nil
        window.backTarget = nil
        // Irgendeine Eingabe danach räumt den Fokus ab.
        dispatcher.perform(.rejected, in: context)
        XCTAssertNil(ui.boardChatFocus)
        window.tickets = Self.place()
        guard case let .tickets(state) = context else { return XCTFail("\(context)") }
        XCTAssertNil(state.boardChat)
    }

    func testControllerUIClosingEndsTheFocus() {
        enterFromTheRightEdge()
        dispatcher.closeControllerUI()
        XCTAssertNil(ui.boardChatFocus)
    }

    /// Paket 3b: R2 diktiert an den Board-Chat der Spalte, nie an den Chat
    /// dahinter, und Kreuz beim Stoppen sendet nicht.
    func testR2DictatesIntoTheBoardChatAndNeverSubmits() {
        tap(.r2)
        XCTAssertEqual(dictation.started, [.boardChat(sessionID: Self.boardChatID)])
        XCTAssertEqual(dictation.labels, ["Vic"])
        tap(.cross)
        tap(.r2)
        XCTAssertFalse(dictation.stopped.contains(true), "nie mit Senden: \(dictation.stopped)")
        XCTAssertTrue(terminals.keys.isEmpty, "\(terminals.keys)")
    }

    func testR2WithoutBoardChatDoesNotDictate() {
        window.tickets = Self.place(boardChat: false)
        tap(.r2)
        XCTAssertTrue(dictation.started.isEmpty)
        XCTAssertEqual(haptics.last, .rejected)
        XCTAssertEqual(ui.ticketNotice, .dictationNeedsBoardChat)
    }

    func testTriangleSendsTheHandOffToTheBoard() {
        tap(.triangle)
        XCTAssertEqual(window.ticketCommands.last, .handOff)
        XCTAssertEqual(ui.ticketNotice, .handedOff)
        XCTAssertTrue(terminals.keys.isEmpty, "kein Enter, keine Taste")
        window.ticketOutcome = .rejected
        tap(.triangle)
        XCTAssertEqual(haptics.last, .rejected)
    }

    /// Paket 3c: ⌘K öffnet die Menü-Karte am Ticket, bedient per Tastatur;
    /// im Board-Chat und bei offenem Menü nicht.
    func testCommandKOpensTheTicketMenuForTheKeyboard() {
        window.ticketMenu = ControllerTicketMenuInfo(key: "WM8-12", hasURL: true)
        XCTAssertTrue(dispatcher.openKeyboardTicketMenu())
        XCTAssertNotNil(ui.menu)
        XCTAssertTrue(ui.menuByKeyboard)
        XCTAssertTrue(dispatcher.isKeyboardMenuOpen)
        XCTAssertFalse(dispatcher.openKeyboardTicketMenu(), "schon offen")
        ui.menu = nil
        enterFromTheRightEdge()
        XCTAssertFalse(dispatcher.openKeyboardTicketMenu(), "nicht aus dem Board-Chat")
        XCTAssertTrue(terminals.keys.isEmpty)
    }

    /// Hinter den Tickets ohne Fokus im Board-Chat gibt es kein Ziel für Tasten.
    func testNoInputTargetBehindTheTicketsWithoutFocus() {
        XCTAssertNil(dispatcher.chatInputSessionID)
        enterFromTheRightEdge()
        XCTAssertEqual(dispatcher.chatInputSessionID, Self.boardChatID)
        window.tickets = nil
        XCTAssertEqual(dispatcher.chatInputSessionID, hidden, "ohne Tickets wieder der sichtbare Chat")
    }
}
