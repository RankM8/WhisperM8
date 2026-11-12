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

    /// Cmd-Tab: Halten und Loslassen ohne Bewegung führt zum vorigen Ort —
    /// dasselbe Ziel wie L2 getippt, aber über die Liste.
    func testHoldAndReleaseGoesToThePreviousChat() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(.l2, at: 0)
        tick(0.3)
        XCTAssertEqual(whereTo?.chats.selected?.id, chats[3], "Markierung auf dem vorigen Chat")
        release(.l2, at: 1)
        XCTAssertEqual(window.selected, chats[3])
        XCTAssertEqual(window.commands.last, .selectSession(chats[3]))
        XCTAssertFalse(window.commands.contains(.lastChat), "Wechsel über die Liste, nicht über Tippen")
        XCTAssertTrue(haptics.isEmpty)
    }

    /// Kreis bricht ab, auch wenn die Markierung auf dem vorigen Ort steht.
    func testCircleCancelsTheSwitchToThePreviousPlace() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(.l2, at: 0)
        tick(0.3)
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
        XCTAssertEqual(whereTo?.tab, .workspaces, "Raster: Reiter Workspaces")
        XCTAssertEqual(whereTo?.workspaces.selected?.id, workspaces[1], "auf dem vorigen Workspace")
        press(.dpadLeft, at: 0.5)
        release(.dpadLeft, at: 0.55)
        XCTAssertEqual(whereTo?.tab, .chats, "links: Reiter Chats")
        XCTAssertEqual(whereTo?.destination, .stay, "Chats: Markierung auf dem aktuellen")
        press(.dpadRight, at: 0.6)
        release(.dpadRight, at: 0.65)
        XCTAssertEqual(whereTo?.tab, .workspaces)
        XCTAssertEqual(whereTo?.destination, .workspace(workspaces[1]), "zurück auf dem vorigen Workspace")
        press(.dpadDown, at: 0.7)
        release(.dpadDown, at: 0.75)
        release(.l2, at: 1)
        XCTAssertEqual(window.commands.last, .activateWorkspace(workspaces[2]))
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

    func testQuickDrawContinueSendsAndCloses() {
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
        XCTAssertEqual(terminals.keys, [.killLineStart, .killLineStart, .killLineStart, .newline],
                       "Kreuz und Kreis bleiben frei")
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
        let cases: [(AgentSessionRuntimeStatus?, ControllerChatState.Profile, Date?)] = [
            (.working, .claude, nil), (nil, .claude, nil), (.idle, .claude, now.addingTimeInterval(-1)),
            (.working, .codex, nil),
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

    /// Der Chat beginnt zu arbeiten, während R1 gehalten wird: Die Raute graut
    /// aus (nach `refreshContext`), und ein Druck geht nicht.
    func testChatStartingToWorkWhileHoldingR1() {
        press(.r1, at: 0)
        tick(0.3)
        setTerminal(chats[1], status: .working)
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
}
