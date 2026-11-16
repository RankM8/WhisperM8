import Foundation
import XCTest
@testable import WhisperM8

/// WM8-91 Paket 3d, seit WM8-125 mit Reitern statt Filtern: ▲ über die
/// oberste Karte bzw. Zeile in die Reiterzeile, darüber die Kopfzeile; ◀ ▶
/// wählen, Kreuz schaltet, ▼ und Kreis zurück. Nie schaltet Bewegen einen
/// Reiter. Was nicht in die Zeile passt, steht unter „Mehr“ als Liste darunter.
@MainActor
final class TicketBoardHeaderTests: XCTestCase {
    // MARK: - Pur

    private var boardLayout: TicketHeaderLayout {
        .board(hasBack: true, tabs: ["n", "w", "e"], hasMore: true)
    }

    func testBoardLayoutFollowsTheScreen() {
        XCTAssertEqual(boardLayout.rows[0], [.back, .modeList, .modeBoard, .copyList, .refresh])
        XCTAssertEqual(boardLayout.rows[1], [.view("n"), .view("w"), .view("e"), .moreViews])
        XCTAssertEqual(TicketHeaderLayout.board(hasBack: false, tabs: ["n"], hasMore: false).rows,
                       [[.modeList, .modeBoard, .copyList, .refresh], [.view("n")]])
        XCTAssertEqual(TicketHeaderLayout.triage(hasBack: true, hasBoardChat: false, hasURL: true).rows,
                       [[.back, .closeTriage, .copyLink, .openInLinear, .refresh]])
        XCTAssertEqual(TicketHeaderLayout.triage(hasBack: true, hasBoardChat: true, hasURL: false).rows,
                       [[.back, .closeTriage, .copyLink, .handOff, .refresh]])
    }

    func testEntryIsTheBottomRowAndRemembersTheLastItem() {
        XCTAssertEqual(boardLayout.entry(), TicketHeaderSpot(row: 1, index: 0))
        XCTAssertEqual(boardLayout.entry(remembering: .view("e")), TicketHeaderSpot(row: 1, index: 2))
        XCTAssertEqual(boardLayout.entry(remembering: .modeList), TicketHeaderSpot(row: 1, index: 0),
                       "nur Knöpfe der untersten Zeile werden gemerkt")
    }

