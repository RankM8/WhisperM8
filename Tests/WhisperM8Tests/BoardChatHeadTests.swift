import Foundation
import XCTest
@testable import WhisperM8

/// WM8-126: Kopf der Board-Chat-Spalte mit Controller und Tastatur
/// (Entscheidung Giuliano 16.11.2026: „Kopfzeile verlängern“). ▶ am rechten
/// Ende einer Kopfzeile des Boards führt in den Kopf der Spalte; ◀ zurück,
/// ▼ in den Board-Chat. Kreuz wechselt den Chat, holt einen anderen hinein,
/// öffnet ihn als Tab oder blendet die Spalte aus. Nie geht dabei etwas in
/// einen Chat.
@MainActor
final class BoardChatHeadTests: XCTestCase {
    private let project = UUID()
    private let jarvis = UUID()
    private let product = UUID()

    private func choice(_ id: UUID, _ name: String, _ kind: BoardChatChoice.Kind, selected: Bool) -> BoardChatChoice {
        BoardChatChoice(id: id, name: name, title: name, kind: kind, isSelected: selected)
    }

    private var vic: BoardChatHeadOption {
        BoardChatHeadOption(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!, name: "Vic",
                            title: "Vic · Prüfer (Beispiel)", isRunning: true)
    }

    private func layout(current: UUID? = nil, others: [BoardChatHeadOption] = [], canOpenAsTab: Bool = true,
                        collapsed: Bool = false) -> BoardChatHeadLayout {
        let current = current ?? jarvis
        return .make(choices: [choice(jarvis, "Jarvis", .jarvis, selected: current == jarvis),
                               choice(product, "Pia", .product, selected: current == product)],
                     others: others, canOpenAsTab: canOpenAsTab, isCollapsed: collapsed)
    }

    // MARK: - Pur

    func testLayoutFollowsTheHead() {
        XCTAssertEqual(layout().items, [.choice(jarvis), .choice(product), .otherChat, .openAsTab, .hide])
        XCTAssertEqual(layout().current, jarvis)
        XCTAssertEqual(layout(canOpenAsTab: false).items, [.choice(jarvis), .choice(product), .otherChat, .hide],
                       "„Als Tab öffnen“ nur, wenn das Terminal hier steht")
        XCTAssertEqual(layout(collapsed: true).items, [.show], "zugeklappt nur „zeigen“")
        XCTAssertEqual(BoardChatHeadLayout.make(choices: [], others: [], canOpenAsTab: false, isCollapsed: false).items,
                       [.otherChat, .hide], "ohne Jarvis: hineinholen und ausblenden")
    }

    func testEntryPrefersTheRememberedButtonThenTheChatInTheColumn() {
        XCTAssertEqual(BoardChatHeadSelection.entry(layout(current: product)), .choice(product))
        XCTAssertEqual(BoardChatHeadSelection.entry(layout(), remembering: .hide), .hide)
        XCTAssertEqual(BoardChatHeadSelection.entry(layout(canOpenAsTab: false), remembering: .openAsTab), .choice(jarvis),
                       "einen gemerkten Knopf, den es nicht mehr gibt, ersetzt der Chat in der Spalte")
        XCTAssertEqual(BoardChatHeadSelection.entry(layout(collapsed: true)), .show)
    }

    func testStepsWithoutWrapping() {
        let head = layout()
        XCTAssertEqual(BoardChatHeadSelection.step(.choice(jarvis), .left, in: head), .backToBoardHeader)
        XCTAssertEqual(BoardChatHeadSelection.step(.choice(jarvis), .right, in: head), .item(.choice(product)))
        XCTAssertEqual(BoardChatHeadSelection.step(.hide, .right, in: head), .stay)
        XCTAssertEqual(BoardChatHeadSelection.step(.otherChat, .up, in: head), .stay)
        XCTAssertEqual(BoardChatHeadSelection.step(.otherChat, .down, in: head), .down)
    }

