import Foundation
import XCTest
@testable import WhisperM8

/// Ticket-Modus am Controller (WM8-91): Hinter den Tickets kommt in keinem
/// Chat etwas an — kein Enter, kein Escape, keine Taste, kein Diktat. Geprüft
/// für jede Geste aus der Belegung, mit und ohne Ebene, und dazu im Ablauf
/// durch Erkenner, Belegung und Ausführer.
@MainActor
final class ControllerTicketsSafetyTests: XCTestCase {
    // MARK: - Belegung, pur

    private static let place = ControllerTicketsPlace(projectID: UUID(), team: "WM8")

    private static var contexts: [ControllerContext] {
        let back = ControllerBackTarget(kind: .chat, title: "Jarvis", id: UUID())
        return [
            .tickets(ControllerTicketState(place: place, area: .content, backTarget: back)),
            .tickets(ControllerTicketState(place: place, area: .content, backTarget: nil)),
            .tickets(ControllerTicketState(place: place, area: .list, backTarget: back)),
        ]
    }

    /// Jede Geste, die der Erkenner liefern kann: alle Tasten, Sticks,
    /// Steuerkreuz, L1 + R1, dazu in jeder Ebene.
    private static var allGestures: [ControllerGesture] {
        var inputs: [ControllerLegendInput] = ControllerButton.allCases.map { .button($0) }
        inputs += [.leftStick, .rightStick, .dpad, .bumpers]
        let plain = Array(Set(inputs.flatMap(ControllerLegend.gestures(for:))))
        let layered = ControllerLayer.allCases.flatMap { layer in plain.map { ControllerGesture.inLayer(layer, $0) } }
        return plain + layered
    }

    /// Aktionen, die einen Chat treffen: in sein Terminal schreiben, ihn
    /// scrollen, in ihn diktieren oder per Tastatur-Brücke Return/Escape an
    /// das Feld mit dem Fokus schicken.
    private static func reachesChat(_ action: ControllerAction) -> Bool {
        switch action {
        case .dictationToggle, .dictationStopAndSubmit, .chatKey, .chatInterrupt, .chatResume, .chatClearInput,
             .pasteNewest, .moveInContent, .toggleMaximize, .scroll, .scrollPage, .scrollToBottom,
             .sendNowOrContinue, .cycleMode, .slashCommand, .bridgeKey:
            return true
        case let .quickDraw(item):
            return item.writesToChat || item == .switchAccount
        default:
            return false
        }
    }

    func testNoGestureReachesAChatBehindTheTickets() {
        for context in Self.contexts {
            for gesture in Self.allGestures {
                guard let action = ControllerBindingResolver.action(for: gesture, in: context) else { continue }
                XCTAssertFalse(Self.reachesChat(action), "\(gesture) → \(action) in \(context)")
            }
        }
    }

    /// Paddles in jeder Belegung: Eingaben in einen Chat gehen nicht, nur
    /// Sprünge, die das Board sichtbar verlassen.
    func testNoPaddleReachesAChatBehindTheTickets() {
        let paddles: [ControllerButton] = [.paddleUpperLeft, .paddleLowerLeft, .paddleUpperRight, .paddleLowerRight]
        for binding in ControllerPaddleBinding.allCases {
            let bindings = ControllerPaddleBindings(
                upperLeft: binding, lowerLeft: binding, upperRight: binding, lowerRight: binding)
            for context in Self.contexts {
                for paddle in paddles {
                    for gesture in ControllerLegend.gestures(for: .button(paddle)) {
                        guard let action = ControllerBindingResolver.action(
                            for: gesture, in: context, paddles: bindings) else { continue }
                        XCTAssertFalse(Self.reachesChat(action), "\(binding) \(gesture) → \(action)")
                    }
                }
            }
        }
    }

