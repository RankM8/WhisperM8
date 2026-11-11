import Foundation
import XCTest
@testable import WhisperM8

@MainActor
private final class TerminalSpy: ControllerTerminalControlling {
    var states: [UUID: ControllerTerminalState] = [:]
    private(set) var keys: [TerminalControlKey] = []
    private(set) var cleared: [UUID] = []
    private(set) var scrolled: [Int] = []
    private(set) var texts: [(text: String, submit: Bool)] = []

    func state(of sessionID: UUID) -> ControllerTerminalState? { states[sessionID] }
    func sendKey(_ key: TerminalControlKey, to sessionID: UUID) -> Bool { keys.append(key); return true }
    func clearComposer(of sessionID: UUID) { cleared.append(sessionID) }
    func scroll(lines: Int, in sessionID: UUID) { scrolled.append(lines) }
    func sendText(_ text: String, submit: Bool, to sessionID: UUID) -> Bool {
        texts.append((text, submit))
        return true
    }
}

@MainActor
private final class DictationSpy: ControllerDictationControlling {
    var phase: ControllerRecordingPhase?
    var isQuickActionRunning = false
    var targetSessionID: UUID?
    private(set) var started: [DictationDeliveryTarget] = []
    private(set) var stopped: [Bool] = []
    private(set) var cancelCount = 0
    private(set) var modeSteps: [Int] = []

    private(set) var labels: [String?] = []
    func start(target: DictationDeliveryTarget, label: String?) {
        started.append(target); labels.append(label); phase = .recording
        if case let .agentChat(id) = target { targetSessionID = id }
    }
    func stop(submit: Bool) { stopped.append(submit); phase = .transcribing; targetSessionID = nil }
    func cancel() { cancelCount += 1; phase = nil }
    func stepOutputMode(_ step: Int) { modeSteps.append(step) }
}

@MainActor
private final class EnvironmentSpy: ControllerAppEnvironment {
    var isAppActive = true
    var hasOtherKeyWindow = false
    var isModalOpen = false
    var isClipboardPanelOpen = false
    private(set) var clipboardToggles = 0
    private(set) var clipboardCommands: [ControllerClipboardCommand] = []
    private(set) var broughtToFront = 0
    private(set) var bridgeKeys: [ControllerBridgeKey] = []
    private(set) var openedSettings = 0

    func toggleClipboardPanel() { clipboardToggles += 1 }
    func clipboard(_ command: ControllerClipboardCommand) { clipboardCommands.append(command) }
    func bringAgentChatsToFront() { broughtToFront += 1 }
    func postBridgeKey(_ key: ControllerBridgeKey) { bridgeKeys.append(key) }
    func openControllerSettings() { openedSettings += 1 }
}

/// Fenster-Attrappe am Befehls-Katalog.
@MainActor
private final class WindowFake {
    let id = UUID()
    var selected: UUID? = UUID()
    var isGridActive = false
    var isSwitcherOpen = false
    var hasSheet = false
    var isSidebarVisible = true
    var hasMultiSelection = false
    var rows: [AgentChatsListRow] = []
    /// Befehle, die „ging nicht“ melden sollen.
    var failing: Set<String> = []
    private(set) var commands: [AgentChatsCommand] = []