    /// Dieselbe Regel wie beim Hineinziehen: nur echte Agent-Chats dieses
    /// Projekts, nicht archiviert, ohne den Chat, der schon dasteht.
    func testOtherChatsFollowTheDropRule() {
        let now = Date(timeIntervalSince1970: 2_000)
        func candidate(_ title: String, running: Bool = false, age: TimeInterval = 0, project: UUID? = nil,
                       archived: Bool = false, kind: AgentSessionKind = .chat) -> BoardChatCandidate {
            BoardChatCandidate(id: UUID(), title: title, projectID: project ?? self.project, isRunning: running,
                               lastActivityAt: now.addingTimeInterval(-age), isArchived: archived, kind: kind)
        }
        let current = candidate("Jarvis: Supervisor WM8", running: true)
        let old = candidate("Lou · Doku (Beispiel)", age: 600)
        let recent = candidate("Mo · Notch (Beispiel)", age: 60)
        let running = candidate("Vic · Prüfer (Beispiel)", running: true, age: 900)
        let candidates = [
            current, old, recent, running,
            candidate("zsh", kind: .terminal),
            candidate("Ari · alt (Beispiel)", archived: true),
            candidate("Bea · fremd (Beispiel)", project: UUID()),
        ]
        let others = BoardChatHeadSelection.others(candidates, projectID: project, current: current.id,
                                                   name: BoardChatText.callName)
        XCTAssertEqual(others.map(\.id), [running.id, recent.id, old.id], "laufende zuerst, dann der zuletzt aktive")
        XCTAssertEqual(others.first?.name, BoardChatText.callName(running.title))
    }

    // MARK: - Modell

    private func viewModel() -> TicketBoardViewModel {
        TicketBoardViewModel(model: TicketBoardBuilder.build(snapshot: TicketFixtures.snapshot([
            TicketFixtures.ticket(1, status: "Todo", project: "A"),
        ]), chats: [], projectPath: nil), documents: .immediate)
    }

    private func context(_ column: BoardChatHeadLayout?) -> TicketHeaderContext {
        TicketHeaderContext(hasBack: true, hasBoardChat: true, column: column)
    }

    /// ▶ am Ende der Kopfzeile: in den Kopf der Spalte; ◀ zurück auf dieselbe Stelle.
    func testRightAtTheEndOfARowEntersTheColumnAndLeftComesBack() {
        let model = viewModel()
        let ctx = context(layout())
        XCTAssertTrue(model.enterHeader(ctx))
        _ = model.headerMove(.up, ctx)
        for _ in 0..<10 { _ = model.headerMove(.right, ctx) }
        XCTAssertNil(model.headerFocus, "am Ende der Zeile weiter in die Spalte")
        XCTAssertEqual(model.columnFocus, .choice(jarvis), "auf dem Chat, der in der Spalte steht")
        XCTAssertEqual(model.controllerView(isReady: true), .boardChatHead)
        XCTAssertEqual(model.columnMove(.left, ctx, exit: .toBoard), .done)
        XCTAssertNil(model.columnFocus)
        XCTAssertEqual(model.headerItem(ctx), .refresh, "zurück auf den Knopf, von dem man kam")
    }

    func testWithoutAColumnTheRowEndStays() {
        let model = viewModel()
        let ctx = context(nil)
        XCTAssertTrue(model.enterHeader(ctx))
        for _ in 0..<12 { _ = model.headerMove(.right, ctx) }
        XCTAssertNil(model.columnFocus)
        XCTAssertNotNil(model.headerFocus)
    }

    /// Kreuz auf dem Chat, der schon dasteht, tut nichts; auf dem anderen
    /// wechselt es. In einen Chat führt Kreuz nie.
    func testCrossSwitchesButNeverEntersAChat() {
        let model = viewModel()
        let ctx = context(layout())
        XCTAssertTrue(model.enterColumn(layout(), from: nil))
        XCTAssertEqual(model.columnActivate(ctx), .done)
        _ = model.columnMove(.right, ctx, exit: .intoBoardChat)
        XCTAssertEqual(model.columnActivate(ctx), .choose(product))
        model.reconcileColumn(layout(current: product), chosen: product)
        XCTAssertEqual(model.columnFocus, .choice(product), "Ring bleibt auf dem gewählten Chat")
        XCTAssertEqual(model.columnActivate(context(layout(current: product))), .done, "zweites Kreuz: nichts")
    }

