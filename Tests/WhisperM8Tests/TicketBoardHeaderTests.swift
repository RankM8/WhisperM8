import Foundation
import XCTest
@testable import WhisperM8

/// WM8-91 Paket 3d: Kopf und Filter des Boards mit dem Controller (Auftrag
/// Giuliano 16.11.2026). ▲ über die oberste Karte in die Filterzeile, darüber
/// die Kopfzeile; ◀ ▶ wählen, Kreuz schaltet, ▼ und Kreis zurück auf die Karte.
/// Nie schaltet Bewegen einen Filter. „Alle Bereiche“ als Liste darunter.
@MainActor
final class TicketBoardHeaderTests: XCTestCase {
    private let ada = TicketPerson(id: "u1", name: "Ada Erfunden")
    private let bo = TicketPerson(id: "u2", name: "Bo Beispiel")

    // MARK: - Pur

    private var boardLayout: TicketHeaderLayout {
        .board(hasBack: true, people: [.person(id: "u1"), .person(id: "u2")])
    }

    func testBoardLayoutFollowsTheScreen() {
        XCTAssertEqual(boardLayout.rows[0], [.back, .modeBoard, .modeList, .copyList, .refresh])
        XCTAssertEqual(boardLayout.rows[1], [
            .waitingForMe, .project, .agent(.all), .agent(.withAgent), .agent(.withoutAgent),
            .person(.all), .person(.unassigned), .person(.person(id: "u1")), .person(.person(id: "u2")),
        ])
        XCTAssertEqual(TicketHeaderLayout.triage(hasBack: true, hasBoardChat: false, hasURL: true).rows,
                       [[.back, .closeTriage, .copyLink, .openInLinear, .refresh]])
        XCTAssertEqual(TicketHeaderLayout.triage(hasBack: true, hasBoardChat: true, hasURL: false).rows,
                       [[.back, .closeTriage, .copyLink, .handOff, .refresh]])
    }

    func testEntryIsTheBottomRowAndRemembersTheLastItem() {
        XCTAssertEqual(boardLayout.entry(), TicketHeaderSpot(row: 1, index: 0))
        XCTAssertEqual(boardLayout.entry(remembering: .agent(.withAgent)), TicketHeaderSpot(row: 1, index: 3))
        XCTAssertEqual(boardLayout.entry(remembering: .modeList), TicketHeaderSpot(row: 1, index: 0),
                       "nur Knöpfe der untersten Zeile werden gemerkt")
    }

