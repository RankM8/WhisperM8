import AppKit
import XCTest
@testable import WhisperM8

/// Insel per Tastatur, Paket 2 (WM8-104): Schnellbefehle als Buchstaben,
/// Schalter, Limits-Karte, Spickzettel und das Options-Menü per Tastatur.
@MainActor
final class KeyboardIslandCommandsTests: XCTestCase {
    private typealias K = KeyboardIslandKeys.KeyCode
    private var window: ControllerWindowFake!
    private var center: AgentChatsCommandCenter!
    private var terminals: ControllerTerminalSpy!
    private var dictation: ControllerDictationSpy!
    private var environment: ControllerEnvironmentSpy!
    private var island: ControllerIslandSpy!
    private var ui: ControllerUIModel!
    private var dispatcher: ControllerActionDispatcher!
    private var monitor: KeyboardIslandMonitor!
    private var delayed: [@MainActor () -> Void] = []
    private var beeps = 0
    private var chats: [UUID] = []
    private var refreshes = 0
    private var loading = false

    override func setUp() async throws {
        window = ControllerWindowFake()
        center = AgentChatsCommandCenter(keyWindowID: { [unowned self] in window.id })
        _ = center.register(windowID: window.id, handler: window.handler)
        terminals = ControllerTerminalSpy()
        dictation = ControllerDictationSpy()
        environment = ControllerEnvironmentSpy()
        environment.appToggles = ControllerAppToggles(alert: .all, nextAlert: .soundOff, awake: .off)
        island = ControllerIslandSpy()
        ui = ControllerUIModel()
        dispatcher = ControllerActionDispatcher(
            chats: center, terminals: terminals, dictation: dictation, environment: environment,
            ui: ui, island: island, now: { Date(timeIntervalSince1970: 1_000) })
        dispatcher.titleForSession = { _ in "Controller Insel" }
        dispatcher.islandChatRows = { order, current in
            order.map { ControllerIslandChatRow(id: $0, title: "Chat", status: .idle, detail: "", isCurrent: $0 == current) }
        }
        beeps = 0
        refreshes = 0
        loading = false
        dispatcher.keyboardRejected = { [unowned self] in beeps += 1 }
        dispatcher.keyboardLetters = { [.stayAwake: "Q"] }
        delayed = []
        dispatcher.scheduleOnMain = { [unowned self] _, work in delayed.append(work) }
        dispatcher.limits = ControllerLimitsAccess(
            accounts: { ControllerLimitAccounts(claude: ["main"], gpt: []) },
            rows: { _ in [] }, updatedAt: { nil }, isLoading: { [unowned self] in loading },
            refreshIfStale: {}, refresh: { [unowned self] in refreshes += 1 })
        chats = [UUID(), UUID(), UUID()]
        window.selected = chats[1]
        window.rows = chats.map { AgentChatsListRow(row: .chat($0)) }
        for chat in chats { setTerminal(chat, status: .idle) }
        monitor = KeyboardIslandMonitor()
        monitor.attach(dispatcher)
        monitor.isEnabled = { true }
        monitor.schedule = { _, _ in }
    }

    private func setTerminal(_ id: UUID, status: AgentSessionRuntimeStatus?, profile: ControllerChatState.Profile = .claude) {
        terminals.states[id] = ControllerTerminalState(
            isRunning: true, profile: profile, status: status, statusSince: nil,
            draftSuspected: false, lastEnterAt: nil, lastEscapeAt: nil)
    }

    @discardableResult
    private func press(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [.option], _ characters: String? = nil) -> Bool {
        monitor.keyDown(keyCode: keyCode, modifiers: modifiers, characters: characters)
    }

    private func press(_ command: KeyboardIslandCommand) { press(command.keyCode) }
    private func releaseOption() { monitor.flagsChanged([]) }
    private var commands: ControllerKeyboardCommands? { dispatcher.islandState?.model.keyboard }

    private func runDelayed() {
        let work = delayed
        delayed = []
        work.forEach { $0() }
    }

    func testOpeningBuildsCommandRowForCurrentChat() {
        press(K.tab)
        XCTAssertEqual(commands?.chatTitle, "Controller Insel")
        XCTAssertEqual(commands?.letter(.stayAwake), "Q", "Buchstabe des aktuellen Layouts")
        XCTAssertEqual(commands?.letter(.sendNow), "S")
        XCTAssertTrue(commands?.isEnabled(.sendNow) == true)
        XCTAssertTrue(commands?.isEnabled(.transcript) == true, "Claude: Ctrl+O geht")
    }

    /// S wirkt auf den aktuellen Chat (Claude: Jetzt senden), nicht auf die
    /// markierte Zeile, und schließt die Insel nach kurzer Markierung.
    func testSendNowGoesToCurrentChat() {
        press(K.tab)
        press(.sendNow)
        XCTAssertEqual(terminals.keys, [.sendNow])
        XCTAssertTrue(commands?.isHit(.sendNow) == true)
        releaseOption()
        XCTAssertTrue(window.commands.isEmpty, "nach einem Befehl wechselt Loslassen nicht")
        runDelayed()
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
    }

    func testTranscriptAndMode() {
        press(K.tab)
        press(.transcript)
        XCTAssertEqual(terminals.keys, [.toggleTranscript])
        runDelayed()
        press(K.tab)
        press(.cycleMode)
        XCTAssertEqual(terminals.keys.last, .backTab)
    }