    func testOtherChatListChoosesAndCircleCloses() {
        let model = viewModel()
        let head = layout(others: [vic])
        let ctx = context(head)
        XCTAssertTrue(model.enterColumn(head, from: nil))
        model.columnFocus = .otherChat
        XCTAssertEqual(model.columnActivate(ctx), .done)
        XCTAssertEqual(model.columnPickerIndex, 0)
        XCTAssertEqual(model.controllerView(isReady: true), .boardChatHeadPicker)
        XCTAssertEqual(model.columnMove(.down, ctx, exit: .intoBoardChat), .nothing, "am Ende der Liste still, nie in den Chat")
        model.columnBack()
        XCTAssertNil(model.columnPickerIndex, "Kreis schließt die Liste ohne Wahl")
        XCTAssertEqual(model.columnFocus, .otherChat)
        XCTAssertEqual(model.columnActivate(ctx), .done)
        XCTAssertEqual(model.columnActivate(ctx), .choose(vic.id))
        XCTAssertNil(model.columnPickerIndex)
        model.columnBack()
        XCTAssertNil(model.columnFocus, "Kreis zurück auf die Karte")
        XCTAssertNil(model.headerFocus)
    }

    func testEmptyOtherChatListIsRejected() {
        let model = viewModel()
        XCTAssertTrue(model.enterColumn(layout(), from: nil))
        model.columnFocus = .otherChat
        XCTAssertEqual(model.columnActivate(context(layout())), .rejected)
        XCTAssertNil(model.columnPickerIndex)
    }

    /// ▼ führt nur in den Board-Chat, wenn das Fenster ihn sichtbar meldet;
    /// sonst zurück aufs Board.
    func testDownEntersTheBoardChatOnlyWhenItIsShown() {
        let model = viewModel()
        XCTAssertTrue(model.enterColumn(layout(), from: nil))
        XCTAssertEqual(model.columnMove(.down, context(layout()), exit: .intoBoardChat), .rightEdge)
        XCTAssertNil(model.columnFocus)
        XCTAssertTrue(model.enterColumn(layout(), from: nil))
        XCTAssertEqual(model.columnMove(.down, context(layout()), exit: .toBoard), .done)
        XCTAssertNil(model.columnFocus)
        XCTAssertNil(model.headerFocus)
    }

    func testHideMovesTheRingToShow() {
        let model = viewModel()
        XCTAssertTrue(model.enterColumn(layout(), from: nil))
        model.columnFocus = .hide
        XCTAssertEqual(model.columnActivate(context(layout())), .hide)
        model.reconcileColumn(layout(collapsed: true))
        XCTAssertEqual(model.columnFocus, .show)
        XCTAssertEqual(model.columnActivate(context(layout(collapsed: true))), .show)
    }

    /// Ein Mausklick räumt Ring und Liste der Spalte; die Maus öffnet die Liste.
    func testMouseClearsAndOpensTheList() {
        let model = viewModel()
        XCTAssertTrue(model.enterColumn(layout(others: [vic]), from: nil))
        model.columnPickerIndex = 0
        TicketBoardControllers.leaveHeaders([model])
        XCTAssertNil(model.columnFocus)
        XCTAssertNil(model.columnPickerIndex)
        model.openOtherChatsByMouse(hasOptions: true)
        XCTAssertEqual(model.columnFocus, .otherChat)
        XCTAssertEqual(model.columnPickerIndex, 0)
        model.openOtherChatsByMouse(hasOptions: true)
        XCTAssertEqual(model.columnPickerIndex, 0, "kein Umschalten: der Klick daneben räumt")
        model.leaveHeader()
        model.openOtherChatsByMouse(hasOptions: false)
        XCTAssertNil(model.columnPickerIndex, "ohne passenden Chat keine leere Liste")
    }

    // MARK: - Belegung