    func testStepsWithoutWrapping() {
        let start = TicketHeaderSpot(row: 1, index: 0)
        XCTAssertEqual(TicketHeaderSelection.step(start, .left, in: boardLayout), .stay)
        XCTAssertEqual(TicketHeaderSelection.step(start, .right, in: boardLayout), .spot(TicketHeaderSpot(row: 1, index: 1)))
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 1, index: 8), .right, in: boardLayout), .stay)
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 1, index: 7), .up, in: boardLayout),
                       .spot(TicketHeaderSpot(row: 0, index: 4)), "höchstens der letzte Knopf der Zeile darüber")
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 0, index: 2), .up, in: boardLayout), .stay)
        XCTAssertEqual(TicketHeaderSelection.step(TicketHeaderSpot(row: 0, index: 2), .down, in: boardLayout),
                       .spot(TicketHeaderSpot(row: 1, index: 2)))
        XCTAssertEqual(TicketHeaderSelection.step(start, .down, in: boardLayout), .leave)
    }

    func testProjectListSteps() {
        let options = TicketHeaderSelection.projectOptions(["A", "B"])
        XCTAssertEqual(options, [nil, "A", "B"])
        XCTAssertEqual(TicketHeaderSelection.projectStart(current: "B", options: options), 2)
        XCTAssertEqual(TicketHeaderSelection.projectStart(current: nil, options: options), 0)
        XCTAssertEqual(TicketHeaderSelection.projectStep(0, .up, count: 3), 0)
        XCTAssertEqual(TicketHeaderSelection.projectStep(0, .down, count: 3), 1)
        XCTAssertEqual(TicketHeaderSelection.projectStep(2, .down, count: 3), 2)
    }

    // MARK: - Modell

    private func viewModel() -> TicketBoardViewModel {
        TicketBoardViewModel(model: TicketBoardBuilder.build(snapshot: TicketFixtures.snapshot([
            TicketFixtures.ticket(1, status: "Todo", assignee: ada, project: "B"),
            TicketFixtures.ticket(2, status: "Todo", assignee: bo, project: "A"),
            TicketFixtures.ticket(3, status: "In Progress", project: "A"),
        ]), chats: [], projectPath: nil), documents: .immediate)
    }

    private let context = TicketHeaderContext(hasBack: true, hasBoardChat: false)

    func testMovingOnlySelectsCrossSwitches() {
        let model = viewModel()
        XCTAssertTrue(model.enterHeader(context))
        XCTAssertEqual(model.headerItem(context), .waitingForMe)
        XCTAssertEqual(model.controllerView(isReady: true), .header)
        // Gehalten durch die ganze Zeile: kein Filter ändert sich.
        for _ in 0..<12 { _ = model.headerMove(.right, context) }
        XCTAssertEqual(model.filter, TicketBoardFilter.all, "Bewegen schaltet nie")
        for _ in 0..<12 { _ = model.headerMove(.left, context) }
        _ = model.headerMove(.right, context)   // „Alle Bereiche“
        _ = model.headerMove(.right, context)   // Agent: Alle
        _ = model.headerMove(.right, context)   // Mit Agent
        XCTAssertEqual(model.headerItem(context), .agent(.withAgent))
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.filter.agent, .withAgent)
        XCTAssertEqual(model.headerItem(context), .agent(.withAgent), "die Auswahl bleibt auf dem Knopf")
    }

    func testWaitingForMeAndPersonToggle() {
        let model = viewModel()
        model.enterHeader(context)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertTrue(model.filter.waitingForMe)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertFalse(model.filter.waitingForMe)
        for _ in 0..<6 { _ = model.headerMove(.right, context) }   // Person: Nicht zugewiesen
        XCTAssertEqual(model.headerItem(context), .person(.unassigned))
        _ = model.headerActivate(context)
        XCTAssertEqual(model.filter.person, .unassigned)
    }

    func testDownAndCircleGoBackToTheCard() {
        let model = viewModel()
        model.ensureControllerSelection(preferringChat: nil)
        let spot = model.boardSpot
        model.enterHeader(context)
        XCTAssertEqual(model.headerMove(.down, context), .done)
        XCTAssertNil(model.headerFocus)
        XCTAssertEqual(model.boardSpot, spot, "zurück auf die Karte, von der man kam")
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
        _ = model.headerMove(.up, context)               // ← Chats
        XCTAssertEqual(model.headerActivate(context), .goBack)
        _ = model.headerMove(.right, context)            // Board
        _ = model.headerMove(.right, context)            // Liste
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.mode, .list)
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerActivate(context), .copyList)
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerActivate(context), .refresh)
    }

    /// Entscheidung 16.11.2026: Liste darunter, ▲ ▼ wählen, Kreuz übernimmt,
    /// Kreis schließt ohne Änderung; das Board filtert erst beim Übernehmen.
    func testProjectListOpensBelowAndAppliesOnlyOnCross() {
        let model = viewModel()
        model.enterHeader(context)
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerItem(context), .project)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.projectPickerIndex, 0, "auf „Alle Bereiche“")
        XCTAssertEqual(model.controllerView(isReady: true), .headerPicker)
        _ = model.headerMove(.down, context)
        XCTAssertNil(model.filter.project, "Bewegen filtert nicht")
        model.headerBack()
        XCTAssertNil(model.projectPickerIndex)
        XCTAssertNil(model.filter.project, "Kreis schließt ohne Änderung")
        XCTAssertEqual(model.headerItem(context), .project, "die Auswahl bleibt auf dem Knopf")
        _ = model.headerActivate(context)
        _ = model.headerMove(.down, context)
        let wanted = TicketHeaderSelection.projectOptions(model.presentation.projects)[1]
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertEqual(model.filter.project, wanted)
        XCTAssertNil(model.projectPickerIndex)
    }

    func testOpeningTheTriageResetsTheHeader() {
        let model = viewModel()
        var changes = 0
        model.onControllerViewChange = { changes += 1 }
        model.enterHeader(context)
        model.openFromLane("WM8-1")
        XCTAssertNil(model.headerFocus)
        XCTAssertEqual(changes, 1, "Triage auf: die Leiste liest neu")
        model.enterHeader(context)
        XCTAssertEqual(model.headerItem(context), .back, "die Triage hat eine Zeile")
        _ = model.headerMove(.right, context)
        XCTAssertEqual(model.headerActivate(context), .done)
        XCTAssertNil(model.triage, "„Board“ schließt die Triage")
        model.mode = .list
        XCTAssertEqual(changes, 3)
    }

    /// Folgepunkt der Prüferin zu 3d: Ein Mausklick räumt Kopf und offene
    /// Liste der Bereiche in jedem Board; ein späteres Kreuz trifft keinen
    /// alten Knopf mehr.
    func testMouseClearsTheHeaderInEveryBoard() {
        let first = viewModel(), second = viewModel(), idle = viewModel()
        first.enterHeader(context)
        second.enterHeader(context)
        _ = second.headerMove(.right, context)
        _ = second.headerActivate(context)   // Liste der Bereiche offen
        XCTAssertNotNil(second.projectPickerIndex)
        TicketBoardControllers.leaveHeaders([first, second, idle])
        XCTAssertNil(first.headerFocus)
        XCTAssertNil(second.headerFocus)
        XCTAssertNil(second.projectPickerIndex)
        XCTAssertNil(idle.headerFocus)
        XCTAssertNotEqual(first.controllerView(isReady: true), .header)
        XCTAssertEqual(first.headerActivate(context), .rejected, "Kreuz danach schaltet keinen alten Knopf")
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
        XCTAssertTrue(ControllerLegend.entries(for: header(.board)).map(\.label).contains(.boardFilters), "▲ Filter auf dem Board")
    }
}