    /// Die Tasten, die im Chat senden, bestätigen, abbrechen oder diktieren,
    /// einzeln benannt: Im Ticket-Modus tun sie nichts am Chat.
    func testChatKeysDoNothingToAChat() {
        let context = Self.contexts[0]
        let chatState = ControllerChatState(
            status: .idle, profile: .claude, draftSuspected: true, fieldMayHaveText: true)
        let cases: [(ControllerGesture, String)] = [
            (.press(.cross), "Kreuz: Enter"),
            (.tap(.circle), "Kreis: Escape"),
            (.tap(.square), "Viereck: Rücktaste"),
            (.press(.triangle), "Dreieck: Leerzeichen"),
            (.press(.r2), "R2: Diktat"),
            (.holdBegan(.r3), "R3 halten: Eingabe leeren"),
            (.move(.up, source: .dpad, isRepeat: false), "Steuerkreuz: Pfeil"),
            (.move(.right, source: .dpad, isRepeat: false), "Steuerkreuz rechts: Vorschlag annehmen"),
            (.scroll(lines: 3), "rechter Stick: scrollen"),
            (.inLayer(.writing, .press(.cross)), "L1 + Kreuz: einfügen"),
            (.inLayer(.writing, .press(.circle)), "L1 + Kreis: ein Escape"),
            (.inLayer(.quickDraw, .press(.cross)), "R1 + Kreuz: Jetzt senden"),
            (.inLayer(.quickDraw, .press(.triangle)), "R1 + Dreieck: Modus"),
            (.inLayer(.quickDraw, .press(.square)), "R1 + Viereck: Befehle"),
            (.inLayer(.quickDraw, .press(.l3)), "R1 + L3: Transkript"),
        ]
        for (gesture, name) in cases {
            let inChat = ControllerBindingResolver.action(for: gesture, in: .chat(chatState))
            let inTickets = ControllerBindingResolver.action(for: gesture, in: context)
            XCTAssertNotNil(inChat, "\(name) wirkt im Chat (sonst prüft der Test nichts)")
            XCTAssertFalse(inTickets.map(Self.reachesChat) ?? false, "\(name) → \(String(describing: inTickets))")
        }
    }

    func testPackageOneBindings() {
        let context = Self.contexts[0]
        func action(_ gesture: ControllerGesture) -> ControllerAction? {
            ControllerBindingResolver.action(for: gesture, in: context)
        }
        XCTAssertEqual(action(.tap(.l2)), .lastChat, "L2 getippt: zurück")
        XCTAssertEqual(action(.layerBegan(.whereTo)), .islandShow(.whereTo), "L2 halten: Wohin")
        XCTAssertEqual(action(.layerEnded(.whereTo)), .islandRelease)
        XCTAssertEqual(action(.inLayer(.whereTo, .move(.right, source: .dpad, isRepeat: false))), .islandTab(step: 1))
        XCTAssertEqual(action(.layerBegan(.quickDraw)), .islandShow(.quickDraw), "R1 halten: App-Raute")
        XCTAssertEqual(action(.inLayer(.quickDraw, .move(.right, source: .dpad, isRepeat: false))),
                       .appSlot(.stayAwake), "App-Raute bleibt, wie sie ist")
        XCTAssertNil(action(.layerBegan(.writing)), "L1 „Schreiben“ gibt es erst mit dem Board-Chat")
        XCTAssertEqual(action(.press(.r2)), .rejected, "E4: R2 tut nichts, mit Rückmeldung")
        XCTAssertEqual(action(.inLayer(.whereTo, .press(.r2))), .islandCommitAndDictate,
                       "L2 + R2: der Ausführer lehnt ab, solange das Ziel kein Chat ist")
        XCTAssertEqual(action(.press(.options)), .menuToggle)
        XCTAssertEqual(action(.press(.create)), .newChat)
        XCTAssertEqual(action(.press(.touchpad)), .clipboardToggle)
        XCTAssertEqual(action(.chordCompleted), .pauseToggle)
    }

    // MARK: - Ablauf durch Erkenner, Belegung und Ausführer

