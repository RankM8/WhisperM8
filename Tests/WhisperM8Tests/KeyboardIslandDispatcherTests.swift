import AppKit
import XCTest
@testable import WhisperM8

/// Insel per Tastatur (WM8-104) durch Monitor und Ausführer: dieselbe Insel und
/// dieselben Wege wie L2 „Wohin“ am Controller.
@MainActor
final class KeyboardIslandDispatcherTests: XCTestCase {
    private typealias K = KeyboardIslandKeys.KeyCode
    private var window: ControllerWindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: ControllerTerminalSpy!
    private var dictation: ControllerDictationSpy!
    private var environment: ControllerEnvironmentSpy!
    private var island: ControllerIslandSpy!
    private var dispatcher: ControllerActionDispatcher!
    private var monitor: KeyboardIslandMonitor!
    private var scheduled: [@MainActor () -> Void] = []
    private var beeps = 0
    private var enabled = true
    private var chats: [UUID] = []
    private var reopenResult = false

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        dictation = ControllerDictationSpy()
        environment = ControllerEnvironmentSpy()
        island = ControllerIslandSpy()
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation, environment: environment,
            ui: ControllerUIModel(), island: island, now: { Date(timeIntervalSince1970: 1_000) })
        dispatcher.titleForSession = { _ in "Chat" }
        dispatcher.islandChatRows = { order, current in
            order.map { ControllerIslandChatRow(id: $0, title: "Chat", status: .idle, detail: "", isCurrent: $0 == current) }
        }
        dispatcher.closedChats = ControllerClosedChatsAccess(
            nextTitle: { nil }, reopen: { [unowned self] in reopenResult })
        beeps = 0
        dispatcher.keyboardRejected = { [unowned self] in beeps += 1 }
        chats = [UUID(), UUID(), UUID(), UUID()]
        window.selected = chats[1]
        window.rows = chats.map { AgentChatsListRow(row: .chat($0)) }
        for chat in chats {
            terminals.states[chat] = ControllerTerminalState(
                isRunning: true, profile: .claude, status: .idle, statusSince: nil,
                draftSuspected: false, lastEnterAt: nil, lastEscapeAt: nil)
        }
        scheduled = []
        enabled = true
        reopenResult = false
        monitor = KeyboardIslandMonitor()
        monitor.attach(dispatcher)
        monitor.isEnabled = { [unowned self] in enabled }
        monitor.schedule = { [unowned self] _, work in scheduled.append(work) }
    }

    @discardableResult
    private func press(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [.option]) -> Bool {
        monitor.keyDown(keyCode: keyCode, modifiers: modifiers)
    }

    private func releaseOption() { monitor.flagsChanged([]) }

    private func fireReveal() {
        let work = scheduled
        scheduled = []
        work.forEach { $0() }
    }

    // MARK: - Öffnen

    /// ⌥Tab kurz: kein Aufblitzen, Wechsel an den vorigen Ort wie L2 getippt.
    func testQuickTapGoesBackWithoutShowing() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        XCTAssertTrue(press(K.tab), "⌥Tab wird geschluckt")
        XCTAssertTrue(island.shown.isEmpty, "unsichtbar bis 0,2 s")
        releaseOption()
        XCTAssertEqual(window.commands.last, .lastChat, "derselbe Weg wie L2 getippt")
        XCTAssertEqual(window.selected, chats[3])
        fireReveal()
        XCTAssertTrue(island.shown.isEmpty, "nach dem Wechsel erscheint nichts mehr")
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
    }

    /// ⌥Tab halten: nach 0,2 s die Insel mit Tastenkappen, Markierung auf
    /// „vorher“; Tab weiter, ⌥ los wechselt.
    func testHoldShowsIslandAndStepsWithTab() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(K.tab)
        fireReveal()
        let model = try? XCTUnwrap(island.last)
        XCTAssertEqual(model?.input, .keyboard)
        XCTAssertEqual(model?.whereTo?.chats.selected?.id, chats[3], "Start auf „vorher“")
        press(K.tab)
        XCTAssertEqual(island.last?.whereTo?.chats.selected?.id, chats[2])
        press(K.tab, [.option, .shift])
        press(K.downArrow, [.option, .function])
        XCTAssertEqual(island.last?.whereTo?.chats.selected?.id, chats[2])
        releaseOption()
        XCTAssertEqual(window.commands.last, .selectSession(chats[2]))
        XCTAssertFalse(island.isVisible)
    }

    func testReturnCommitsAndEscapeCancels() {
        press(K.tab)
        press(K.escape)
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
        releaseOption()
        XCTAssertTrue(window.commands.isEmpty, "nach Esc wechselt nichts")

        press(K.tab)
        press(K.returnKey)
        XCTAssertEqual(window.commands.last, .selectSession(chats[2]), "ohne vorigen Ort die Zeile darunter")
    }

    /// Steht die Markierung (nach Bewegung) wieder auf dem aktuellen Chat,
    /// passiert beim Loslassen nichts.
    func testReleaseOnCurrentDoesNothing() {
        press(K.tab)
        press(K.upArrow, [.option, .function])
        releaseOption()
        XCTAssertTrue(window.commands.isEmpty)
        XCTAssertEqual(beeps, 0)
    }

    func testDoesNotOpenWhenDisabledOrBlocked() {
        enabled = false
        XCTAssertFalse(press(K.tab), "Schalter aus: ⌥Tab läuft weiter wie bisher")
        enabled = true
        window.hasSheet = true
        XCTAssertFalse(press(K.tab), "Dialog oder Sheet: ⌥Tab bleibt beim Dialog")
        window.hasSheet = false
        window.isSwitcherOpen = true
        XCTAssertFalse(press(K.tab), "⌃Tab-Umschalter offen: nur eine Auswahl gleichzeitig")
        window.isSwitcherOpen = false
        environment.isAppActive = false
        XCTAssertFalse(press(K.tab), "WhisperM8 nicht vorne")
        environment.isAppActive = true
        XCTAssertTrue(press(K.tab), "Agent-Chats-Fenster vorne: geht")
    }

    /// Hotkey-Diktat ins Programm vorne: Ein Wechsel würde den Text woanders
    /// hinbringen, die Insel geht nicht auf.
    func testNoIslandDuringUnboundDictation() {
        dictation.phase = .recording
        XCTAssertFalse(press(K.tab))
    }

    /// Geht beim Halten ein Dialog auf, schließt das Loslassen nur.
    func testDialogDuringHoldOnlyCloses() {
        press(K.tab)
        window.hasSheet = true
        releaseOption()
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
        XCTAssertTrue(window.commands.isEmpty)
    }

    // MARK: - Tasten in der Insel

    func testOtherKeysAreSwallowedAndMissedReleasePassesThrough() {
        press(K.tab)
        XCTAssertTrue(press(2), "⌥D gehört der Insel")
        XCTAssertTrue(dispatcher.isKeyboardIslandOpen)
        XCTAssertFalse(press(2, []), "Taste ohne ⌥: Loslassen verpasst, Taste läuft weiter")
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
        XCTAssertTrue(window.commands.isEmpty)
    }

    func testTabsSwitchWithArrows() {
        window.workspaces = [ControllerWorkspaceChoice(
            id: UUID(), name: "W", colorHex: "#5E6AD2", chatCount: 1, hasWaitingChat: false, isCurrent: false)]
        press(K.tab)
        fireReveal()
        press(K.rightArrow, [.option, .function])
        XCTAssertEqual(island.last?.whereTo?.tab, .workspaces)
        press(K.leftArrow, [.option, .function])
        XCTAssertEqual(island.last?.whereTo?.tab, .chats)
    }

    /// W ohne wartenden Chat: Warnton, die Insel bleibt offen.
    func testNextWaitingRejectedKeepsIsland() {
        window.failing = [String(describing: AgentChatsCommand.nextWaitingChat)]
        press(K.tab)
        press(K.w)
        XCTAssertEqual(beeps, 1)
        XCTAssertTrue(dispatcher.isKeyboardIslandOpen)
        window.failing = []
        press(K.w)
        XCTAssertEqual(window.commands.last, .nextWaitingChat)
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
    }

    func testReopenClosedChat() {
        press(K.tab)
        press(K.r)
        XCTAssertEqual(beeps, 1, "nichts geschlossen")
        XCTAssertTrue(dispatcher.isKeyboardIslandOpen)
        reopenResult = true
        press(K.r)
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
    }

    // MARK: - Diktat

    /// Leertaste: zum markierten Chat und dort diktieren.
    func testSpaceGoesAndDictates() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(K.tab)
        press(K.space)
        XCTAssertEqual(window.selected, chats[3])
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: chats[3])])
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
        releaseOption()
        XCTAssertEqual(window.commands.filter { $0 == .lastChat }.count, 1, "Loslassen danach wechselt nicht noch mal")
    }

    /// Der Diktat-Hotkey (⌥Leertaste über Carbon) kommt nie als keyDown an:
    /// Bei offener Insel heißt er „hin und diktieren“, sein Loslassen beendet
    /// die neue Aufnahme nicht.
    func testDictationHotkeyWhileOpen() {
        XCTAssertFalse(monitor.consumeDictationHotkeyDown(), "ohne Insel: gewöhnliches Diktat")
        press(K.tab)
        XCTAssertTrue(monitor.consumeDictationHotkeyDown())
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: chats[2])])
        XCTAssertTrue(monitor.consumeDictationHotkeyUp())
        XCTAssertFalse(monitor.consumeDictationHotkeyUp())
    }

    /// Geht das Loslassen des verbrauchten Hotkeys verloren, verschluckt der
    /// Merker nicht das Ende des nächsten gewöhnlichen Diktats.
    func testLostHotkeyReleaseDoesNotSwallowLaterDictation() {
        press(K.tab)
        XCTAssertTrue(monitor.consumeDictationHotkeyDown())
        // Loslassen verloren; später ein gewöhnlicher Druck ohne Insel.
        XCTAssertFalse(monitor.consumeDictationHotkeyDown())
        XCTAssertFalse(monitor.consumeDictationHotkeyUp(), "das Ende des gewöhnlichen Diktats läuft durch")
    }

    /// Ist das Loslassen von ⌥ verloren gegangen, schließt Return die Insel
    /// ohne Wechsel und wird verschluckt wie Esc: Ins Terminal durchgereicht
    /// bestätigte es womöglich eine offene Freigabe.
    func testReturnWithoutOptionIsSwallowed() {
        window.backTarget = ControllerBackTarget(kind: .chat, title: "Chat", id: chats[3])
        press(K.tab)
        XCTAssertTrue(press(K.returnKey, []))
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
        XCTAssertTrue(window.commands.isEmpty)
    }

    /// Während eines an einen Chat gebundenen Diktats: Wohin geht, Leertaste
    /// heißt „stopp“, Esc schließt nur die Insel.
    func testDuringBoundDictation() {
        dictation.phase = .recording
        dictation.targetSessionID = chats[1]
        press(K.tab)
        fireReveal()
        XCTAssertEqual(island.last?.target.dictating, true)
        press(K.escape)
        XCTAssertEqual(dictation.cancelCount, 0, "Esc beendet keine Aufnahme")
        XCTAssertTrue(dictation.stopped.isEmpty)
        press(K.tab)
        press(K.space)
        XCTAssertEqual(dictation.stopped, [false], "stopp, Text ins Feld")
        XCTAssertTrue(window.commands.isEmpty, "stopp wechselt nicht")
    }

    /// Ein Workspace ist kein Ziel für „hin und diktieren“: Warnton, Insel bleibt.
    func testSpaceOnWorkspaceIsRejected() {
        let workspace = UUID()
        window.workspaces = [ControllerWorkspaceChoice(
            id: workspace, name: "W", colorHex: "#5E6AD2", chatCount: 1, hasWaitingChat: false, isCurrent: false)]
        window.backTarget = ControllerBackTarget(kind: .workspace, title: "W", id: workspace)
        press(K.tab)
        press(K.space)
        XCTAssertEqual(beeps, 1)
        XCTAssertTrue(dispatcher.isKeyboardIslandOpen)
        XCTAssertTrue(dictation.started.isEmpty)
    }

    // MARK: - Controller und Tastatur

    /// Eine Controller-Eingabe schließt die Insel per Tastatur ohne Wechsel;
    /// das Ende einer Ebene wirkt dann nicht auf sie.
    func testControllerInputClosesKeyboardIsland() {
        press(K.tab)
        dispatcher.perform(.islandRelease, in: .chat(ControllerChatState(status: .idle, profile: .claude)))
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
        XCTAssertTrue(window.commands.isEmpty)
        releaseOption()
        XCTAssertTrue(window.commands.isEmpty)
    }

    /// Hält der Controller gerade L2, schließt ⌥Tab dessen Insel und öffnet sie
    /// für die Tastatur neu.
    func testKeyboardTakesOverControllerIsland() {
        dispatcher.showIsland(.whereTo)
        XCTAssertEqual(island.last?.input, .controller)
        press(K.tab)
        fireReveal()
        XCTAssertEqual(island.last?.input, .keyboard)
        XCTAssertEqual(dispatcher.spentLayer, .whereTo, "die Controller-Ebene bleibt bis zum Loslassen zu")
    }
}
