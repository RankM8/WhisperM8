import Foundation
import XCTest
@testable import WhisperM8

private typealias TerminalSpy = ControllerTerminalSpy
private typealias DictationSpy = ControllerDictationSpy
private typealias EnvironmentSpy = ControllerEnvironmentSpy
private typealias WindowFake = ControllerWindowFake

/// Ausführer der Controller-Steuerung: Zustand der App als Schnappschuss und
/// die Wirkung jeder Aktion.
@MainActor
final class ControllerActionDispatcherTests: XCTestCase {
    private var window: WindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: TerminalSpy!
    private var dictation: DictationSpy!
    private var environment: EnvironmentSpy!
    private var ui: ControllerUIModel!
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var keyWindowID: UUID?

    override func setUp() async throws {
        window = WindowFake()
        keyWindowID = window.id
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in keyWindowID })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = TerminalSpy()
        dictation = DictationSpy()
        environment = EnvironmentSpy()
        ui = ControllerUIModel()
        haptics = []
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation, environment: environment,
            ui: ui, island: ControllerIslandSpy(), now: { [unowned self] in clock })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        setTerminal(status: .idle)
    }

    private func setTerminal(
        status: AgentSessionRuntimeStatus?, running: Bool = true,
        profile: ControllerChatState.Profile = .claude, draft: Bool = false,
        statusSince: Date? = nil, lastEnter: Date? = nil, lastEscape: Date? = nil,
        lastDraftInput: Date? = nil, choiceListOpen: Bool = false
    ) {
        guard let selected = window.selected else { return }
        terminals.states[selected] = ControllerTerminalState(
            isRunning: running, profile: profile, status: status, statusSince: statusSince,
            draftSuspected: draft, lastEnterAt: lastEnter, lastEscapeAt: lastEscape,
            lastDraftInputAt: lastDraftInput, choiceListOpen: choiceListOpen)
    }

    private var context: ControllerContext {
        ControllerContextResolver.context(for: dispatcher.snapshot())
    }

    private func perform(_ action: ControllerAction) {
        dispatcher.perform(action, in: context)
    }

    // MARK: - Schnappschuss

    func testChatContextCarriesTerminalState() {
        setTerminal(status: .working, draft: true)
        guard case let .chat(state) = context else { return XCTFail("chat erwartet, war \(context)") }
        XCTAssertEqual(state.status, .working)
        XCTAssertEqual(state.profile, .claude)
        XCTAssertTrue(state.draftSuspected)
        XCTAssertTrue(state.hasTerminal)
    }

    func testChatWithoutTerminalCountsAsEnded() {
        terminals.states = [:]
        guard case let .chat(state) = context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(state.status, .ended)
        XCTAssertFalse(state.hasTerminal)
    }

    func testStoppedProcessCountsAsEnded() {
        setTerminal(status: .idle, running: false)
        guard case let .chat(state) = context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(state.status, .ended)
    }

    /// Review-Befund 3: Eine Eingabe per Controller hält Kreuz bei
    /// arbeitendem Chat 30 s lang scharf.
    func testRecentDraftInputIsTimeLimited() {
        setTerminal(status: .working, lastDraftInput: clock.addingTimeInterval(-29))
        guard case let .chat(fresh) = context else { return XCTFail("chat erwartet") }
        XCTAssertTrue(fresh.recentDraftInput)
        XCTAssertEqual(ControllerBindingResolver.action(for: .press(.cross), in: context), .chatKey(.enter))

        clock = clock.addingTimeInterval(2)
        guard case let .chat(later) = context else { return XCTFail("chat erwartet") }
        XCTAssertFalse(later.recentDraftInput)
        XCTAssertNil(ControllerBindingResolver.action(for: .press(.cross), in: context))
    }

    /// Befund 5 nach Runde 3: Eine Eingabe zählt nur, wenn danach nichts
    /// abgeschickt wurde — auf welchem Weg auch immer (`lastEnterAt` ist das
    /// letzte Absenden: Kreuz auch in Rückfragen, Tastatur, `chats send`,
    /// Diktat, Menü).
    func testDraftInputOlderThanLastSubmitDoesNotArmCross() {
        setTerminal(status: .working, lastEnter: clock.addingTimeInterval(-5), lastDraftInput: clock.addingTimeInterval(-10))
        guard case let .chat(state) = context else { return XCTFail("chat erwartet") }
        XCTAssertFalse(state.recentDraftInput)
        XCTAssertNil(ControllerBindingResolver.action(for: .press(.cross), in: context))

        setTerminal(status: .working, lastEnter: clock.addingTimeInterval(-10), lastDraftInput: clock.addingTimeInterval(-5))
        guard case let .chat(newer) = context else { return XCTFail("chat erwartet") }
        XCTAssertTrue(newer.recentDraftInput)
    }

    func testChoiceListOpenReachesChatState() {
        setTerminal(status: .idle, choiceListOpen: true)
        guard case let .chat(state) = context else { return XCTFail("chat erwartet") }
        XCTAssertTrue(state.choiceListOpen)
        XCTAssertEqual(ControllerBindingResolver.action(for: .move(.left, source: .dpad, isRepeat: false), in: context),
                       .chatKey(.left))
    }

    func testRecentEnterAndEscapeAreTimeLimited() {
        setTerminal(status: .idle, lastEnter: clock.addingTimeInterval(-1), lastEscape: clock.addingTimeInterval(-0.5))
        guard case let .chat(fresh) = context else { return XCTFail("chat erwartet") }
        XCTAssertTrue(fresh.recentlySubmitted)
        XCTAssertTrue(fresh.escapeSentRecently)

        clock = clock.addingTimeInterval(10)
        guard case let .chat(later) = context else { return XCTFail("chat erwartet") }
        XCTAssertFalse(later.recentlySubmitted)
        XCTAssertFalse(later.escapeSentRecently)
    }

    func testAwaitingInputReportsItsAge() {
        setTerminal(status: .awaitingInput, statusSince: clock.addingTimeInterval(-0.2))
        guard case let .chat(state) = context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(state.secondsSinceAwaitingBegan ?? -1, 0.2, accuracy: 0.001)
    }

    func testNoKeyWindowIsOtherOrNone() {
        keyWindowID = nil
        XCTAssertEqual(context, .noWindow)
        environment.hasOtherKeyWindow = true
        XCTAssertEqual(context, .otherWindow)
    }

    func testSheetOrPopoverMakesItModal() {
        window.hasSheet = true
        XCTAssertEqual(context, .modal)
        window.hasSheet = false
        environment.isModalOpen = true
        XCTAssertEqual(context, .modal)
    }

    func testAppInBackgroundIsOutsideApp() {
        environment.isAppActive = false
        XCTAssertEqual(context, .outsideApp(backgroundEnabled: false))
    }

    /// Debug-Kanal der Test-Instanz: Fenster und „vorne“ werden unterstellt.
    func testDebugOverrideProvidesWindowAndFrontmost() {
        keyWindowID = nil
        environment.isAppActive = false
        dispatcher.debugOverride = { [window] in
            ControllerDebugOverride(windowID: window!.id, assumeFrontmost: true)
        }
        guard case .chat = context else { return XCTFail("chat erwartet, war \(context)") }
        perform(.lastChat)
        XCTAssertEqual(window.commands.last, .lastChat)
    }

    // MARK: - Tasten in den Chat

    func testChatKeysGoToTheSelectedTerminal() {
        perform(.chatKey(.enter))
        perform(.chatKey(.up))
        perform(.chatInterrupt)
        XCTAssertEqual(terminals.keys, [.enter, .up, .escape])
    }

    func testBackspaceAndScroll() {
        perform(.chatKey(.backspace))
        perform(.scroll(lines: -3))
        XCTAssertEqual(terminals.keys, [.backspace])
        XCTAssertEqual(terminals.scrolled, [-3])
    }

    /// Runde 2: Scrollen auch während der Aufnahme, im ausgewählten Chat.
    func testScrollWhileRecording() {
        perform(.dictationToggle)
        guard case .recording = context else { return XCTFail("Aufnahme erwartet") }
        perform(.scroll(lines: 2))
        XCTAssertEqual(terminals.scrolled, [2])
    }

    /// Runde 2: Kreuz auf einem gestoppten Chat startet ihn über den Katalog.
    func testResumeStartsSelectedChat() {
        setTerminal(status: .idle, running: false)
        guard case let .chat(state) = context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(ControllerBindingResolver.action(for: .press(.cross), in: .chat(state)), .chatResume)
        perform(.chatResume)
        XCTAssertEqual(window.commands.last, .startChat(window.selected!))
        XCTAssertEqual(haptics, [])
        XCTAssertEqual(terminals.keys, [], "kein Enter an ein gestopptes Terminal")
    }

    func testResumeWithNothingToStartIsRejected() {
        window.failing = [String(describing: AgentChatsCommand.startChat(window.selected!))]
        perform(.chatResume)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testNothingIsSentWithoutSelection() {
        window.selected = nil
        dispatcher.perform(.chatKey(.enter), in: .list)
        XCTAssertEqual(terminals.keys, [])
    }

    // MARK: - Navigation

    func testLastChat() {
        perform(.lastChat)
        XCTAssertEqual(window.commands, [.lastChat])
    }

    /// Das Ziel von L2 kommt aus dem Fenster in den Zusammenhang, und nach
    /// dem Sprung nennt die Legende gleich das neue Ziel (den verlassenen Ort).
    func testBackTargetReachesContextAndRefreshesAfterJump() {
        let marketing = ControllerBackTarget(kind: .workspace, title: "Marketing")
        let loginFix = ControllerBackTarget(kind: .chat, title: "Login-Fix")
        window.backTarget = marketing
        window.backTargetAfterJump = loginFix
        guard case let .chat(state) = context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(state.backTarget, marketing)

        perform(.lastChat)
        guard case let .chat(after) = ui.context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(after.backTarget, loginFix)
        XCTAssertEqual(haptics, [])
    }

    func testFailedJumpGivesRejectFeedback() {
        window.failing = [String(describing: AgentChatsCommand.lastChat)]
        perform(.lastChat)
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Runde 3: Dreieck aus einem anderen Fenster holt Agent Chats nach vorn
    /// (vorher über „nächster wartender Chat“).
    func testTriangleFromOtherWindowBringsAgentChatsToFront() {
        keyWindowID = nil
        environment.hasOtherKeyWindow = true
        let current = context
        XCTAssertEqual(current, .otherWindow)
        perform(ControllerBindingResolver.action(for: .press(.triangle), in: current)!)
        XCTAssertEqual(environment.broughtToFront, 1)
        XCTAssertEqual(window.commands, [])
    }

    func testMovingInGridUsesGridFocus() {
        window.isGridActive = true
        perform(.moveInContent(.right))
        XCTAssertEqual(window.commands, [.gridFocus(.right)])
        XCTAssertEqual(ui.area, .content)
    }

    /// Am linken Rand des Rasters geht es in die Liste.
    func testLeftAtGridEdgeEntersList() {
        window.isGridActive = true
        window.failing = [String(describing: AgentChatsCommand.gridFocus(.left))]
        window.rows = [AgentChatsListRow(row: .chat(window.selected!))]
        perform(.moveInContent(.left))
        XCTAssertEqual(ui.area, .list)
        XCTAssertEqual(ui.markedRow, .chat(window.selected!))
    }

    func testOtherDirectionsAtGridEdgeDoNothing() {
        window.isGridActive = true
        window.failing = [String(describing: AgentChatsCommand.gridFocus(.up))]
        perform(.moveInContent(.up))
        XCTAssertEqual(ui.area, .content)
    }

    func testMultiSelectionIsClearedFirst() {
        window.hasMultiSelection = true
        perform(.lastChat)
        XCTAssertEqual(window.commands, [.clearMultiSelection, .lastChat])
    }

    // MARK: - Liste links

    private func makeRows() -> (workspace: UUID, project: UUID, chat: UUID) {
        let workspace = UUID(), project = UUID(), chat = UUID()
        window.rows = [
            AgentChatsListRow(row: .workspace(workspace)),
            AgentChatsListRow(row: .project(project), projectID: project, activeSessionIDs: [chat]),
            AgentChatsListRow(row: .chat(chat), projectID: project),
        ]
        return (workspace, project, chat)
    }

    func testEnterListShowsSidebarAndMarksCurrentChat() {
        let ids = makeRows()
        window.selected = ids.chat
        window.isSidebarVisible = false
        perform(.moveInContent(.left))
        XCTAssertTrue(window.isSidebarVisible)
        XCTAssertEqual(ui.markedRow, .chat(ids.chat))
        XCTAssertEqual(context, .list)
    }

    func testEmptyListCannotBeEntered() {
        perform(.moveInContent(.left))
        XCTAssertEqual(ui.area, .content)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testMovingAndActivatingRows() {
        let ids = makeRows()
        perform(.moveInContent(.left))          // startet auf der ersten Zeile (kein Treffer für die Auswahl)
        XCTAssertEqual(ui.markedRow, .workspace(ids.workspace))
        perform(.listActivate)
        XCTAssertEqual(window.commands.last, .activateWorkspace(ids.workspace))
        XCTAssertEqual(ui.area, .content, "Nach dem Öffnen ist man im Inhalt")

        perform(.moveInContent(.left))
        perform(.listMove(step: 1))
        XCTAssertEqual(ui.markedRow, .project(ids.project))
        perform(.listActivate)
        XCTAssertEqual(window.commands.last, .openProjectAsWorkspace(ids.project, activeSessionIDs: [ids.chat]))

        perform(.moveInContent(.left))
        perform(.listMove(step: 2))
        perform(.listActivate)
        XCTAssertEqual(window.commands.last, .selectSession(ids.chat))
    }

    /// Verschwindet die markierte Zeile (Filter, Chat geschlossen), rückt die
    /// Markierung auf den Nachbarn.
    func testMarkerSurvivesVanishingRow() {
        let ids = makeRows()
        perform(.moveInContent(.left))
        perform(.listMove(step: 2))
        XCTAssertEqual(ui.markedRow, .chat(ids.chat))
        window.rows.removeLast()
        // Beim Bewegen gilt ein kurz zurückliegender Stand der Zeilen.
        clock = clock.addingTimeInterval(2)
        perform(.listMove(step: 0))
        XCTAssertEqual(ui.markedRow, .project(ids.project))
    }

    /// Runde 2: Create öffnet die Projekt-Auswahl, mit dem Projekt der
    /// markierten Zeile vorausgewählt.
    func testFilterAndNewChatPickerForMarkedProject() {
        let ids = makeRows()
        perform(.moveInContent(.left))
        perform(.listFilter(step: 1))
        XCTAssertEqual(window.commands.last, .sidebarFilter(step: 1))
        perform(.listMove(step: 1))
        perform(.newChat)
        XCTAssertEqual(window.commands.last, .showNewChatPicker(preferredProjectID: ids.project))
        XCTAssertEqual(ui.area, .content)
    }

    /// Im Inhalt: aktuelles Projekt (das setzt die Ansicht ein). Ist die
    /// Auswahl offen, gehört der Controller ihr (Zusammenhang `modal`):
    /// Pfeile, Return, Escape über die Brücke, R2 diktiert ins Suchfeld.
    func testNewChatPickerMakesContextModal() {
        perform(.newChat)
        XCTAssertEqual(window.commands.last, .showNewChatPicker(preferredProjectID: nil))
        XCTAssertEqual(context, .modal)
        dispatcher.perform(ControllerBindingResolver.action(
            for: .move(.down, source: .leftStick, isRepeat: false), in: .modal)!, in: .modal)
        dispatcher.perform(ControllerBindingResolver.action(for: .press(.cross), in: .modal)!, in: .modal)
        dispatcher.perform(ControllerBindingResolver.action(for: .tap(.circle), in: .modal)!, in: .modal)
        XCTAssertEqual(environment.bridgeKeys, [.down, .returnKey, .escape])
        perform(.dictationToggle)
        XCTAssertEqual(dictation.started, [.frontApp], "Diktat ins Suchfeld, wie beim Hotkey")
    }

    func testNewChatPickerUnavailableIsRejected() {
        window.failing = [String(describing: AgentChatsCommand.showNewChatPicker(preferredProjectID: nil))]
        perform(.newChat)
        XCTAssertEqual(haptics, [.rejected])
    }

    // MARK: - Nachbar-Chat in der Einzelansicht (Runde 2)

    /// Workspace mit A und B, Projekt mit A, B und C.
    private func makeChatRows() -> (a: UUID, b: UUID, c: UUID, workspace: UUID, project: UUID?) {
        let workspace = UUID(), project = UUID(), a = UUID(), b = UUID(), c = UUID()
        window.rows = [
            AgentChatsListRow(row: .workspace(workspace)),
            AgentChatsListRow(row: .workspaceChat(session: a, workspace: workspace), projectID: project),
            AgentChatsListRow(row: .workspaceChat(session: b, workspace: workspace), projectID: project),
            AgentChatsListRow(row: .project(project), projectID: project),
            AgentChatsListRow(row: .chat(a), projectID: project),
            AgentChatsListRow(row: .chat(b), projectID: project),
            AgentChatsListRow(row: .chat(c), projectID: project),
        ]
        return (a, b, c, workspace, project)
    }

    func testAdjacentChatWalksTheListWithoutEnteringIt() {
        let ids = makeChatRows()
        window.selected = ids.a
        perform(.adjacentChat(step: 1))
        XCTAssertEqual(window.selected, ids.b)
        XCTAssertEqual(ui.area, .content, "Die Liste wird nicht betreten")
        XCTAssertNil(ui.markedRow)
        // Jeder Chat zählt einmal: nach B (Workspace) kommt C (Projekt).
        perform(.adjacentChat(step: 1))
        XCTAssertEqual(window.selected, ids.c)
        perform(.adjacentChat(step: 1))
        XCTAssertEqual(window.selected, ids.c)
        XCTAssertEqual(haptics, [.rejected], "am Rand kein Umlauf")
    }

    /// Ausgangspunkt ist die Workspace-Zeile des Chats, wenn es sie gibt.
    func testAdjacentChatStartsAtWorkspaceRow() {
        let ids = makeChatRows()
        window.selected = ids.b
        perform(.adjacentChat(step: -1))
        XCTAssertEqual(window.selected, ids.a)
        perform(.adjacentChat(step: -1))
        XCTAssertEqual(haptics, [.rejected], "über A im Workspace steht nur die Kopfzeile")
    }

    /// Der aktuelle Chat steht nicht (mehr) in der Liste: vorn bzw. hinten beginnen.
    func testAdjacentChatFromMissingChatStartsAtEdge() {
        let ids = makeChatRows()
        perform(.adjacentChat(step: 1))
        XCTAssertEqual(window.selected, ids.a)
        window.selected = UUID()
        perform(.adjacentChat(step: -1))
        XCTAssertEqual(window.selected, ids.c)
        XCTAssertEqual(haptics, [])
    }

    func testAdjacentChatWithEmptyListIsRejected() {
        perform(.adjacentChat(step: 1))
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Runde 2: Viereck halten in der Liste schließt die Zeile wie ihr „−“/„×“;
    /// die Markierung bleibt in der Liste und rückt auf den Nachbarn.
    func testHoldSquareClosesMarkedRow() {
        let ids = makeChatRows()
        window.selected = ids.c
        perform(.moveInContent(.left))
        perform(.listMove(step: -4))
        XCTAssertEqual(ui.markedRow, .workspaceChat(session: ids.b, workspace: ids.workspace))
        window.rows.remove(at: 2)
        perform(.listCloseRow)
        XCTAssertEqual(window.commands.last, .closeListRow(.workspaceChat(session: ids.b, workspace: ids.workspace)))
        XCTAssertEqual(ui.area, .list)
        XCTAssertEqual(ui.markedRow, .project(ids.project ?? UUID()), "Nachbar an derselben Stelle")
    }

    func testHoldSquareOnHeaderIsRejected() {
        let ids = makeChatRows()
        window.selected = ids.c
        perform(.moveInContent(.left))
        perform(.listMove(step: -10))
        XCTAssertEqual(ui.markedRow, .workspace(ids.workspace))
        perform(.listCloseRow)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertFalse(window.commands.contains { if case .closeListRow = $0 { return true }; return false })
    }

    /// Runde 2: R3 in der Liste startet die markierte Zeile, still, wenn nichts zu starten ist.
    func testR3InListStartsMarkedChatSilently() {
        let ids = makeChatRows()
        window.selected = ids.a
        perform(.moveInContent(.left))
        window.failing = [String(describing: AgentChatsCommand.startChat(ids.a))]
        perform(.listStartRow)
        XCTAssertEqual(window.commands.last, .startChat(ids.a))
        XCTAssertEqual(haptics, [], "laufender Chat: keine Vibration")
    }

    // MARK: - Eingabe leeren (Runde 3)

    func testClearInputGoesToSelectedChatWithConfirmation() {
        perform(.holdProgress(.r3, duration: 0.6))
        perform(.chatClearInput)
        XCTAssertEqual(terminals.clearedSessions, [window.selected!])
        XCTAssertEqual(haptics, [.inputCleared])
    }

    func testClearInputThatFailsIsRejected() {
        terminals.clearResult = false
        perform(.holdProgress(.r3, duration: 0.6))
        perform(.chatClearInput)
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Befund 6 nach Runde 3: Das Ziel steht beim Haltebeginn fest. Wechselt
    /// der Chat während des Haltens, wird nichts geleert.
    func testClearInputIsBoundToChatAtHoldBegin() {
        let first = window.selected!
        perform(.holdProgress(.r3, duration: 0.6))
        window.selected = UUID()
        setTerminal(status: .idle)
        perform(.chatClearInput)
        XCTAssertEqual(terminals.clearedSessions, [], "weder der alte noch der neue Chat")
        XCTAssertEqual(haptics, [.rejected])

        // Zurück auf dem ersten Chat und neu gehalten: geleert wird er.
        window.selected = first
        haptics = []
        perform(.holdProgress(.r3, duration: 0.6))
        perform(.chatClearInput)
        XCTAssertEqual(terminals.clearedSessions, [first])
        XCTAssertEqual(haptics, [.inputCleared])
    }

    func testClearInputWithoutHoldBeginOrAfterCancelIsRejected() {
        perform(.chatClearInput)
        perform(.holdProgress(.r3, duration: 0.6))
        perform(.holdProgressCancelled(.r3))
        perform(.chatClearInput)
        XCTAssertEqual(terminals.clearedSessions, [])
        XCTAssertEqual(haptics, [.rejected, .rejected])
    }

    func testLeaveListClearsMarker() {
        _ = makeRows()
        perform(.moveInContent(.left))
        perform(.leaveList)
        XCTAssertEqual(ui.area, .content)
        XCTAssertNil(ui.markedRow)
    }

    // MARK: - Einzelansicht: Stick hoch/runter markiert in der Liste (Runde 3)

    /// Startpunkt ist der aktuelle Chat, die Markierung rückt sofort einen
    /// Schritt; der offene Chat bleibt, nichts wird ausgewählt.
    func testEnterListWithStepMarksNeighborWithoutSwitching() {
        let ids = makeChatRows()
        window.selected = ids.c
        perform(.enterList(step: -1))
        XCTAssertEqual(ui.area, .list)
        XCTAssertEqual(ui.markedRow, .chat(ids.b))
        XCTAssertEqual(window.selected, ids.c, "der offene Chat bleibt")
        XCTAssertFalse(window.commands.contains { if case .selectSession = $0 { return true }; return false })
        XCTAssertEqual(haptics, [])
    }

    /// Steht der Chat in einem Workspace, beginnt die Markierung dort (Runde 2).
    func testEnterListWithStepStartsAtWorkspaceRow() {
        let ids = makeChatRows()
        window.selected = ids.a
        perform(.enterList(step: 1))
        XCTAssertEqual(ui.markedRow, .workspaceChat(session: ids.b, workspace: ids.workspace))
        XCTAssertEqual(window.selected, ids.a)
    }

    /// Am Rand bleibt die Markierung stehen, ohne „geht nicht“.
    func testEnterListWithStepStaysAtEdge() {
        let ids = makeChatRows()
        window.selected = ids.c
        perform(.enterList(step: 1))
        XCTAssertEqual(ui.markedRow, .chat(ids.c))
        XCTAssertEqual(haptics, [])
    }

    /// Steht der aktuelle Chat nicht in der Liste (Filter), bleibt die
    /// Markierung auf der ersten Zeile statt von dort weiterzurücken.
    func testEnterListWithStepFromMissingChatMarksFirstRow() {
        let ids = makeChatRows()
        window.selected = UUID()
        perform(.enterList(step: 1))
        XCTAssertEqual(ui.markedRow, .workspace(ids.workspace))
    }

    func testEnterListWithStepAndEmptyListIsRejected() {
        perform(.enterList(step: 1))
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertEqual(ui.area, .content)
    }

    /// Ganze Kette über die Belegung: Stick runter im Chat betritt die Liste,
    /// gehaltene Wiederholungen kommen dort als `listMove` an, Kreis führt
    /// ohne Wechsel zurück in den bisherigen Chat.
    func testStickDownInSingleChatThenHoldThenCircleKeepsChat() {
        let ids = makeChatRows()
        window.selected = ids.a
        setTerminal(status: .idle)
        let resolve = { [unowned self] (gesture: ControllerGesture) in
            let current = context
            if let action = ControllerBindingResolver.action(for: gesture, in: current) {
                dispatcher.perform(action, in: current)
            }
        }
        resolve(.move(.down, source: .leftStick, isRepeat: false))
        XCTAssertEqual(context, .list)
        XCTAssertEqual(ui.markedRow, .workspaceChat(session: ids.b, workspace: ids.workspace))
        resolve(.move(.down, source: .leftStick, isRepeat: true))
        XCTAssertEqual(ui.markedRow, .project(ids.project ?? UUID()))
        resolve(.tap(.circle))
        XCTAssertEqual(ui.area, .content)
        XCTAssertNil(ui.markedRow)
        XCTAssertEqual(window.selected, ids.a, "Kreis wechselt nicht")
        XCTAssertFalse(window.commands.contains { command in
            switch command {
            case .selectSession, .selectWorkspaceChat, .activateWorkspace, .openProjectAsWorkspace: return true
            default: return false
            }
        })
    }

    /// Stick rechts in der Liste: ebenfalls zurück ohne Wechsel.
    func testStickRightLeavesListWithoutSwitching() {
        let ids = makeChatRows()
        window.selected = ids.c
        perform(.enterList(step: -1))
        let action = ControllerBindingResolver.action(for: .move(.right, source: .leftStick, isRepeat: false), in: context)
        XCTAssertEqual(action, .leaveList)
        perform(.leaveList)
        XCTAssertEqual(window.selected, ids.c)
        XCTAssertEqual(ui.area, .content)
    }

    /// Kreuz auf einer Workspace-Chat-Zeile öffnet sie wie ihr Klick: Der
    /// Befehl nennt den Workspace der Zeile, damit das Fenster hineinwechselt.
    func testActivatingWorkspaceChatRowNamesItsWorkspace() {
        let ids = makeChatRows()
        window.selected = ids.c
        perform(.enterList(step: -5))
        XCTAssertEqual(ui.markedRow, .workspaceChat(session: ids.a, workspace: ids.workspace))
        perform(.listActivate)
        XCTAssertEqual(window.commands.last, .selectWorkspaceChat(ids.a, workspaceID: ids.workspace))
        XCTAssertEqual(window.selected, ids.a)
        XCTAssertEqual(ui.area, .content, "Kreuz geht sofort in den Inhalt")
    }

    func testActivatingWorkspaceChatRowThatFailsIsRejected() {
        let ids = makeChatRows()
        window.selected = ids.a
        perform(.enterList(step: 0))
        window.failing = [String(describing: AgentChatsCommand.selectWorkspaceChat(ids.a, workspaceID: ids.workspace))]
        perform(.listActivate)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertEqual(ui.area, .list, "bleibt in der Liste")
    }

    // MARK: - Ctrl+Tab der Tastatur

    /// Ein per Tastatur geöffneter Umschalter gehört der Tastatur: Die erste
    /// Controller-Eingabe schließt ihn.
    func testKeyboardSwitcherIsCancelledByControllerInput() {
        window.isSwitcherOpen = true
        guard case .chat = context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(window.commands, [], "Der Schnappschuss allein schließt nichts")
        perform(.lastChat)
        XCTAssertEqual(window.commands, [.switcherCancel, .lastChat])
    }

    func testRefreshLeavesKeyboardSwitcherAlone() {
        window.isSwitcherOpen = true
        dispatcher.refreshContext()
        XCTAssertEqual(window.commands, [])
        XCTAssertTrue(window.isSwitcherOpen)
    }

    // MARK: - Diktat

    func testDictationInChatTargetsSelectedChat() {
        dispatcher.titleForSession = { _ in "Mein Chat" }
        perform(.dictationToggle)
        XCTAssertEqual(dictation.labels, ["Mein Chat"], "Die Pill zeigt das Ziel")
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: window.selected!)])
        XCTAssertEqual(haptics, [.recordingStarted])
        // Runde 5: an einen Chat gebunden, also mit Navigation.
        XCTAssertEqual(context, .recording(
            phase: .recording, targetIsChat: true, navigation: .init(area: .content, gridActive: false)))
    }

    func testSecondToggleStopsWithoutSending() {
        perform(.dictationToggle)
        perform(.dictationToggle)
        XCTAssertEqual(dictation.stopped, [false])
        XCTAssertEqual(haptics, [.recordingStarted, .recordingStopped])
    }

    func testStopAndSubmit() {
        perform(.dictationToggle)
        perform(.dictationStopAndSubmit)
        XCTAssertEqual(dictation.stopped, [true])
    }

    /// In ein Textfeld, einen Dialog oder ein anderes Programm geht das
    /// Diktat wie beim Hotkey — und wird nie gesendet.
    func testDictationOutsideChatGoesToFrontApp() {
        window.hasSheet = true
        perform(.dictationToggle)
        XCTAssertEqual(dictation.started, [.frontApp])
        XCTAssertEqual(context, .recording(phase: .recording, targetIsChat: false))
        dispatcher.perform(.dictationStopAndSubmit, in: context)
        XCTAssertEqual(dictation.stopped, [false], "Return geht nie an fremde Felder")
    }

    func testDictationIntoEndedChatFallsBackToFrontApp() {
        setTerminal(status: .idle, running: false)
        perform(.dictationToggle)
        XCTAssertEqual(dictation.started, [.frontApp])
    }

    func testToggleWhileTranscribingIsRejected() {
        dictation.phase = .transcribing
        dispatcher.perform(.dictationToggle, in: .chat(ControllerChatState(status: .idle, profile: .claude)))
        XCTAssertEqual(dictation.started, [])
        XCTAssertEqual(haptics, [.rejected])
    }

    func testCancelAndOutputMode() {
        perform(.dictationToggle)
        perform(.outputMode(step: 1))
        perform(.dictationCancel)
        XCTAssertEqual(dictation.modeSteps, [1])
        XCTAssertEqual(dictation.cancelCount, 1)
    }

    // MARK: - Menü

    func testMenuOpensMovesAndCloses() {
        perform(.menuToggle)
        XCTAssertEqual(context, .menu(dialogOpen: false))
        XCTAssertEqual(ui.menu?.selected, .continueWork)
        perform(.menuMove(step: 1))
        XCTAssertEqual(ui.menu?.selected, .commands)
        perform(.menuBack)
        XCTAssertNil(ui.menu, "Kreis auf der ersten Ebene schließt")
        perform(.menuToggle)
        perform(.menuToggle)
        XCTAssertNil(ui.menu)
    }

    func testContinueWritesIntoTheChat() {
        perform(.menuToggle)
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.count, 1)
        XCTAssertEqual(terminals.texts.first?.submit, true)
        XCTAssertNil(ui.menu, "Nach der Wahl schließt das Menü")
    }

    /// Runde 2: Befehle als zweite Ebene. „/“ bleibt ungesendet, feste
    /// Befehle werden gesendet; Kreis geht zurück.
    func testCommandsSubmenu() {
        perform(.menuToggle)
        ui.menu?.select(.commands)
        perform(.menuActivate)
        XCTAssertNotNil(ui.menu?.submenu, "zweite Ebene offen")
        perform(.menuBack)
        XCTAssertNil(ui.menu?.submenu)
        XCTAssertNotNil(ui.menu)
        perform(.menuActivate)
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.last?.text, "/")
        XCTAssertEqual(terminals.texts.last?.submit, false)

        perform(.menuToggle)
        ui.menu?.select(.commands)
        perform(.menuActivate)
        perform(.menuMove(step: 1))
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.last?.text, "/model")
        XCTAssertEqual(terminals.texts.last?.submit, true)
    }

    /// Befund 1a nach Runde 3: Befehle, die eine Liste öffnen („/“, `/model`
    /// …), setzen den Merker „Auswahl offen“ am Chat des Menüs; andere nicht.
    func testListOpeningCommandsMarkTheChoiceList() {
        let chatID = window.selected!
        func send(commandAt index: Int) {
            perform(.menuToggle)
            ui.menu?.select(.commands)
            perform(.menuActivate)
            perform(.menuMove(step: index))
            perform(.menuActivate)
        }
        send(commandAt: 0)
        XCTAssertEqual(terminals.texts.last?.text, "/")
        XCTAssertEqual(terminals.choiceListsOpened, [chatID])
        send(commandAt: 1)
        XCTAssertEqual(terminals.texts.last?.text, "/model")
        XCTAssertEqual(terminals.choiceListsOpened, [chatID, chatID])
        let clearIndex = ControllerSlashCommands.claude.firstIndex(of: "/clear")!
        send(commandAt: clearIndex)
        XCTAssertEqual(terminals.texts.last?.text, "/clear")
        XCTAssertEqual(terminals.choiceListsOpened.count, 2, "/clear öffnet keine Liste")
    }

    /// Nachreview: An einen arbeitenden Claude-Chat gesendet, setzt `/model`
    /// den Merker nicht; bei Codex schon.
    func testListOpeningCommandToWorkingClaudeSetsNoMarker() {
        func sendModel() {
            perform(.menuToggle)
            ui.menu?.select(.commands)
            perform(.menuActivate)
            perform(.menuMove(step: 1))
            perform(.menuActivate)
        }
        setTerminal(status: .working)
        sendModel()
        XCTAssertEqual(terminals.texts.last?.text, "/model")
        XCTAssertEqual(terminals.choiceListsOpened, [])

        setTerminal(status: .working, profile: .codex)
        sendModel()
        XCTAssertEqual(terminals.texts.last?.text, "/model")
        XCTAssertEqual(terminals.choiceListsOpened, [window.selected!])
    }

    func testCommandsRejectedWithDraft() {
        setTerminal(status: .idle, draft: true)
        perform(.menuToggle)
        ui.menu?.select(.commands)
        perform(.menuActivate)
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.count, 0, "nie an einen Entwurf hängen")
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Bei offener Rückfrage läuft kein Text in den Chat.
    func testMenuSkipsInputItemsWhileQuestionIsOpen() {
        setTerminal(status: .awaitingInput, statusSince: clock.addingTimeInterval(-5))
        perform(.menuToggle)
        XCTAssertEqual(ui.menu?.selected, .rename, "nichts, was in die Rückfrage schreibt")
        XCTAssertTrue(ui.menuDialogOpen)
        ui.menu?.select(.cycleMode)
        XCTAssertEqual(ui.menu?.selected, .rename, "Shift+Tab ist aus")
        XCTAssertEqual(terminals.keys, [], "Shift+Tab nie in eine Rückfrage")
    }

    /// Review-Befund 2: Eingaben aus dem Menü gehen an den Chat, für den es
    /// geöffnet wurde. Hat sich die Auswahl inzwischen geändert, geht nichts
    /// raus, es gibt „geht nicht“, und das Menü ist zu.
    func testMenuInputIsRejectedWhenSelectionChanged() {
        let opened = window.selected!
        perform(.menuToggle)
        XCTAssertEqual(ui.menu?.setup.sessionID, opened)
        let other = UUID()
        window.selected = other
        setTerminal(status: .idle)
        perform(.menuActivate)                 // „Weiter“
        XCTAssertEqual(terminals.texts.count, 0)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertNil(ui.menu)

        window.selected = opened
        perform(.menuToggle)
        ui.menu?.select(.cycleMode)
        window.selected = other
        perform(.menuActivate)
        XCTAssertEqual(terminals.keys, [], "kein Shift+Tab an den anderen Chat")

        window.selected = opened
        perform(.menuToggle)
        ui.menu?.select(.commands)
        perform(.menuActivate)
        window.selected = other
        perform(.menuMove(step: 1))
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.count, 0, "kein Befehl an den anderen Chat")
        XCTAssertEqual(haptics, [.rejected, .rejected, .rejected])
    }

    /// Unverändert: Mit derselben Auswahl geht „Modus wechseln“ an den Chat des Menüs.
    func testCycleModeGoesToMenuChat() {
        perform(.menuToggle)
        ui.menu?.select(.cycleMode)
        perform(.menuActivate)
        XCTAssertEqual(terminals.keys, [.backTab])
    }

    /// „Weiter“ würde an einen Entwurf angehängt und beides gesendet.
    func testContinueIsRejectedWithDraft() {
        setTerminal(status: .idle, draft: true)
        perform(.menuToggle)
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.count, 0)
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Runde 2: Aktionen am Chat — dieselben Wege wie das Kontextmenü.
    func testChatActionsGoToTheWindow() {
        let session = window.selected!
        window.chatInfo?.canFork = true
        for item in [ControllerMenuItem.rename, .fork, .pin, .archive, .closeChat] {
            perform(.menuToggle)
            ui.menu?.select(item)
            XCTAssertEqual(ui.menu?.selected, item)
            perform(.menuActivate)
        }
        XCTAssertEqual(window.commands, [
            .renameChat(session), .forkChat(session), .togglePin(session), .archiveChat(session),
            .closeListRow(.chat(session)),
        ])
    }

    /// In der Liste wirken die Aktionen auf die markierte Chat-Zeile;
    /// Eingaben in den Chat sind dann aus.
    func testMenuInListTargetsMarkedRow() {
        let ids = makeRows()
        perform(.moveInContent(.left))
        perform(.listMove(step: 2))
        XCTAssertEqual(ui.markedRow, .chat(ids.chat))
        perform(.menuToggle)
        XCTAssertEqual(ui.menu?.setup.sessionID, ids.chat)
        XCTAssertFalse(ui.menu?.setup.acceptsInput ?? true)
        ui.menu?.select(.closeChat)
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .closeListRow(.chat(ids.chat)))
    }

    func testAccountsSubmenuMovesChat() {
        let session = window.selected!
        window.chatInfo?.accounts = [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "work", label: "work", isCurrent: false, isLoggedIn: true),
            ControllerAccountChoice(kind: .gpt, name: "team", label: "team", isCurrent: false, isLoggedIn: true),
        ]
        perform(.menuToggle)
        ui.menu?.select(.switchAccount)
        perform(.menuActivate)
        // Runde 5: Die Markierung beginnt auf dem eigenen Konto; Kreuz dort
        // geht nicht, der erste Schritt führt zum nächsten wählbaren.
        let commandsBefore = window.commands.count
        perform(.menuActivate)
        XCTAssertEqual(window.commands.count, commandsBefore)
        perform(.menuMove(step: 1))
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .moveChatToAccount(session, profileName: "work"))
        XCTAssertNil(ui.menu)

        perform(.menuToggle)
        ui.menu?.select(.switchAccount)
        perform(.menuActivate)
        perform(.menuMove(step: 2))
        perform(.menuActivate)
        XCTAssertEqual(window.commands.last, .setGPTAccount(session, profileName: "team"))
    }

    /// In einer Shell wäre der diktierte Text ein Befehl: Kreuz beendet dort
    /// nur, sendet nie.
    func testStopAndSubmitOnlyForClaudeAndCodex() {
        setTerminal(status: .idle, profile: .shell)
        perform(.dictationToggle)
        XCTAssertEqual(context, .recording(
            phase: .recording, targetIsChat: false, navigation: .init(area: .content, gridActive: false)))
        dispatcher.perform(.dictationStopAndSubmit, in: context)
        XCTAssertEqual(dictation.stopped, [false])
    }

    func testCloseControllerUIClosesMenuListAndRing() {
        window.rows = [AgentChatsListRow(row: .chat(window.selected!))]
        perform(.menuToggle)
        perform(.holdProgress(.circle, duration: 0.4))
        dispatcher.closeControllerUI()
        XCTAssertNil(ui.menu)
        XCTAssertNil(ui.holdProgress)
        XCTAssertEqual(ui.area, .content)
    }

    /// Ein Tastatur-Umschalter bleibt offen, solange der Controller nichts ausführt.
    func testCloseControllerUILeavesKeyboardSwitcher() {
        window.isSwitcherOpen = true
        dispatcher.closeControllerUI()
        XCTAssertEqual(window.commands, [])
    }

    func testMenuSettingsAndPause() {
        var pauses = 0
        dispatcher.togglePause = { pauses += 1 }
        for item in [ControllerMenuItem.clipboardHistory, .showBindings, .pause] {
            perform(.menuToggle)
            ui.menu?.select(item)
            perform(.menuActivate)
        }
        XCTAssertEqual(environment.clipboardToggles, 1, "Verlauf aus dem Menü")
        XCTAssertNil(ui.menu)
        XCTAssertEqual(environment.openedSettings, 1)
        XCTAssertEqual(pauses, 1)
    }

    // MARK: - Verlauf, Brücke, Halten

    func testClipboardAndBridge() {
        perform(.clipboardToggle)
        perform(.clipboard(.paste))
        perform(.bridgeKey(.returnKey))
        perform(.bringAppToFront)
        XCTAssertEqual(environment.clipboardToggles, 1)
        XCTAssertEqual(environment.clipboardCommands, [.paste])
        XCTAssertEqual(environment.bridgeKeys, [.returnKey])
        XCTAssertEqual(environment.broughtToFront, 1)
    }

    func testHoldProgressAppearsAndClears() {
        perform(.holdProgress(.circle, duration: 0.4))
        XCTAssertEqual(ui.holdProgress, ControllerHoldProgress(button: .circle, startedAt: clock, duration: 0.4))
        perform(.holdProgressCancelled(.circle))
        XCTAssertNil(ui.holdProgress)

        perform(.holdProgress(.circle, duration: 0.4))
        perform(.chatInterrupt)
        XCTAssertNil(ui.holdProgress, "Nach der Aktion ist der Ring weg")
    }

    func testContextIsPublishedForTheLegend() {
        setTerminal(status: .working)
        dispatcher.refreshContext()
        guard case let .chat(state) = ui.context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(state.status, .working)
    }
}