    func testStepsWithoutWrapping() {
        let start = TicketHeaderSpot(row: 1, index: 0)
        XCTAssertEqual(TicketHeaderSelection.step(start, .left, in: boardLayout), .stay)
        XCTAssertEqual(TicketHeaderSelection.step(start, .right, in: boardLayout), .spot(TicketHeaderSpot(row: 1, index: 1)))
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 1, index: 3), .right, in: boardLayout), .stay)
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 1, index: 3), .up, in: boardLayout),
                       .spot(TicketHeaderSpot(row: 0, index: 3)))
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 0, index: 2), .up, in: boardLayout), .stay)
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 0, index: 4), .down, in: boardLayout),
                       .spot(TicketHeaderSpot(row: 1, index: 3)), "höchstens der letzte Knopf der Zeile darunter")
        XCTAssertEqual(TicketHeaderSelection.step(start, .down, in: boardLayout), .leave)
    }

    func testPickerSteps() {
        XCTAssertEqual(TicketHeaderSelection.pickerStep(0, .up, count: 3), 0)
        XCTAssertEqual(TicketHeaderSelection.pickerStep(0, .down, count: 3), 1)
        XCTAssertEqual(TicketHeaderSelection.pickerStep(2, .down, count: 3), 2)
        XCTAssertEqual(TicketHeaderSelection.pickerStep(5, .left, count: 3), 2)
    }

    // MARK: Reiter in der Zeile

    private func view(_ id: String) -> TicketView { TicketFixtures.view(id) }

    func testTabsAllFitWithoutMore() {
        let views = [view("a"), view("b"), view("c")]
        let tabs = TicketViewTabs.split(views, active: "a", width: 400) { _ in 100 }
        XCTAssertEqual(tabs.shown.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(tabs.more.isEmpty)
        XCTAssertEqual(TicketViewTabs.split(views, active: "a", width: nil) { _ in 1000 }.shown.count, 3, "ungemessen: alle")
    }

    func testTabsThatDoNotFitGoUnderMoreAndTheActiveOneStays() {
        let views = [view("a"), view("b"), view("c"), view("d"), view("e")]
        // 100 je Reiter, „Mehr“ 84: in 330 passen zwei Reiter und „Mehr“.
        let tabs = TicketViewTabs.split(views, active: "a", width: 330) { _ in 100 }
        XCTAssertEqual(tabs.shown.map(\.id), ["a", "b"])
        XCTAssertEqual(tabs.more.map(\.id), ["c", "d", "e"])

        let activeLate = TicketViewTabs.split(views, active: "e", width: 330) { _ in 100 }
        XCTAssertEqual(activeLate.shown.map(\.id), ["a", "e"], "der gezeigte Reiter steht immer in der Zeile")
        XCTAssertEqual(activeLate.more.map(\.id), ["b", "c", "d"])

        let tiny = TicketViewTabs.split(views, active: "d", width: 50) { _ in 100 }
        XCTAssertEqual(tiny.shown.map(\.id), ["d"], "zur Not nur der gezeigte")
    }

    // MARK: - Modell

    private func viewModel(width: CGFloat? = nil) -> TicketBoardViewModel {
        var board = TicketBoardBuilder.build(snapshot: TicketFixtures.snapshot([
            TicketFixtures.ticket(1, status: "Todo", project: "B"),
            TicketFixtures.ticket(2, status: "Todo", project: "A"),
            TicketFixtures.ticket(3, status: "In Progress", project: "A"),
        ]), chats: [], projectPath: nil)
        board.view = view("n")
        let model = TicketBoardViewModel(model: board, documents: .immediate)
        model.setViews(TicketViewCatalog(views: [view("n"), view("w"), view("e"), view("x")], defaultID: "n"),
                       active: "n", isLoading: false)
        if let width { model.setTabsWidth(width) }
        return model
    }

    private let context = TicketHeaderContext(hasBack: true, hasBoardChat: false)

    func testMovingOnlySelectsCrossSwitchesTheView() {
        let model = viewModel()
        var asked: [String] = []
        model.onSelectView = { asked.append($0) }
        XCTAssertTrue(model.enterHeader(context))
        XCTAssertEqual(model.headerItem(context), .view("n"), "Einstieg auf dem gezeigten Reiter")
        XCTAssertEqual(model.controllerView(isReady: true), .header)
        // Gehalten durch die ganze Zeile: kein Reiter wechselt.
        for _ in 0..<12 { _ = model.headerMove(.right, context) }
        XCTAssertEqual(model.activeViewID, "n", "Bewegen schaltet nie")
        XCTAssertTrue(asked.isEmpty)
        for _ in 0..<12 { _ = model.headerMove(.left, context) }
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerItem(context), .view("w"))
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.activeViewID, "w")
        XCTAssertEqual(asked, ["w"])
        XCTAssertEqual(model.headerItem(context), .view("w"), "die Auswahl bleibt auf dem Reiter")
    }

    func testDownAndCircleGoBackToTheRow() {
        let model = viewModel()
        model.ensureControllerSelection(preferringChat: nil)
        let stop = model.listStop
        XCTAssertNotNil(stop)
        model.enterHeader(context)
        XCTAssertEqual(model.headerMove(.down, context), .done)
        XCTAssertNil(model.headerFocus)
        XCTAssertEqual(model.listStop, stop, "zurück auf die Zeile, von der man kam")
        model.enterHeader(context)
        _ = model.headerMove(.up, context)
        XCTAssertEqual(model.headerItem(context), .back)
        model.headerBack()
        XCTAssertNil(model.headerFocus)
        XCTAssertNotEqual(model.controllerView(isReady: true), .header)
    }

    func testTopRowSwitchesModeAndHandsOutTheRest() {
        let model = viewModel()
        model.enterHeader(context)
        _ = model.headerMove(.up, context)
        XCTAssertEqual(model.headerItem(context), .back)
        XCTAssertEqual(model.headerActivate(context), .goBack)
        _ = model.headerMove(.right, context)            // Liste
        _ = model.headerMove(.right, context)            // Board
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.mode, .board)
        _ = model.headerMove(.left, context)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.mode, .list)
        _ = model.headerMove(.right, context)
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerActivate(context), .copyList)
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerActivate(context), .refresh)
    }

    /// Wie früher die Liste der Bereiche: Liste darunter, ▲ ▼ wählen, Kreuz
    /// zeigt die Ansicht, Kreis schließt ohne Änderung.
    func testMoreOpensAListAndSwitchesOnlyOnCross() {
        // Reiter „Ansicht n“ je rund 85 pt: In 280 passen zwei und „Mehr“.
        let model = viewModel(width: 280)
        XCTAssertEqual(model.tabs.shown.map(\.id), ["n", "w"])
        XCTAssertEqual(model.tabs.more.map(\.id), ["e", "x"])
        model.enterHeader(context)
        _ = model.headerMove(.right, context)
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerItem(context), .moreViews)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.morePickerIndex, 0)
        XCTAssertEqual(model.controllerView(isReady: true), .headerPicker)
        _ = model.headerMove(.down, context)
        XCTAssertEqual(model.activeViewID, "n", "Bewegen wechselt nicht")
        model.headerBack()
        XCTAssertNil(model.morePickerIndex)
        XCTAssertEqual(model.activeViewID, "n", "Kreis schließt ohne Änderung")
        _ = model.headerActivate(context)
        _ = model.headerMove(.down, context)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.activeViewID, "x")
        XCTAssertNil(model.morePickerIndex)
        XCTAssertTrue(model.tabs.shown.contains { $0.id == "x" }, "der gezeigte Reiter rückt in die Zeile")
        XCTAssertEqual(model.headerItem(context), .view("x"), "die Auswahl folgt ihm")
    }

    func testOpeningTheTriageResetsTheHeader() {
        let model = viewModel()
        var changes = 0
        model.onControllerViewChange = { changes += 1 }
        model.enterHeader(context)
        model.openFromList("WM8-1")
        XCTAssertNil(model.headerFocus)
        XCTAssertEqual(changes, 1, "Triage auf: die Leiste liest neu")
        model.enterHeader(context)
        XCTAssertEqual(model.headerItem(context), .back, "die Triage hat eine Zeile")
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertNil(model.triage, "„‹ Liste“ schließt die Triage")
        model.mode = .board
        XCTAssertEqual(changes, 3)
    }

    /// Folgepunkt der Prüferin zu 3d: Ein Mausklick räumt Kopf und offene
    /// Liste in jedem Board; ein späteres Kreuz trifft keinen alten Knopf mehr.
    func testMouseClearsTheHeaderInEveryBoard() {
        let first = viewModel(), second = viewModel(width: 280), idle = viewModel()
        first.enterHeader(context)
        second.enterHeader(context)
        _ = second.headerMove(.right, context)
        _ = second.headerMove(.right, context)
        _ = second.headerActivate(context)   // Liste unter „Mehr“ offen
        XCTAssertNotNil(second.morePickerIndex)
        TicketBoardControllers.leaveHeaders([first, second, idle])
        XCTAssertNil(first.headerFocus)
        XCTAssertNil(second.headerFocus)
        XCTAssertNil(second.morePickerIndex)
        XCTAssertNil(idle.headerFocus)
        XCTAssertNotEqual(first.controllerView(isReady: true), .header)
        XCTAssertEqual(first.headerActivate(context), .rejected, "Kreuz danach schaltet keinen alten Knopf")
    }

    /// Mausklick auf einen Eintrag der offenen Liste: wählt ihn, auch wenn das
    /// Räumen nach dem Klick schon gelaufen ist.
    func testMouseClickOnAListEntryChoosesIt() {
        let model = viewModel(width: 280)
        model.enterHeader(context)
        _ = model.headerMove(.right, context)
        _ = model.headerMove(.right, context)
        _ = model.headerActivate(context)
        XCTAssertNotNil(model.morePickerIndex)
        TicketBoardControllers.leaveHeaders([model])
        model.chooseMoreViewByMouse("e")
        XCTAssertEqual(model.activeViewID, "e")
        XCTAssertNil(model.morePickerIndex, "Liste zu")
        XCTAssertNil(model.headerFocus, "die Maus hat übernommen: kein Ring mehr")
        XCTAssertEqual(model.headerActivate(context), .rejected, "ein späteres Kreuz schaltet nichts im Kopf")
    }

    // MARK: Liste mit Gruppen (WM8-125)

    func testListWalksGroupHeadersAndCollapsesWithLeftAndRight() {
        let model = viewModel()
        XCTAssertEqual(model.listStops, ["group:status:in progress", "WM8-3", "group:status:todo", "WM8-1", "WM8-2"])
        model.ensureControllerSelection(preferringChat: nil)
        XCTAssertEqual(model.listStop, "WM8-3", "Start auf dem ersten Ticket")
        XCTAssertEqual(model.controllerMove(.up), .done)
        XCTAssertEqual(model.selectedGroupID, "status:in progress")
        XCTAssertNil(model.selectedKey)
        XCTAssertEqual(model.controllerView(isReady: true), .list)
        XCTAssertEqual(model.controllerMove(.up), .topEdge, "über dem ersten Kopf: in die Reiter")

        XCTAssertEqual(model.controllerMove(.left), .done)
        XCTAssertTrue(model.isCollapsed("status:in progress"))
        XCTAssertEqual(model.controllerMove(.left), .leftEdge, "schon zu: weiter in die Seitenleiste")
        XCTAssertEqual(model.controllerMove(.down), .done)
        XCTAssertEqual(model.selectedGroupID, "status:todo", "zugeklappte Tickets werden übersprungen")
        XCTAssertEqual(model.controllerOpen(), .done, "Kreuz auf dem Kopf klappt")
        XCTAssertTrue(model.isCollapsed("status:todo"))
        XCTAssertNil(model.triage)
        XCTAssertEqual(model.controllerView(isReady: true), .list, "alles zu: trotzdem bedienbar")
        XCTAssertEqual(model.controllerMove(.right), .done)
        XCTAssertFalse(model.isCollapsed("status:todo"))
        XCTAssertEqual(model.controllerMove(.down), .done)
        XCTAssertEqual(model.selectedKey, "WM8-1")
        XCTAssertEqual(model.controllerOpen(), .done)
        XCTAssertEqual(model.triage?.keys, ["WM8-1", "WM8-2"], "die Triage kennt nur aufgeklappte Gruppen")
    }

    /// „← Chats“ per Tastatur (Kommentar vom 16.11., 18:00): Im Raster wartet
    /// die Kachel mit Fokus wie ein Chat; bleiben die Tickets offen, keiner.
    func testKeyboardBackArrivalReachesTheFocusedTile() {
        let chat = UUID(), tile = UUID(), behind = UUID()
        XCTAssertEqual(KeyboardBackArrival.chatBefore(.chat(chat)), chat)
        XCTAssertNil(KeyboardBackArrival.chatBefore(.workspace(UUID())))
        XCTAssertNil(KeyboardBackArrival.chatBefore(nil))

        XCTAssertEqual(KeyboardBackArrival.shownAfter(placeBefore: .workspace(UUID()), ticketsStillOpen: false,
                                                      shown: tile), tile)
        XCTAssertEqual(KeyboardBackArrival.shownAfter(placeBefore: nil, ticketsStillOpen: false, shown: behind),
                       behind, "kein voriger Ort: der Chat hinter den Tickets")
        XCTAssertNil(KeyboardBackArrival.shownAfter(placeBefore: .chat(chat), ticketsStillOpen: false, shown: chat),
                     "Chat ist schon vorher gesperrt")
        XCTAssertNil(KeyboardBackArrival.shownAfter(placeBefore: .workspace(UUID()), ticketsStillOpen: true,
                                                    shown: tile), "Weg ging nicht: keine Ankunft")
        XCTAssertNil(KeyboardBackArrival.shownAfter(placeBefore: .tickets(projectID: nil), ticketsStillOpen: true,
                                                    shown: tile), "anderes Board")
        XCTAssertNil(KeyboardBackArrival.shownAfter(placeBefore: .workspace(UUID()), ticketsStillOpen: false,
                                                    shown: nil))
    }

    // MARK: - Belegung

    private func header(_ view: ControllerTicketView) -> ControllerContext {
        var place = ControllerTicketsPlace(projectID: UUID(), team: "WM8")
        place.view = view
        place.hasTicket = true
        return .tickets(ControllerTicketState(place: place, area: .content))
    }

    private func action(_ gesture: ControllerGesture, _ context: ControllerContext) -> ControllerAction? {
        ControllerBindingResolver.action(for: gesture, in: context)
    }

    func testBindingsInTheHeader() {
        let context = header(.header)
        XCTAssertEqual(action(.move(.right, source: .leftStick, isRepeat: true), context), .ticket(.move(.right)),
                       "gehalten wandert die Auswahl, ohne zu schalten")
        XCTAssertEqual(action(.press(.cross), context), .ticket(.open))
        XCTAssertEqual(action(.tap(.circle), context), .ticket(.back))
        XCTAssertEqual(action(.tap(.l1), context), .ticket(.adjacent(-1)))
        let picker = header(.headerPicker)
        XCTAssertEqual(action(.move(.down, source: .dpad, isRepeat: false), picker), .ticket(.move(.down)))
        XCTAssertNil(action(.move(.right, source: .dpad, isRepeat: false), picker))
        XCTAssertEqual(action(.press(.cross), picker), .ticket(.open))
        XCTAssertEqual(action(.tap(.circle), picker), .ticket(.back))
        XCTAssertNil(action(.tap(.square), picker))
    }

    /// Hinein nur mit einem einzelnen Druck; gehalten rutscht nichts in den Kopf.
    func testHeldStickNeverEntersTheHeader() {
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: true), header(.board)), .ticket(.repeatMove(.up)))
        XCTAssertEqual(action(.move(.up, source: .leftStick, isRepeat: true), header(.triage)), .ticket(.repeatMove(.up)))
        XCTAssertEqual(action(.move(.up, source: .dpad, isRepeat: false), header(.empty)), .ticket(.move(.up)),
                       "auch aus dem leeren Board (Filter zurücksetzen)")
        XCTAssertNil(action(.move(.up, source: .dpad, isRepeat: true), header(.empty)))
    }

    /// Im Kopf erreicht keine Geste einen Chat (wie im übrigen Ticket-Modus).
    func testNoGestureInTheHeaderReachesAChat() {
        var inputs: [ControllerLegendInput] = ControllerButton.allCases.map { .button($0) }
        inputs += [.leftStick, .rightStick, .dpad, .bumpers]
        let plain = Array(Set(inputs.flatMap(ControllerLegend.gestures(for:))))
        let gestures = plain + ControllerLayer.allCases.flatMap { layer in plain.map { ControllerGesture.inLayer(layer, $0) } }
        for context in [header(.header), header(.headerPicker)] {
            for gesture in gestures {
                guard let action = action(gesture, context) else { continue }
                switch action {
                case .dictationToggle, .dictationStopAndSubmit, .chatKey, .chatInterrupt, .chatResume, .chatClearInput,
                     .pasteNewest, .moveInContent, .toggleMaximize, .scroll, .scrollPage, .scrollToBottom,
                     .sendNowOrContinue, .cycleMode, .slashCommand, .bridgeKey, .listActivate, .listStartRow, .listCloseRow:
                    XCTFail("\(gesture) → \(action)")
                default:
                    break
                }
            }
        }
    }

    func testLegendInTheHeader() {
        let labels = ControllerLegend.entries(for: header(.header)).map(\.label)
        XCTAssertEqual(Array(labels.prefix(3)), [.move, .select, .back])
        XCTAssertEqual(ControllerLegend.entries(for: header(.headerPicker)).map(\.label), [.move, .select, .close])
        XCTAssertTrue(ControllerLegend.entries(for: header(.board)).map(\.label).contains(.boardViews), "▲ Filter auf dem Board")
    }
}