    /// N schaltet die Glocke eine Stufe weiter, die Insel bleibt, und ⌥ los
    /// wechselt dann nicht — erst wieder nach einer Bewegung.
    func testAlertToggleKeepsIslandAndBlocksRelease() {
        press(K.tab)
        press(.alerts)
        XCTAssertEqual(environment.alertCycles, 1)
        XCTAssertEqual(commands?.slots.confirmation, .alert(.soundOff, next: .off))
        XCTAssertEqual(commands?.releaseSwitches, false)
        press(.alerts)
        XCTAssertEqual(environment.alertCycles, 2)
        releaseOption()
        XCTAssertTrue(window.commands.isEmpty)

        press(K.tab)
        press(.alerts)
        press(K.tab)
        XCTAssertEqual(commands?.releaseSwitches, true, "Bewegung macht die Markierung wieder zum Ziel")
        XCTAssertNil(commands?.slots.confirmation)
        releaseOption()
        XCTAssertFalse(window.commands.isEmpty)
    }

    func testStayAwakeNeedsPermissionBeeps() {
        environment.stayAwakeResult = .needsPermission
        press(K.tab)
        press(.stayAwake)
        XCTAssertEqual(beeps, 1)
        XCTAssertEqual(commands?.slots.confirmation, .awakeNeedsPermission)
        XCTAssertTrue(dispatcher.isKeyboardIslandOpen)
    }

    func testClipboardClosesIsland() {
        press(K.tab)
        press(.clipboard)
        XCTAssertEqual(environment.clipboardToggles, 1)
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
    }

    /// L: Karte statt Liste; ↑↓ scrollen sie statt die Markierung zu bewegen,
    /// Return holt frisch, L zurück zur Liste, ⌥ los schließt ohne Wechsel.
    func testLimitsCard() {
        press(K.tab)
        press(.limits)
        XCTAssertNotNil(commands?.slots.card)
        let marked = dispatcher.islandState?.model.whereTo?.chats.selected?.id
        press(K.downArrow, [.option, .function])
        XCTAssertEqual(dispatcher.islandState?.model.whereTo?.chats.selected?.id, marked)
        press(K.returnKey)
        XCTAssertEqual(refreshes, 1)
        loading = true
        press(K.returnKey)
        XCTAssertEqual(beeps, 1, "läuft schon ein Abruf")
        press(.alerts)
        XCTAssertEqual(beeps, 2, "bei offener Karte nur L")
        press(.limits)
        XCTAssertNil(commands?.slots.card)
        press(.limits)
        releaseOption()
        XCTAssertTrue(window.commands.isEmpty)
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
    }

    /// Während eines Diktats: Chat-Befehle aus, App-Befehle gehen.
    func testDuringDictationOnlyAppCommands() {
        dictation.phase = .recording
        dictation.targetSessionID = chats[1]
        press(K.tab)
        XCTAssertTrue(commands?.dictating == true)
        press(.sendNow)
        XCTAssertEqual(beeps, 1)
        XCTAssertTrue(terminals.keys.isEmpty)
        press(.transcript)
        XCTAssertEqual(beeps, 2)
        press(.alerts)
        XCTAssertEqual(environment.alertCycles, 1)
    }

    /// Im Reiter „Workspaces & Projekte“ fehlt die Tastenzeile: Was dort nicht
    /// steht, geht dort auch nicht (Buchstaben, W, R).
    func testCommandsOnlyInChatsTab() {
        window.workspaces = [ControllerWorkspaceChoice(
            id: UUID(), name: "W", colorHex: "#5E6AD2", chatCount: 1, hasWaitingChat: false, isCurrent: false)]
        press(K.tab)
        press(K.rightArrow, [.option, .function])
        press(.alerts)
        press(KeyboardIslandKeys.KeyCode.w)
        XCTAssertEqual(beeps, 2)
        XCTAssertEqual(environment.alertCycles, 0)
    }

    func testCheatSheet() {
        press(K.tab)
        press(44, [.option, .shift], "?")
        XCTAssertTrue(commands?.cheatSheet == true)
        press(K.space)
        XCTAssertEqual(beeps, 1, "Leertaste wirkt im Spickzettel nicht")
        releaseOption()
        XCTAssertTrue(window.commands.isEmpty, "⌥ los schließt nur")
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
    }

    /// B öffnet das Options-Menü direkt auf „Befehle ›“; es geht per Tastatur
    /// mit Pfeilen, Return und Esc, eine andere Taste schließt es und läuft weiter.
    func testCommandsMenuByKeyboard() {
        press(K.tab)
        press(.commands)
        XCTAssertFalse(dispatcher.isKeyboardIslandOpen)
        XCTAssertNotNil(ui.menu)
        XCTAssertTrue(ui.menuByKeyboard)
        XCTAssertNotNil(ui.menu?.submenu)
        releaseOption()
        XCTAssertNotNil(ui.menu, "⌥ loslassen lässt das Menü offen")
        XCTAssertTrue(press(K.downArrow, [.function]))
        XCTAssertTrue(press(K.escape, []))
        XCTAssertNotNil(ui.menu, "Esc: eine Ebene zurück")
        XCTAssertNil(ui.menu?.submenu)
        XCTAssertFalse(press(0, []), "Tippen schließt und läuft weiter")
        XCTAssertNil(ui.menu)
        XCTAssertFalse(ui.menuByKeyboard)
    }
}