    private func head(_ view: ControllerTicketView, boardChat: Bool = true) -> ControllerContext {
        var place = ControllerTicketsPlace(projectID: UUID(), team: "WM8")
        place.view = view
        place.hasTicket = true
        place.boardChatID = boardChat ? UUID() : nil
        place.boardChatName = boardChat ? "Jarvis" : nil
        return .tickets(ControllerTicketState(place: place, area: .content))
    }

    private func action(_ gesture: ControllerGesture, _ context: ControllerContext) -> ControllerAction? {
        ControllerBindingResolver.action(for: gesture, in: context)
    }

    func testBindingsInTheColumnHead() {
        let context = head(.boardChatHead)
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: false), context), .ticket(.move(.right)))
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: false), context), .ticket(.move(.down)))
        XCTAssertEqual(action(.move(.down, source: .leftStick, isRepeat: true), context), .ticket(.repeatMove(.down)),
                       "gehalten nie hinunter in den Chat")
        XCTAssertEqual(action(.press(.cross), context), .ticket(.open))
        XCTAssertEqual(action(.tap(.circle), context), .ticket(.back))
        XCTAssertEqual(action(.tap(.l1), context), .ticket(.adjacent(-1)))
        let picker = head(.boardChatHeadPicker)
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: false), picker), .ticket(.move(.down)))
        XCTAssertNil(action(.move(.left, source: .dpad, isRepeat: false), picker))
        XCTAssertEqual(action(.press(.cross), picker), .ticket(.open))
        XCTAssertEqual(action(.tap(.circle), picker), .ticket(.back))
    }

    /// Gehalten ▶ im Kopf des Boards rutscht nicht in den Kopf der Spalte.
    func testHeldRightInTheBoardHeaderStaysThere() {
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: true), head(.header)), .ticket(.repeatMove(.right)))
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: false), head(.header)), .ticket(.move(.right)))
    }

    func testLegendInTheColumnHead() {
        let entries = ControllerLegend.entries(for: head(.boardChatHead))
        XCTAssertEqual(Array(entries.map(\.label).prefix(4)), [.move, .select, .back, .intoBoardChat])
        XCTAssertEqual(entries.first { $0.label == .intoBoardChat }?.name, "Jarvis")
        XCTAssertFalse(ControllerLegend.entries(for: head(.boardChatHead, boardChat: false)).map(\.label)
            .contains(.intoBoardChat), "▼ in den Chat nur, wenn die Spalte einen zeigt")
        XCTAssertEqual(ControllerLegend.entries(for: head(.boardChatHeadPicker)).map(\.label), [.move, .select, .close])
        XCTAssertEqual(KeyboardLegend.ticketItems(for: head(.boardChatHead)).map(\.keys),
                       [["↑", "↓", "←", "→"], ["↩"], ["esc"]])
        XCTAssertEqual(KeyboardLegend.ticketItems(for: head(.boardChatHeadPicker)).map(\.keys), [["↑", "↓"], ["↩"], ["esc"]])
    }
}

