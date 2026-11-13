import Foundation
import XCTest
@testable import WhisperM8

/// Ausführer der Controller-Insel (Runde 4): L1 „Schreiben“, R1
/// „Schnellbefehle“, L2 „Wohin“ — mit echtem Erkenner und echter Belegung,
/// wo es um Abläufe geht.
@MainActor
final class ControllerActionDispatcherIslandTests: XCTestCase {
    private var window: ControllerWindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: ControllerTerminalSpy!
    private var dictation: ControllerDictationSpy!
    private var island: ControllerIslandSpy!
    private var ui: ControllerUIModel!
    private var dispatcher: ControllerActionDispatcher!
    private var haptics: [ControllerHapticPattern] = []
    private var pauses = 0
    private var recognizer = ControllerGestureRecognizer()
    private var chats: [UUID] = []

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        dictation = ControllerDictationSpy()
        island = ControllerIslandSpy()
        ui = ControllerUIModel()
        haptics = []
        pauses = 0
        recognizer = ControllerGestureRecognizer()
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation, environment: ControllerEnvironmentSpy(),
            ui: ui, island: island, now: { Date(timeIntervalSince1970: 1_000) })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        dispatcher.togglePause = { [unowned self] in pauses += 1 }
        dispatcher.titleForSession = { _ in "Controller Insel" }
        dispatcher.islandStatus = { _ in .working }
        dispatcher.islandChatRows = { order, current in
            order.map { ControllerIslandChatRow(
                id: $0, title: "Chat", project: "WhisperM8", status: .idle, detail: "", isCurrent: $0 == current) }
        }
        chats = [UUID(), UUID(), UUID(), UUID()]
        window.selected = chats[1]
        window.rows = chats.map { AgentChatsListRow(row: .chat($0)) }
        for chat in chats { setTerminal(chat, status: .idle) }
    }

    private func setTerminal(
        _ sessionID: UUID, status: AgentSessionRuntimeStatus?, profile: ControllerChatState.Profile = .claude,
        draft: Bool = false, lastEnter: Date? = nil
    ) {
        terminals.states[sessionID] = ControllerTerminalState(
            isRunning: true, profile: profile, status: status, statusSince: nil,
            draftSuspected: draft, lastEnterAt: lastEnter, lastEscapeAt: nil)
    }

    private let now = Date(timeIntervalSince1970: 1_000)

    private var context: ControllerContext {
        ControllerContextResolver.context(for: dispatcher.snapshot())
    }

    /// Eingabe durch Erkenner, Belegung und Ausführer, wie der Manager es tut
    /// (die Pause schaltet dort der Manager, hier `togglePause`).
    @discardableResult
    private func feed(_ event: ControllerInputEvent, at time: TimeInterval) -> [ControllerAction] {
        run(recognizer.handle(event, at: time))
    }

    @discardableResult
    private func tick(_ time: TimeInterval) -> [ControllerAction] {
        run(recognizer.tick(at: time))
    }

    private func run(_ gestures: [ControllerGesture]) -> [ControllerAction] {
        gestures.compactMap { gesture in
            let current = context
            guard let action = ControllerBindingResolver.action(for: gesture, in: current) else { return nil }
            dispatcher.perform(action, in: current)
            return action
        }
    }

    private func press(_ button: ControllerButton, at time: TimeInterval) {
        if button.isTrigger {
            feed(.trigger(button, value: 1), at: time)
        } else {
            feed(.button(button, pressed: true), at: time)
        }
    }

    private func release(_ button: ControllerButton, at time: TimeInterval) {
        if button.isTrigger {
            feed(.trigger(button, value: 0), at: time)
        } else {
            feed(.button(button, pressed: false), at: time)
        }
    }

    private var whereTo: ControllerWhereToState? { island.last?.whereTo }

    // MARK: - Tippen

    func testTapsSwitchChatsWithoutAnIsland() {
        press(.r1, at: 0)
        release(.r1, at: 0.1)
        XCTAssertEqual(window.selected, chats[2], "R1 getippt: nächster Chat")
        press(.l1, at: 1)
        release(.l1, at: 1.1)
        XCTAssertEqual(window.selected, chats[1], "L1 getippt: voriger Chat")
        XCTAssertTrue(island.shown.isEmpty)
    }

    /// Halten lässt keine Chats mehr durchlaufen.
    func testHoldingL1DoesNotCycleChats() {
        press(.l1, at: 0)
        tick(0.3)
        tick(2)
        release(.l1, at: 2.1)
        XCTAssertEqual(window.selected, chats[1])
        XCTAssertEqual(island.shown.first?.layer, .writing)
        XCTAssertFalse(island.isVisible)
    }

    // MARK: - L2 Wohin

    /// Die Liste steht sofort da (keine Hinweiszeile); ohne vorigen Ort
    /// steht die Markierung auf dem aktuellen Chat. Eine Bewegung, dann
    /// wechselt Loslassen.
    func testWhereToShowsListAtOnceAndSwitchesOnRelease() {
        press(.l2, at: 0)
        XCTAssertTrue(island.shown.isEmpty, "die Insel kommt erst nach 0,3 s")
        tick(0.3)
        XCTAssertEqual(island.screens.last, 7, "Bildschirm des Agent-Chats-Fensters")
        XCTAssertEqual(whereTo?.tab, .chats, "Einzelansicht: Reiter Chats")
        XCTAssertEqual(whereTo?.chats.selected?.id, chats[1], "ohne vorigen Ort: der aktuelle")
        XCTAssertEqual(island.last?.target, ControllerIslandTarget(title: "Controller Insel", status: .working))

        feed(.stick(.left, x: 0, y: -1), at: 0.5)
        XCTAssertEqual(whereTo?.chats.selected?.id, chats[2])
        feed(.stick(.left, x: 0, y: 0), at: 0.6)
        release(.l2, at: 0.8)
        XCTAssertEqual(window.selected, chats[2], "Loslassen wechselt")
        XCTAssertFalse(island.isVisible)
    }

    /// Insel-Paket: Halten zeigt die Markierung auf dem aktuellen Chat;
    /// Loslassen ohne Bewegung tut nichts. Der vorige Chat ist einen Schritt
    /// entfernt und geht dann denselben Weg wie Tippen.
    func testHoldAndReleaseWithoutMovementStays() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(.l2, at: 0)
        tick(0.3)
        XCTAssertEqual(whereTo?.chats.selected?.id, chats[1], "Markierung auf dem aktuellen Chat")
        XCTAssertEqual(whereTo?.previous, .chat(chats[3]), "„vorher“ am vorigen Chat")
        release(.l2, at: 1)
        XCTAssertEqual(window.selected, chats[1])
        XCTAssertFalse(window.commands.contains(.lastChat))
        XCTAssertTrue(haptics.isEmpty)
    }

    /// Der vorige Chat steht auch dann in der Liste, wenn die Seitenleiste
    /// ihn gerade nicht zeigt (Filter, Suche, eingeklappt) — gleich unter dem
    /// aktuellen, ein Schritt nach unten führt dorthin über `lastChat`.
    func testPreviousChatOutsideTheSidebarIsOneStepAway() {
        let hidden = UUID()
        setTerminal(hidden, status: .idle)
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: hidden)
        press(.l2, at: 0)
        tick(0.3)
        XCTAssertEqual(whereTo?.chats.rows.map(\.id), [chats[0], chats[1], hidden, chats[2], chats[3]],
                       "gleich hinter dem aktuellen")
        press(.dpadDown, at: 0.4)
        release(.dpadDown, at: 0.45)
        XCTAssertEqual(whereTo?.chats.selected?.id, hidden)
        release(.l2, at: 1)
        XCTAssertEqual(window.commands.last, .lastChat)
        XCTAssertEqual(window.selected, hidden)
    }

    /// Bewegt auf den vorigen Workspace: derselbe Weg wie Tippen; scheitert
    /// er (Workspace gehört einem anderen Fenster), vibriert es „geht nicht“
    /// und kein Fenster kommt nach vorn.
    func testReleaseOnPreviousWorkspaceGoesBackAndRejectsQuietly() {
        let workspaces = [UUID(), UUID()]
        window.workspaces = workspaces.enumerated().map { index, id in
            ControllerWorkspaceChoice(id: id, name: "W\(index)", colorHex: "#888888", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: index == 0)
        }
        window.isGridActive = true
        window.backTarget = ControllerBackTarget(kind: .workspace, title: "W1", id: workspaces[1])
        window.failing = [String(describing: AgentChatsCommand.lastChat)]
        press(.l2, at: 0)
        tick(0.3)
        press(.dpadDown, at: 0.4)
        release(.dpadDown, at: 0.45)
        release(.l2, at: 1)
        XCTAssertEqual(window.commands.last, .lastChat)
        XCTAssertFalse(window.commands.contains(.activateWorkspace(workspaces[1])))
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Hat beim Loslassen etwas anderes die Eingaben (Sheet, Dialog,
    /// Aufnahme), schließt die Insel nur.
    func testReleaseOutsideTheChatOnlyClosesTheIsland() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(.l2, at: 0)
        tick(0.3)
        window.hasSheet = true
        release(.l2, at: 1)
        XCTAssertEqual(window.selected, chats[1])
        XCTAssertFalse(window.commands.contains(.lastChat))
        XCTAssertFalse(island.isVisible)
    }

    /// Kreis bricht ab, auch nach einer Bewegung.
    func testCircleCancelsTheSwitchAfterAMovement() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(.l2, at: 0)
        tick(0.3)
        press(.dpadDown, at: 0.4)
        release(.dpadDown, at: 0.45)
        press(.circle, at: 0.5)
        XCTAssertFalse(island.isVisible)
        release(.circle, at: 0.6)
        release(.l2, at: 0.8)
        XCTAssertEqual(window.selected, chats[1], "nichts passiert")
    }

    func testWhereToReleaseWithoutPreviousPlaceDoesNothing() {
        press(.l2, at: 0)
        tick(0.3)
        release(.l2, at: 1)
        XCTAssertEqual(window.selected, chats[1])
        XCTAssertFalse(window.commands.contains(.lastChat), "kein Tippen nach dem Halten")
        XCTAssertFalse(window.commands.contains { if case .selectSession = $0 { return true }; return false })
        XCTAssertTrue(haptics.isEmpty)
        XCTAssertFalse(island.isVisible)
    }

    /// Tippen bleibt „zurück zum vorigen Ort“.
    func testTapStillGoesBack() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(.l2, at: 0)
        release(.l2, at: 0.1)
        XCTAssertEqual(window.commands, [.lastChat])
        XCTAssertTrue(island.shown.isEmpty)
    }

    /// Kombination vor 0,3 s: Stick öffnet sofort die Insel und macht einen Schritt.
    func testEarlyStickOpensTheListImmediately() {
        press(.l2, at: 0)
        press(.dpadDown, at: 0.05)
        XCTAssertEqual(whereTo?.chats.selected?.id, chats[2])
        tick(0.3)
        XCTAssertEqual(island.shown.count, 2, "die Halte-Schwelle öffnet nicht noch einmal")
        press(.cross, at: 0.4)
        XCTAssertEqual(window.selected, chats[2], "Kreuz wechselt sofort")
        XCTAssertFalse(island.isVisible)
        release(.l2, at: 0.6)
        XCTAssertEqual(window.selected, chats[2], "das spätere Loslassen tut nichts")
    }

    func testWhereToInGridStartsOnWorkspacesAndSwitchesWorkspace() {
        let workspaces = [UUID(), UUID(), UUID()]
        window.workspaces = workspaces.enumerated().map { index, id in
            ControllerWorkspaceChoice(id: id, name: "W\(index)", colorHex: "#888888", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: index == 0)
        }
        window.isGridActive = true
        window.backTarget = ControllerBackTarget(kind: .workspace, title: "W1", id: workspaces[1])
        press(.l2, at: 0)
        tick(0.3)
        XCTAssertEqual(whereTo?.tab, .workspaces, "Raster: Reiter Workspaces & Projekte")
        XCTAssertEqual(whereTo?.workspaces.selected?.id, workspaces[0], "auf dem aktuellen Workspace")
        press(.dpadLeft, at: 0.5)
        release(.dpadLeft, at: 0.55)
        XCTAssertEqual(whereTo?.tab, .chats, "links: Reiter Chats")
        XCTAssertEqual(whereTo?.destination, .stay, "Chats: Markierung auf dem aktuellen")
        press(.dpadRight, at: 0.6)
        release(.dpadRight, at: 0.65)
        XCTAssertEqual(whereTo?.tab, .workspaces)
        XCTAssertEqual(whereTo?.destination, .stay, "zurück auf dem aktuellen Workspace")
        press(.dpadDown, at: 0.7)
        release(.dpadDown, at: 0.75)
        press(.dpadDown, at: 0.8)
        release(.dpadDown, at: 0.85)
        release(.l2, at: 1)
        XCTAssertEqual(window.commands.last, .switchToWorkspace(workspaces[2]), "still, ohne Konfliktdialog")
    }

    func testCircleCancelsAndTheIslandStaysClosed() {
        press(.l2, at: 0)
        press(.circle, at: 0.1)
        tick(0.3)
        XCTAssertTrue(island.shown.isEmpty, "Kreis vor 0,3 s: Insel kommt nicht mehr")
        press(.dpadDown, at: 0.4)
        XCTAssertTrue(island.shown.isEmpty)
        release(.l2, at: 0.5)
        XCTAssertEqual(window.selected, chats[1], "kein Wechsel, kein Tippen")
        XCTAssertFalse(window.commands.contains(.lastChat))
    }

    func testTriangleJumpsToNextWaitingChat() {
        press(.l2, at: 0)
        tick(0.3)
        press(.triangle, at: 0.4)
        XCTAssertEqual(window.commands.last, .nextWaitingChat)
        XCTAssertFalse(island.isVisible)

        window.failing = [String(describing: AgentChatsCommand.nextWaitingChat)]
        release(.triangle, at: 0.45)
        release(.l2, at: 0.5)
        press(.l2, at: 1)
        press(.triangle, at: 1.1)
        XCTAssertEqual(haptics, [.rejected], "kein wartender Chat")
    }

    func testR2SwitchesToTheMarkedChatAndDictates() {
        press(.l2, at: 0)
        press(.dpadDown, at: 0.1)
        press(.r2, at: 0.2)
        XCTAssertEqual(window.selected, chats[2])
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: chats[2])])
    }

    func testR2WithoutListDictatesIntoTheCurrentChat() {
        press(.l2, at: 0)
        tick(0.3)
        press(.r2, at: 0.4)
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: chats[1])])
        XCTAssertFalse(window.commands.contains { if case .selectSession = $0 { return true }; return false })
    }

    /// R2 auf einem anderen Workspace: „geht nicht“, die Insel bleibt. Steht
    /// die Markierung auf dem aktuellen Workspace, diktiert R2 in den Chat.
    func testR2OnAnotherWorkspaceIsRejected() {
        window.workspaces = [true, false].map {
            ControllerWorkspaceChoice(id: UUID(), name: "W", colorHex: "#888888", chatCount: 1,
                                      hasWaitingChat: false, isCurrent: $0)
        }
        window.isGridActive = true
        press(.l2, at: 0)
        press(.dpadDown, at: 0.1)
        press(.r2, at: 0.2)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertTrue(dictation.started.isEmpty)
        XCTAssertTrue(island.isVisible, "die Insel bleibt")
    }

    func testR2OnTheCurrentWorkspaceDictatesIntoTheCurrentChat() {
        window.workspaces = [ControllerWorkspaceChoice(
            id: UUID(), name: "W", colorHex: "#888888", chatCount: 1, hasWaitingChat: false, isCurrent: true)]
        window.isGridActive = true
        press(.l2, at: 0)
        tick(0.3)
        XCTAssertEqual(whereTo?.tab, .workspaces)
        press(.r2, at: 0.4)
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: chats[1])])
        XCTAssertFalse(haptics.contains(.rejected))
    }

    // MARK: - R1 Schnellbefehle

    /// Claude: R1 + Kreuz ist fest „Jetzt senden“ (Ctrl+X Ctrl+S, wie
    /// Ctrl+Enter), auch bei ruhendem Chat; nie mehr „Weiter“ als Text.
    func testQuickDrawCrossSendsNowInClaude() {
        press(.r1, at: 0)
        tick(0.3)
        guard case let .quickDraw(slots)? = island.last?.content else { return XCTFail("Raute erwartet") }
        XCTAssertEqual(slots.cross, .sendNow)
        XCTAssertTrue(slots.enabled.contains(.continueWork))
        press(.cross, at: 0.4)
        XCTAssertEqual(terminals.keys, [.sendNow])
        XCTAssertTrue(terminals.texts.isEmpty, "kein „Weiter“ im Feld")
        release(.cross, at: 0.42)
        release(.r1, at: 0.45)
        XCTAssertFalse(island.isVisible)
    }

    /// Codex (ruhend, leeres Feld): R1 + Kreuz schickt weiterhin „Weiter“.
    func testQuickDrawContinueSendsAndCloses() {
        setTerminal(chats[1], status: .idle, profile: .codex)
        press(.r1, at: 0)
        tick(0.3)
        guard case let .quickDraw(slots)? = island.last?.content else { return XCTFail("Raute erwartet") }
        XCTAssertTrue(slots.enabled.contains(.continueWork))
        press(.cross, at: 0.4)
        XCTAssertEqual(terminals.texts.map(\.text), [ControllerMenuText.continueWork])
        XCTAssertEqual(terminals.texts.map(\.submit), [true])
        guard case let .quickDraw(hit)? = island.shown.last?.content else { return XCTFail() }
        XCTAssertEqual(hit.hit, .continueWork, "kurz markiert vor dem Schließen")
        release(.r1, at: 0.45)
        XCTAssertFalse(island.isVisible)
        XCTAssertEqual(window.selected, chats[1], "kein Chatwechsel")
    }

    /// Quick Draw vor 0,3 s: führt aus, die Insel erscheint danach nicht mehr.
    func testQuickDrawBeforeTheIslandShowsKeepsItClosed() {
        press(.r1, at: 0)
        press(.triangle, at: 0.05)
        XCTAssertEqual(terminals.keys, [.backTab], "Modus wechseln = Shift+Tab")
        tick(0.3)
        XCTAssertTrue(island.shown.isEmpty)
    }

    func testQuickDrawRespectsAnOpenQuestion() {
        setTerminal(chats[1], status: .awaitingInput)
        press(.r1, at: 0)
        tick(0.3)
        guard case let .quickDraw(slots)? = island.last?.content else { return XCTFail("Raute erwartet") }
        XCTAssertTrue(slots.dialogOpen)
        XCTAssertFalse(slots.enabled.contains(.continueWork))
        press(.cross, at: 0.4)
        press(.triangle, at: 0.5)
        XCTAssertEqual(haptics, [.rejected, .rejected])
        XCTAssertTrue(terminals.texts.isEmpty)
        XCTAssertTrue(terminals.keys.isEmpty, "kein Shift+Tab in einer Rückfrage")
        XCTAssertTrue(island.isVisible, "ein Eintrag, der nicht geht, lässt die Insel offen")
    }

    /// Erscheint die Rückfrage, während R1 gehalten wird, gilt sie sofort.
    func testQuestionAppearingWhileHoldingIsHonoured() {
        press(.r1, at: 0)
        tick(0.3)
        setTerminal(chats[1], status: .awaitingInput)
        press(.cross, at: 0.4)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    func testQuickDrawCommandsOpensTheMenuOnThatPage() {
        press(.r1, at: 0)
        tick(0.3)
        press(.square, at: 0.4)
        guard case .commands? = ui.menu?.submenu else { return XCTFail("Menü auf „Befehle“ erwartet") }
        XCTAssertEqual(context, .menu(dialogOpen: false))
        release(.r1, at: 0.6)
        XCTAssertNotNil(ui.menu, "Loslassen von R1 schließt das Menü nicht")
    }

    func testQuickDrawAccountsOpensTheAccountPage() {
        window.chatInfo = ControllerChatActionInfo(title: "Chat", accounts: [
            ControllerAccountChoice(kind: .claude, name: "main", label: "main", isCurrent: true, isLoggedIn: true),
            ControllerAccountChoice(kind: .claude, name: "work", label: "work", isCurrent: false, isLoggedIn: true),
        ])
        press(.r1, at: 0)
        press(.circle, at: 0.1)
        guard case .accounts? = ui.menu?.submenu else { return XCTFail("Menü auf „Konto wechseln“ erwartet") }
    }

    /// Ziel ist der Chat beim Öffnen; ist inzwischen ein anderer ausgewählt,
    /// geht nichts raus.
    func testQuickDrawTargetsTheChatAtOpening() {
        press(.r1, at: 0)
        tick(0.3)
        window.selected = chats[3]
        press(.cross, at: 0.4)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    // MARK: - L1 Schreiben

    func testWritingDeletesToLineStartAndInsertsNewline() {
        press(.l1, at: 0)
        tick(0.3)
        guard case let .writing(slots)? = island.last?.content else { return XCTFail("Schreiben erwartet") }
        XCTAssertTrue(slots.canDeleteLine && slots.canInsertNewline)
        press(.square, at: 0.4)
        tick(0.8)
        tick(0.95)
        release(.square, at: 1)
        press(.triangle, at: 1.1)
        press(.cross, at: 1.2)
        press(.circle, at: 1.3)
        // Runde 5: Kreuz fügt ein (hier ist die Zwischenablage leer: „geht
        // nicht“), Kreis schickt genau ein Escape.
        XCTAssertEqual(terminals.keys, [.killLineStart, .killLineStart, .killLineStart, .newline, .escape])
        XCTAssertEqual(haptics, [.rejected])
        release(.l1, at: 1.5)
        XCTAssertFalse(island.isVisible)
        XCTAssertEqual(window.selected, chats[1])
    }

    func testWritingInAShellOnlyExplains() {
        setTerminal(chats[1], status: .idle, profile: .shell)
        press(.l1, at: 0)
        tick(0.3)
        guard case let .writing(slots)? = island.last?.content else { return XCTFail("Schreiben erwartet") }
        XCTAssertEqual(slots.note, .shell)
        press(.square, at: 0.4)
        XCTAssertTrue(terminals.keys.isEmpty)
        XCTAssertEqual(haptics, [.rejected])
    }

    // MARK: - Pause und Aufräumen

    /// L1 + R1 eine Sekunde: Pause, aber kein Chatwechsel und keine Ebene.
    func testChordPausesWithoutSwitchingOrLayerActions() {
        press(.l1, at: 0)
        tick(0.3)
        XCTAssertTrue(island.isVisible)
        press(.r1, at: 0.5)
        XCTAssertFalse(island.isVisible, "Akkord schließt die Insel")
        tick(1.5)
        release(.l1, at: 1.6)
        release(.r1, at: 1.7)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(window.selected, chats[1])
        XCTAssertTrue(terminals.keys.isEmpty)
    }

    /// Das Ende einer Ebene ohne offene Insel lässt den Ctrl+Tab-Umschalter
    /// der Tastatur stehen.
    func testLayerEndWithoutIslandTouchesNothing() {
        window.isSwitcherOpen = true
        dispatcher.perform(.islandRelease, in: context)
        dispatcher.perform(.islandClose, in: context)
        XCTAssertEqual(window.commands, [])
    }

    func testCloseControllerUIHidesTheIsland() {
        press(.l2, at: 0)
        tick(0.3)
        dispatcher.closeControllerUI()
        XCTAssertFalse(island.isVisible)
        XCTAssertNil(dispatcher.islandState)
    }

    func testUserInputClosesTheIslandForThisHold() {
        press(.l1, at: 0)
        tick(0.3)
        dispatcher.closeIslandForUserInput()
        XCTAssertFalse(island.isVisible)
        dispatcher.perform(.islandShow(.writing), in: context)
        XCTAssertFalse(island.isVisible, "kommt in diesem Halten nicht wieder")
        release(.l1, at: 1)
        press(.l1, at: 2)
        tick(2.3)
        XCTAssertTrue(island.isVisible)
    }

    // MARK: - Review nach Runde 4

    /// Punkt 1: „Weiter“ und „Modus wechseln“ nur, wenn der Chat ruht — nicht
    /// bei arbeitend, unbekannt oder gerade gesendet (Lücke vor „wartet“;
    /// Codex meldet nie „wartet“). Konto wechseln geht weiter.
    func testContinueAndModeOnlyWhileTheChatIsIdle() {
        // Codex: „Weiter“ und „Modus wechseln“ nur bei ruhendem Chat.
        let cases: [(AgentSessionRuntimeStatus?, ControllerChatState.Profile, Date?)] = [
            (.working, .codex, nil), (nil, .codex, nil), (.idle, .codex, now.addingTimeInterval(-1)),
        ]
        for (status, profile, lastEnter) in cases {
            haptics = []
            setTerminal(chats[1], status: status, profile: profile, lastEnter: lastEnter)
            press(.r1, at: 0)
            tick(0.3)
            guard case let .quickDraw(slots)? = island.last?.content else { return XCTFail("Raute erwartet") }
            XCTAssertEqual(slots.note, .busy, "\(String(describing: status)) \(profile)")
            XCTAssertFalse(slots.enabled.contains(.continueWork))
            XCTAssertFalse(slots.enabled.contains(.cycleMode))
            XCTAssertTrue(slots.enabled.contains(.commands))
            press(.cross, at: 0.4)
            press(.triangle, at: 0.5)
            XCTAssertEqual(haptics, [.rejected, .rejected])
            XCTAssertTrue(terminals.texts.isEmpty)
            XCTAssertTrue(terminals.keys.isEmpty, "kein Shift+Tab, kein Enter")
            release(.cross, at: 0.6)
            release(.triangle, at: 0.6)
            release(.r1, at: 0.7)
        }
        setTerminal(chats[1], status: .idle, profile: .codex)
        press(.r1, at: 1)
        press(.triangle, at: 1.1)
        XCTAssertEqual(terminals.keys, [.backTab], "ruhender Codex-Chat: Modus wechseln geht")
    }

    /// Claude: Arbeitet der Chat (oder wurde gerade gesendet), bleibt „Modus
    /// wechseln“ gesperrt; R1 + Kreuz ist „Jetzt senden“ und geht.
    func testClaudeBusyCrossSendsNowButModeWaits() {
        let cases: [(AgentSessionRuntimeStatus?, Date?)] = [
            (.working, nil), (nil, nil), (.idle, now.addingTimeInterval(-1)),
        ]
        for (status, lastEnter) in cases {
            haptics = []
            let keysBefore = terminals.keys.count
            setTerminal(chats[1], status: status, profile: .claude, lastEnter: lastEnter)
            press(.r1, at: 0)
            tick(0.3)
            guard case let .quickDraw(slots)? = island.last?.content else { return XCTFail("Raute erwartet") }
            XCTAssertEqual(slots.cross, .sendNow, "\(String(describing: status))")
            XCTAssertFalse(slots.enabled.contains(.cycleMode))
            press(.triangle, at: 0.4)
            XCTAssertEqual(haptics, [.rejected], "kein Shift+Tab bei arbeitendem Chat")
            press(.cross, at: 0.5)
            XCTAssertEqual(Array(terminals.keys.dropFirst(keysBefore)), [.sendNow])
            XCTAssertTrue(terminals.texts.isEmpty)
            release(.cross, at: 0.6)
            release(.triangle, at: 0.6)
            release(.r1, at: 0.7)
        }
    }

    /// Der Chat beginnt zu arbeiten, während R1 gehalten wird: Die Raute graut
    /// aus (nach `refreshContext`), und ein Druck geht nicht.
    func testChatStartingToWorkWhileHoldingR1() {
        setTerminal(chats[1], status: .idle, profile: .codex)
        press(.r1, at: 0)
        tick(0.3)
        setTerminal(chats[1], status: .working, profile: .codex)
        dispatcher.refreshContext()
        guard case let .quickDraw(slots)? = island.last?.content else { return XCTFail("Raute erwartet") }
        XCTAssertEqual(slots.note, .busy)
        press(.cross, at: 0.4)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    /// Das Options-Menü ist kein Schlupfloch: dieselbe Regel, auch wenn der
    /// Chat erst nach dem Öffnen zu arbeiten beginnt.
    func testMenuFollowsTheSameRule() {
        setTerminal(chats[1], status: .working)
        dispatcher.perform(.menuToggle, in: context)
        let busyMenu = ui.menu
        XCTAssertEqual(busyMenu?.top.isEnabled(.continueWork), false)
        XCTAssertEqual(busyMenu?.top.isEnabled(.cycleMode), false)
        dispatcher.perform(.menuToggle, in: context)

        setTerminal(chats[1], status: .idle)
        dispatcher.perform(.menuToggle, in: context)
        ui.menu?.select(.continueWork)
        setTerminal(chats[1], status: .working)
        dispatcher.refreshContext()
        XCTAssertEqual(ui.menu?.top.isEnabled(.continueWork), false, "Einträge folgen dem Status")
        // Auch wenn der Status zwischen zwei Schnappschüssen wechselt, prüft
        // das Auslösen frisch.
        guard let setup = ui.menu?.setup else { return XCTFail("Menü erwartet") }
        var stale = setup
        stale.chatBusy = false
        dispatcher.perform(.continueWork, setup: stale)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertTrue(terminals.texts.isEmpty)
    }

    /// Punkt 3: Nur den Reiter zu wechseln und L2 loszulassen, wechselt nicht.
    func testTabSwitchAloneDoesNotSwitch() {
        window.workspaces = [UUID(), UUID()].map {
            ControllerWorkspaceChoice(id: $0, name: "W", colorHex: "#888888", chatCount: 1,
                                      hasWaitingChat: false, isCurrent: false)
        }
        press(.l2, at: 0)
        press(.dpadRight, at: 0.1)
        release(.dpadRight, at: 0.15)
        XCTAssertEqual(whereTo?.tab, .workspaces)
        release(.l2, at: 0.5)
        XCTAssertFalse(window.commands.contains { if case .activateWorkspace = $0 { return true }; return false })
        XCTAssertEqual(window.selected, chats[1])

        // Bewegt, dann Reiter gewechselt: auch dann erst nach einer Bewegung.
        press(.l2, at: 1)
        press(.dpadDown, at: 1.1)
        release(.dpadDown, at: 1.15)
        press(.dpadRight, at: 1.2)
        release(.dpadRight, at: 1.25)
        press(.cross, at: 1.3)
        XCTAssertFalse(window.commands.contains { if case .activateWorkspace = $0 { return true }; return false })
        XCTAssertEqual(window.selected, chats[1])
    }

    /// Punkt 4: Scheitert der Wechsel, wird nicht diktiert.
    func testDictatesOnlyIfTheSwitchWorked() {
        window.failing = [String(describing: AgentChatsCommand.selectSession(chats[2]))]
        press(.l2, at: 0)
        press(.dpadDown, at: 0.1)
        press(.r2, at: 0.2)
        XCTAssertTrue(dictation.started.isEmpty)
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Punkt 7: Der Schnappschuss zeichnet die Insel nicht nach, nur
    /// `refreshContext` (Trockenläufe des Debug-Kanals bleiben ohne Fenster).
    func testSnapshotHasNoIslandSideEffect() {
        press(.r1, at: 0)
        tick(0.3)
        let shown = island.shown.count
        setTerminal(chats[1], status: .awaitingInput)
        _ = dispatcher.snapshot()
        XCTAssertEqual(island.shown.count, shown)
        dispatcher.refreshContext()
        XCTAssertEqual(island.shown.count, shown + 1)
    }

    // MARK: - Insel-Paket: Projekte im Reiter „Workspaces & Projekte“

    /// Ein Projekt öffnet still als Raster (wie der ⊞ in der Seitenleiste);
    /// R2 auf einem Projekt geht nicht.
    func testProjectSwitchesSilentlyAndRejectsDictation() {
        let project = UUID()
        window.workspaces = [
            ControllerWorkspaceChoice(id: UUID(), name: "W", colorHex: "#888888", chatCount: 1,
                                      hasWaitingChat: false, isCurrent: true),
            ControllerWorkspaceChoice(id: project, name: "P", colorHex: "#888888", chatCount: 2,
                                      hasWaitingChat: false, isCurrent: false, kind: .project),
        ]
        window.isGridActive = true
        press(.l2, at: 0)
        press(.dpadDown, at: 0.1)
        release(.dpadDown, at: 0.15)
        press(.r2, at: 0.2)
        XCTAssertEqual(haptics, [.rejected], "R2 auf einem Projekt")
        XCTAssertTrue(dictation.started.isEmpty)
        press(.cross, at: 0.3)
        XCTAssertEqual(window.commands.last, .switchToProject(project))
    }

    // MARK: - Insel-Paket: App-Raute unter R1

    private func holdR1() {
        press(.r1, at: 0)
        tick(0.3)
    }

    private var quickDraw: ControllerQuickDrawSlots? {
        if case let .quickDraw(slots)? = island.last?.content { return slots }
        return nil
    }

    /// Die Glocke schaltet eine Stufe weiter; die Insel bleibt offen und
    /// bestätigt, was jetzt gilt und was der nächste Druck bringt.
    func testAlertToggleKeepsTheIslandOpenAndConfirms() {
        let environment = ControllerEnvironmentSpy()
        rebuild(environment: environment)
        holdR1()
        press(.dpadLeft, at: 0.4)
        release(.dpadLeft, at: 0.45)
        XCTAssertEqual(environment.alertCycles, 1)
        XCTAssertEqual(quickDraw?.confirmation, .alert(.soundOff, next: .off))
        XCTAssertEqual(quickDraw?.app.alert, .soundOff)
        XCTAssertTrue(island.isVisible, "Schalter lassen die Insel offen")
        press(.dpadLeft, at: 0.5)
        release(.dpadLeft, at: 0.55)
        XCTAssertEqual(environment.alertCycles, 2)
        XCTAssertEqual(quickDraw?.confirmation, .alert(.off, next: .all))
        XCTAssertEqual(haptics, [.toggled, .toggled])
    }

    /// Wach bleiben ohne Admin-Freigabe: kein Dialog, Hinweis, „geht nicht“.
    func testStayAwakeWithoutPermissionOpensNoDialog() {
        let environment = ControllerEnvironmentSpy()
        environment.stayAwakeResult = .needsPermission
        rebuild(environment: environment)
        holdR1()
        press(.dpadRight, at: 0.4)
        XCTAssertEqual(quickDraw?.confirmation, .awakeNeedsPermission)
        XCTAssertEqual(haptics, [.rejected])
        XCTAssertTrue(island.isVisible)
        environment.stayAwakeResult = .changed(.whileWorking)
        release(.dpadRight, at: 0.45)
        press(.dpadRight, at: 0.5)
        XCTAssertEqual(quickDraw?.confirmation, .awake(.whileWorking, next: .always))
    }

    /// ▼ öffnet den Verlauf und schließt die Insel (ein Befehl).
    func testClipboardSlotClosesTheIsland() {
        let environment = ControllerEnvironmentSpy()
        rebuild(environment: environment)
        holdR1()
        press(.dpadDown, at: 0.4)
        XCTAssertEqual(environment.clipboardToggles, 1)
        XCTAssertFalse(island.isVisible)
    }

    /// Während eines gebundenen Diktats geht die App-Raute weiter.
    func testAppDiamondWorksWhileDictating() {
        let environment = ControllerEnvironmentSpy()
        rebuild(environment: environment)
        dictation.start(target: .agentChat(sessionID: chats[1]), label: nil)
        holdR1()
        press(.dpadLeft, at: 0.4)
        XCTAssertEqual(environment.alertCycles, 1)
        XCTAssertEqual(quickDraw?.note, .dictating)
    }

    /// R1 + ▲: Limits-Karte mit allen Konten, Konto des Chats markiert, ein
    /// passiver Abruf nur beim Öffnen der Karte (nicht beim Halten von R1);
    /// Stick und ▼ scrollen, ✕ nimmt den Weg von ↻.
    func testLimitsCardScrollsAndRefreshes() {
        var stale = 0, refreshed = 0
        dispatcher.limits = ControllerLimitsAccess(
            accounts: { ControllerLimitAccounts(claude: (0..<7).map { "k\($0)" }, gpt: ["k7", "k8"]) },
            rows: { accounts in
                accounts.claude.map { ControllerAccountLimitRow(kind: .claude, name: $0, fiveHour: 10) }
                    + accounts.gpt.map { ControllerAccountLimitRow(kind: .gpt, name: $0, fiveHour: 10) }
            },
            updatedAt: { nil }, isLoading: { false },
            refreshIfStale: { stale += 1 }, refresh: { refreshed += 1 })
        var info = ControllerChatActionInfo(title: "Chat")
        info.usageAccount = ControllerUsageAccount(kind: .claude, name: "k2")
        window.chatInfo = info
        holdR1()
        XCTAssertEqual(stale, 0, "R1 halten lädt nichts")
        XCTAssertEqual(quickDraw?.account, ControllerIslandAccountBadge(name: "k2", fiveHourUsed: nil))
        press(.dpadUp, at: 0.4)
        release(.dpadUp, at: 0.45)
        XCTAssertEqual(stale, 1)
        XCTAssertEqual(quickDraw?.card?.rows.first(where: \.isCurrentChat)?.name, "k2")
        XCTAssertEqual(quickDraw?.card?.hiddenBelow, 3)
        press(.dpadDown, at: 0.5)
        release(.dpadDown, at: 0.55)
        XCTAssertEqual(quickDraw?.card?.hiddenAbove, 1, "▼ scrollt statt Verlauf")
        feed(.stick(.left, x: 0, y: -1), at: 0.6)
        XCTAssertEqual(quickDraw?.card?.hiddenAbove, 2, "Stick scrollt")
        feed(.stick(.left, x: 0, y: 0), at: 0.65)
        press(.cross, at: 0.7)
        XCTAssertEqual(refreshed, 1)
        XCTAssertTrue(window.commands.isEmpty || !terminals.texts.contains { $0.text == ControllerMenuText.continueWork })
        XCTAssertTrue(island.isVisible)
        release(.cross, at: 0.75)
        press(.triangle, at: 0.8)
        XCTAssertEqual(haptics.last, .rejected, "Chat-Raute geht bei offener Karte nicht")
        release(.r1, at: 1)
        XCTAssertFalse(island.isVisible, "Loslassen schließt")
    }

    /// Review Insel-Paket, Befunde 2 und 3: Kopf und Karte bleiben beim
    /// Konto, das beim Öffnen galt — während eines Diktats dem seines Ziels,
    /// auch wenn neue Zahlen kommen und ein anderer Chat ausgewählt ist. Die
    /// Konten liest die Karte einmal beim Öffnen, neue Zahlen ordnen sich
    /// nur noch zu.
    func testIslandKeepsTheAccountItOpenedWithAndReadsAccountsOnce() {
        var accountReads = 0, rowBuilds = 0
        var fiveHour: Double = 10
        dispatcher.limits = ControllerLimitsAccess(
            accounts: {
                accountReads += 1
                return ControllerLimitAccounts(claude: ["main", "diktat"], gpt: [])
            },
            rows: { accounts in
                rowBuilds += 1
                return accounts.claude.map { ControllerAccountLimitRow(kind: .claude, name: $0, fiveHour: fiveHour) }
            })
        dispatcher.accountLimit = { _, _ in (fiveHour: fiveHour, week: nil) }
        var selectedInfo = ControllerChatActionInfo(title: "Ausgewählt")
        selectedInfo.usageAccount = ControllerUsageAccount(kind: .claude, name: "main")
        var targetInfo = ControllerChatActionInfo(title: "Ziel")
        targetInfo.usageAccount = ControllerUsageAccount(kind: .claude, name: "diktat")
        window.chatInfo = selectedInfo
        window.chatInfoByID[chats[2]] = targetInfo
        dictation.start(target: .agentChat(sessionID: chats[2]), label: nil)
        holdR1()
        XCTAssertEqual(quickDraw?.account?.name, "diktat", "Kopf: Konto des Diktat-Ziels")
        XCTAssertEqual(accountReads, 0, "R1 halten liest keine Konten")
        press(.dpadUp, at: 0.4)
        release(.dpadUp, at: 0.45)
        XCTAssertEqual(accountReads, 1)
        XCTAssertEqual(quickDraw?.card?.rows.first(where: \.isCurrentChat)?.name, "diktat")

        fiveHour = 55
        dispatcher.accountLimitsChanged()
        dispatcher.accountLimitsChanged()
        XCTAssertEqual(accountReads, 1, "neue Zahlen lesen die Profile nicht neu")
        XCTAssertGreaterThan(rowBuilds, 1)
        XCTAssertEqual(quickDraw?.account, ControllerIslandAccountBadge(name: "diktat", fiveHourUsed: 55))
        XCTAssertEqual(quickDraw?.card?.rows.first(where: \.isCurrentChat)?.name, "diktat")
        XCTAssertEqual(quickDraw?.card?.rows.first?.fiveHour, 55)
    }

    /// Review Insel-Paket, Befund 5: Bei offener Karte schickt R1 + L3 kein
    /// Ctrl+O. Während eines Diktats bietet die Fußzeile ✕ nicht an (dort
    /// „geht nicht“), nach dem Diktat wieder.
    func testLimitsCardBlocksTranscriptToggleAndHidesRefreshWhileDictating() {
        holdR1()
        press(.dpadUp, at: 0.4)
        release(.dpadUp, at: 0.45)
        XCTAssertEqual(quickDraw?.card?.canRefresh, true)
        press(.l3, at: 0.5)
        XCTAssertEqual(haptics.last, .rejected)
        XCTAssertFalse(terminals.keys.contains(.toggleTranscript), "kein Ctrl+O bei offener Karte")
        release(.l3, at: 0.55)
        release(.r1, at: 0.6)

        dictation.start(target: .agentChat(sessionID: chats[1]), label: nil)
        press(.r1, at: 1)
        tick(1.3)
        press(.dpadUp, at: 1.4)
        release(.dpadUp, at: 1.45)
        XCTAssertEqual(quickDraw?.card?.canRefresh, false, "✕ geht während des Diktats nicht")
        press(.cross, at: 1.5)
        XCTAssertEqual(haptics.last, .rejected)
        release(.cross, at: 1.55)
        dictation.cancel()
        dispatcher.refreshContext()
        XCTAssertEqual(quickDraw?.card?.canRefresh, true, "nach dem Diktat wieder")
    }

    /// Review Insel-Paket, Befund 7: Steht die Prüfung der Freigabe noch aus
    /// (Seitenleiste seit dem Start verborgen), antwortet der Wach-Schalter
    /// danach — ohne vorher „Erst in der Seitenleiste freigeben“ zu sagen.
    func testStayAwakeAnswersAfterTheSilentPermissionCheck() {
        let environment = ControllerEnvironmentSpy()
        environment.deferStayAwake = true
        rebuild(environment: environment)
        holdR1()
        press(.dpadRight, at: 0.4)
        XCTAssertNil(quickDraw?.confirmation)
        XCTAssertTrue(haptics.isEmpty)
        environment.answerStayAwake()
        XCTAssertEqual(quickDraw?.confirmation, .awake(.whileWorking, next: .always))
        XCTAssertEqual(haptics, [.toggled])

        // Ist die Insel bis zur Antwort zu, bleibt nur der Impuls.
        release(.dpadRight, at: 0.45)
        environment.deferStayAwake = true
        press(.dpadRight, at: 0.5)
        release(.r1, at: 0.6)
        let shown = island.shown.count
        environment.answerStayAwake()
        XCTAssertEqual(island.shown.count, shown)
        XCTAssertFalse(island.isVisible)
        XCTAssertEqual(haptics, [.toggled, .toggled])
    }

    /// Review Insel-Paket, Befund 9: Auch während eines gebundenen Diktats
    /// wechselt Loslassen von L2 nach einer Bewegung; das Diktat bleibt bei
    /// seinem Ziel.
    func testReleasingL2AfterAMoveSwitchesDuringBoundDictation() {
        dictation.start(target: .agentChat(sessionID: chats[1]), label: nil)
        press(.l2, at: 0)
        tick(0.3)
        XCTAssertNotNil(whereTo)
        press(.dpadDown, at: 0.4)
        release(.dpadDown, at: 0.45)
        release(.l2, at: 0.5)
        XCTAssertEqual(window.selected, chats[2], "Loslassen nach Bewegung wechselt")
        XCTAssertEqual(dictation.targetSessionID, chats[1], "Diktat bleibt beim Ziel")
        XCTAssertTrue(dictation.stopped.isEmpty)
        XCTAssertFalse(island.isVisible)
    }

    private func rebuild(environment: ControllerEnvironmentSpy) {
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation, environment: environment,
            ui: ui, island: island, now: { Date(timeIntervalSince1970: 1_000) })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        dispatcher.titleForSession = { _ in "Controller Insel" }
        dispatcher.islandStatus = { _ in .working }
    }
}