    private var window: ControllerWindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: ControllerTerminalSpy!
    private var dictation: ControllerDictationSpy!
    private var island: ControllerIslandSpy!
    private var environment: ControllerEnvironmentSpy!
    private var ui: ControllerUIModel!
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var recognizer = ControllerGestureRecognizer()
    private var chat = UUID()
    private var clock: TimeInterval = 0

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
            ui: ui, island: island, now: { Date(timeIntervalSince1970: 1_000) })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        dispatcher.togglePause = {}
        dispatcher.titleForSession = { _ in "Jarvis" }
        dispatcher.islandStatus = { _ in .idle }
        dispatcher.islandChatRows = { order, current in
            order.map { ControllerIslandChatRow(
                id: $0, title: "Chat", project: "WhisperM8", status: .idle, detail: "", isCurrent: $0 == current) }
        }
        chat = UUID()
        window.selected = chat
        window.rows = [AgentChatsListRow(row: .chat(chat))]
        // Ein Chat, der auf eine Freigabe wartet: genau dort wäre ein Enter fatal.
        terminals.states[chat] = ControllerTerminalState(
            isRunning: true, profile: .claude, status: .awaitingInput, statusSince: nil,
            draftSuspected: true, lastEnterAt: nil, lastEscapeAt: nil)
        window.tickets = Self.place
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

    private func tick(_ seconds: TimeInterval) {
        clock += seconds
        run(recognizer.tick(at: clock))
    }

    private func press(_ button: ControllerButton) {
        feed(button.isTrigger ? .trigger(button, value: 1) : .button(button, pressed: true))
    }

    private func release(_ button: ControllerButton) {
        feed(button.isTrigger ? .trigger(button, value: 0) : .button(button, pressed: false))
    }

    private func tap(_ button: ControllerButton) {
        press(button)
        release(button)
    }

    private func hold(_ button: ControllerButton) {
        press(button)
        tick(1.5)
        release(button)
    }

    private func assertNothingReachedTheChat(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(terminals.keys.isEmpty, "Tasten: \(terminals.keys) – \(message)", file: file, line: line)
        XCTAssertTrue(terminals.texts.isEmpty, "Text – \(message)", file: file, line: line)
        XCTAssertTrue(terminals.clearedSessions.isEmpty, "geleert – \(message)", file: file, line: line)
        XCTAssertTrue(terminals.scrolled.isEmpty && terminals.pages.isEmpty, "gescrollt – \(message)", file: file, line: line)
        XCTAssertTrue(dictation.started.isEmpty, "Diktat – \(message)", file: file, line: line)
        XCTAssertTrue(environment.bridgeKeys.isEmpty, "Brücke – \(message)", file: file, line: line)
    }

    func testContextIsTicketsWhileTheBoardIsShown() {
        guard case let .tickets(state) = context else { return XCTFail("\(context)") }
        XCTAssertEqual(state.place.team, "WM8")
        window.tickets = nil
        guard case .chat = context else { return XCTFail("ohne Tickets wieder der Chat") }
    }

    /// Jede Taste getippt, gedrückt und gehalten, dazu Sticks, Steuerkreuz
    /// und die Ebenen: Am wartenden Chat hinter den Tickets kommt nichts an.
    func testEveryButtonLeavesTheHiddenChatAlone() {
        let buttons: [ControllerButton] = [
            .cross, .circle, .square, .triangle, .r2, .r3, .l3, .options, .create, .touchpad,
            .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
        ]
        // Create öffnet sichtbar die Projekt-Auswahl „Neuer Chat“; die gehört
        // danach weg, sonst gingen die Pfeile zu Recht dorthin.
        func closeOverlays() {
            ui.menu = nil
            window.isNewChatPickerOpen = false
        }
        for button in buttons {
            tap(button)
            closeOverlays()
            hold(button)
            closeOverlays()
            assertNothingReachedTheChat("\(button)")
        }
        for side in [ControllerStickSide.left, .right] {
            feed(.stick(side, x: 0, y: 1))
            tick(0.6)
            feed(.stick(side, x: 0, y: 0))
            feed(.stick(side, x: 1, y: 0))
            feed(.stick(side, x: 0, y: 0))
        }
        assertNothingReachedTheChat("Sticks")
        // Unter jeder Ebene die Gesichtstasten.
        for layerKey in [ControllerButton.l1, .r1] {
            for button in [ControllerButton.cross, .circle, .square, .triangle, .r2, .l3] {
                press(layerKey)
                tick(0.4)
                tap(button)
                release(layerKey)
                closeOverlays()
            }
        }
        assertNothingReachedTheChat("Ebenen")
        XCTAssertNotNil(window.tickets, "keine dieser Tasten verlässt das Board über einen Chat-Befehl")
    }

    func testR2RejectsWithoutDictating() {
        tap(.r2)
        XCTAssertTrue(dictation.started.isEmpty)
        XCTAssertEqual(haptics.last, .rejected)
    }

    func testR1ShowsOnlyTheAppDiamond() {
        press(.r1)
        tick(0.4)
        guard case let .quickDraw(slots)? = island.last?.content else { return XCTFail("keine Raute") }
        XCTAssertTrue(slots.enabled.isEmpty, "Chat-Raute aus")
        XCTAssertEqual(slots.note, .noBoardChat)
        XCTAssertEqual(island.last?.target.title, "Tickets · WM8")
        tap(.cross)
        release(.r1)
        assertNothingReachedTheChat("R1 + Kreuz")
    }

    /// L2 + R2 auf dem Board, in dem man ist: Es gibt keinen Chat, in den
    /// „hier“ diktiert würde.
    func testWhereToDictateInTheBoardIsRejected() {
        window.ticketBoards = ControllerTicketBoards(
            rows: [board(team: "WM8", here: true, current: true)], inTickets: true)
        press(.l2)
        tick(0.4)
        XCTAssertEqual(island.last?.whereTo?.tab, .tickets)
        tap(.r2)
        release(.l2)
        assertNothingReachedTheChat("L2 + R2")
        XCTAssertEqual(haptics.last, .rejected)
    }

    private func board(team: String, here: Bool = false, current: Bool = false, id: UUID = UUID()) -> ControllerTicketBoardChoice {
        ControllerTicketBoardChoice(
            id: id, team: team, projectName: team.lowercased(), colorHex: "#5e6ad2",
            waitingCount: nil, isHere: here, isCurrent: current)
    }
}