/// Ablauf durch Erkenner, Belegung und Ausführer: Ein Wechsel des Board-Chats
/// schickt nie etwas, auch nicht auf einen Chat mit offener Freigabe und auch
/// nicht bei Kreuz, Kreuz direkt danach. Hinein geht es nur mit ▼, mit Sperre.
@MainActor
final class BoardChatHeadFlowTests: XCTestCase {
    private var window = ControllerWindowFake()
    private var center = AgentChatsCommandCenter(keyWindowID: { nil })
    private var terminals = ControllerTerminalSpy()
    private var ui = ControllerUIModel()
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var recognizer = ControllerGestureRecognizer()
    private var clock: TimeInterval = 0
    private var nowValue = Date(timeIntervalSince1970: 1_000)
    private let jarvis = UUID()
    /// Produkt-Chat mit einer Freigabe, die seit einer Minute offen ist.
    private let product = UUID()
    private let hidden = UUID()

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        ui = ControllerUIModel()
        haptics = []
        recognizer = ControllerGestureRecognizer()
        clock = 0
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: ControllerDictationSpy(),
            environment: ControllerEnvironmentSpy(), ui: ui, island: ControllerIslandSpy(),
            now: { [unowned self] in nowValue })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        dispatcher.togglePause = {}
        dispatcher.titleForSession = { _ in "Pia" }
        dispatcher.islandStatus = { _ in .idle }
        window.selected = hidden
        for id in [hidden, jarvis, product] {
            terminals.states[id] = ControllerTerminalState(
                isRunning: true, profile: .claude, status: .awaitingInput,
                statusSince: nowValue.addingTimeInterval(-60), draftSuspected: false, lastEnterAt: nil, lastEscapeAt: nil)
        }
        window.tickets = place(.boardChatHead, shown: jarvis)
    }

    private func place(_ view: ControllerTicketView, shown: UUID?) -> ControllerTicketsPlace {
        var place = ControllerTicketsPlace(projectID: UUID(), team: "WM8")
        place.view = view
        place.hasTicket = true
        place.boardChatID = shown
        place.boardChatName = shown == nil ? nil : "Jarvis"
        return place
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
        feed(.button(button, pressed: true))
        feed(.button(button, pressed: false))
    }

    func testSwitchingToAChatWithAnOpenApprovalSendsNothing() {
        // Kreuz auf „Pia · Produkt“: Das Fenster zeigt danach Pia in der Spalte,
        // die Auswahl bleibt im Kopf.
        window.onTicketCommand = { [unowned self] command in
            guard command == .open else { return }
            window.tickets = place(.boardChatHead, shown: product)
        }
        tap(.cross)
        tap(.cross)
        tap(.cross)
        tap(.circle)
        XCTAssertTrue(terminals.keys.isEmpty, "Wechsel schickt nichts: \(terminals.keys)")
        XCTAssertNil(ui.boardChatFocus, "Kreuz führt nie in den Chat")
        // ▼: hinein, mit Ankunftssperre.
        window.onTicketCommand = nil
        window.ticketOutcome = .rightEdge
        tap(.dpadDown)
        window.ticketOutcome = .done
        XCTAssertEqual(ui.boardChatFocus, ControllerBoardChatFocus(windowID: window.id, sessionID: product))
        tap(.cross)
        tap(.cross)
        XCTAssertTrue(terminals.keys.isEmpty, "kein Enter in die offene Freigabe gleich nach der Ankunft: \(terminals.keys)")
        nowValue = nowValue.addingTimeInterval(ControllerBindingResolver.arrivalLock + 0.1)
        tap(.cross)
        XCTAssertEqual(terminals.keyTargets, [product], "nach der Sperre nur an den sichtbaren Board-Chat")
        XCTAssertFalse(terminals.keyTargets.contains(hidden))
    }

    /// „Als Tab öffnen“: Der Chat geht als Tab auf, die Tickets zu. Kreuz
    /// gleich danach bestätigt die offene Freigabe dort nicht.
    func testOpenAsTabWaitsForTheArrivalLock() {
        var onTab = place(.boardChatHead, shown: jarvis)
        onTab.columnTabChatID = jarvis
        window.tickets = onTab
        window.onTicketCommand = { [unowned self] command in
            guard command == .open else { return }
            window.tickets = nil
            window.selected = jarvis
        }
        tap(.cross)
        XCTAssertEqual(window.selected, jarvis)
        tap(.cross)
        tap(.circle)
        XCTAssertTrue(terminals.keys.isEmpty, "\(terminals.keys)")
    }

    /// Ausblenden: Danach zeigt die Spalte keinen Board-Chat mehr; ▼ führt
    /// in keinen Chat, R2 diktiert nicht.
    func testAfterHidingNothingReachesAChat() {
        window.onTicketCommand = { [unowned self] command in
            guard command == .open else { return }
            window.tickets = place(.boardChatHead, shown: nil)
        }
        tap(.cross)
        window.ticketOutcome = .rightEdge
        tap(.dpadDown)
        XCTAssertNil(ui.boardChatFocus)
        XCTAssertEqual(haptics.last, .rejected)
        XCTAssertTrue(terminals.keys.isEmpty)
    }
}