    var handler: AgentChatsCommandCenter.Handler {
        AgentChatsCommandCenter.Handler(
            perform: { [unowned self] command in
                commands.append(command)
                switch command {
                case .switcherBegin: isSwitcherOpen = true
                case .switcherCommit, .switcherCancel: isSwitcherOpen = false
                case .setSidebarVisible(let visible): isSidebarVisible = visible
                case .clearMultiSelection: hasMultiSelection = false
                case .selectSession(let id): selected = id
                default: break
                }
                return !failing.contains(String(describing: command))
            },
            snapshot: { [unowned self] in
                AgentChatsWindowSnapshot(
                    windowID: id, isKeyWindow: true, selectedSessionID: selected,
                    isGridActive: isGridActive, canReturnToWorkspace: false,
                    isSwitcherOpen: isSwitcherOpen, hasSheet: hasSheet,
                    isSidebarVisible: isSidebarVisible, hasMultiSelection: hasMultiSelection,
                    isArchiveMode: false)
            },
            listRows: { [unowned self] in rows }
        )
    }
}

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
            ui: ui, now: { [unowned self] in clock })
        dispatcher.playHaptic = { [unowned self] in haptics.append($0) }
        setTerminal(status: .idle)
    }

    private func setTerminal(
        status: AgentSessionRuntimeStatus?, running: Bool = true,
        profile: ControllerChatState.Profile = .claude, draft: Bool = false,
        statusSince: Date? = nil, lastEnter: Date? = nil, lastEscape: Date? = nil
    ) {
        guard let selected = window.selected else { return }
        terminals.states[selected] = ControllerTerminalState(
            isRunning: running, profile: profile, status: status, statusSince: statusSince,
            draftSuspected: draft, lastEnterAt: lastEnter, lastEscapeAt: lastEscape)
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
        perform(.tab(step: 1))
        XCTAssertEqual(window.commands.last, .nextTab)
    }

    // MARK: - Tasten in den Chat

    func testChatKeysGoToTheSelectedTerminal() {
        perform(.chatKey(.enter))
        perform(.chatKey(.up))
        perform(.chatInterrupt)
        XCTAssertEqual(terminals.keys, [.enter, .up, .escape])
    }

    func testClearComposerAndScroll() {
        perform(.chatClearComposer)
        perform(.scroll(lines: -3))
        XCTAssertEqual(terminals.cleared, [window.selected!])
        XCTAssertEqual(terminals.scrolled, [-3])
    }

    func testNothingIsSentWithoutSelection() {
        window.selected = nil
        dispatcher.perform(.chatKey(.enter), in: .list)
        XCTAssertEqual(terminals.keys, [])
    }

    // MARK: - Navigation

    func testTabsAndLastChat() {
        perform(.tab(step: -1))
        perform(.tab(step: 1))
        perform(.lastChat)
        XCTAssertEqual(window.commands, [.previousTab, .nextTab, .lastChat])
    }

    func testFailedJumpGivesRejectFeedback() {
        window.failing = [String(describing: AgentChatsCommand.nextWaitingChat)]
        perform(.nextWaitingChat)
        XCTAssertEqual(haptics, [.rejected])
    }

    func testNextWaitingFromOtherWindowBringsAgentChatsToFront() {
        keyWindowID = nil
        environment.hasOtherKeyWindow = true
        perform(.nextWaitingChat)
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
        perform(.tab(step: 1))
        XCTAssertEqual(window.commands, [.clearMultiSelection, .nextTab])
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

    func testFilterAndNewChatInMarkedProject() {
        let ids = makeRows()
        perform(.moveInContent(.left))
        perform(.listFilter(step: 1))
        XCTAssertEqual(window.commands.last, .sidebarFilter(step: 1))
        perform(.listMove(step: 1))
        perform(.newChat)
        XCTAssertEqual(window.commands.last, .newChat(projectID: ids.project))
        XCTAssertEqual(ui.area, .content)
    }

    func testNewChatInContentUsesCurrentProject() {
        perform(.newChat)
        XCTAssertEqual(window.commands.last, .newChatInCurrentProject)
    }

    func testLeaveListClearsMarker() {
        _ = makeRows()
        perform(.moveInContent(.left))
        perform(.leaveList)
        XCTAssertEqual(ui.area, .content)
        XCTAssertNil(ui.markedRow)
    }

    // MARK: - Chat-Auswahl

    func testPickerOpensMovesAndCommits() {
        perform(.pickerBegin)
        XCTAssertEqual(context, .chatPicker)
        perform(.pickerMove(.down))
        perform(.pickerCommit)
        XCTAssertEqual(window.commands, [.switcherBegin, .switcherMove(.down), .switcherCommit])
        guard case .chat = context else { return XCTFail("nach dem Schließen wieder chat") }
    }

    func testPickerWithTooFewChatsIsRejected() {
        window.failing = [String(describing: AgentChatsCommand.switcherBegin)]
        perform(.pickerBegin)
        XCTAssertEqual(haptics, [.rejected])
    }

    /// Ein per Tastatur geöffneter Umschalter gehört der Tastatur: Die erste
    /// Controller-Eingabe schließt ihn.
    func testKeyboardSwitcherIsCancelledByControllerInput() {
        window.isSwitcherOpen = true
        guard case .chat = context else { return XCTFail("chat erwartet") }
        XCTAssertEqual(window.commands, [], "Der Schnappschuss allein schließt nichts")
        perform(.tab(step: 1))
        XCTAssertEqual(window.commands, [.switcherCancel, .nextTab])
    }

    func testRefreshLeavesKeyboardSwitcherAlone() {
        window.isSwitcherOpen = true
        dispatcher.refreshContext()
        XCTAssertEqual(window.commands, [])
        XCTAssertTrue(window.isSwitcherOpen)
    }

    func testPickerCommitAndDictateTargetsTheChosenChat() {
        perform(.pickerBegin)
        perform(.pickerCommitAndDictate)
        XCTAssertEqual(window.commands.suffix(1), [.switcherCommit])
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: window.selected!)])
    }

    // MARK: - Diktat

    func testDictationInChatTargetsSelectedChat() {
        dispatcher.titleForSession = { _ in "Mein Chat" }
        perform(.dictationToggle)
        XCTAssertEqual(dictation.labels, ["Mein Chat"], "Die Pill zeigt das Ziel")
        XCTAssertEqual(dictation.started, [.agentChat(sessionID: window.selected!)])
        XCTAssertEqual(haptics, [.recordingStarted])
        XCTAssertEqual(context, .recording(phase: .recording, targetIsChat: true))
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
        XCTAssertEqual(ui.menu?.selected, .slashCommands)
        perform(.menuToggle)
        XCTAssertNil(ui.menu)
    }

    func testMenuItemsWriteIntoTheChat() {
        perform(.menuToggle)
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.count, 1)
        XCTAssertEqual(terminals.texts.first?.submit, true)
        XCTAssertNil(ui.menu, "Nach der Wahl schließt das Menü")

        perform(.menuToggle)
        perform(.menuMove(step: 1))
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.last?.text, "/")
        XCTAssertEqual(terminals.texts.last?.submit, false)
    }

    /// Bei offener Rückfrage läuft kein Text in den Chat.
    func testMenuSkipsTextItemsWhileQuestionIsOpen() {
        setTerminal(status: .awaitingInput, statusSince: clock.addingTimeInterval(-5))
        perform(.menuToggle)
        XCTAssertEqual(ui.menu?.selected, .closeTab, "nichts, was in die Rückfrage schreibt")
        XCTAssertTrue(ui.menuDialogOpen)
        ui.menu?.selected = .cycleMode
        perform(.menuActivate)
        XCTAssertEqual(terminals.keys, [], "Shift+Tab nie in eine Rückfrage")
        XCTAssertEqual(terminals.texts.count, 0)
        XCTAssertEqual(haptics, [.rejected])
    }

    /// „Weiter“ würde an einen Entwurf angehängt und beides gesendet.
    func testContinueIsRejectedWithDraft() {
        setTerminal(status: .idle, draft: true)
        perform(.menuToggle)
        perform(.menuActivate)
        XCTAssertEqual(terminals.texts.count, 0)
        XCTAssertEqual(haptics, [.rejected])
    }

    /// In einer Shell wäre der diktierte Text ein Befehl: Kreuz beendet dort
    /// nur, sendet nie.
    func testStopAndSubmitOnlyForClaudeAndCodex() {
        setTerminal(status: .idle, profile: .shell)
        perform(.dictationToggle)
        XCTAssertEqual(context, .recording(phase: .recording, targetIsChat: false))
        dispatcher.perform(.dictationStopAndSubmit, in: context)
        XCTAssertEqual(dictation.stopped, [false])
    }

    func testCloseControllerUIClosesPickerMenuListAndRing() {
        window.rows = [AgentChatsListRow(row: .chat(window.selected!))]
        perform(.pickerBegin)
        perform(.menuToggle)
        perform(.holdProgress(.circle, duration: 0.4))
        dispatcher.closeControllerUI()
        XCTAssertEqual(window.commands.last, .switcherCancel)
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

    func testMenuCloseTabAndSettingsAndPause() {
        var pauses = 0
        dispatcher.togglePause = { pauses += 1 }
        for item in [ControllerMenuItem.closeTab, .showBindings, .pause] {
            perform(.menuToggle)
            ui.menu?.selected = item
            perform(.menuActivate)
        }
        XCTAssertEqual(window.commands.last, .closeSelectedTab)
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
