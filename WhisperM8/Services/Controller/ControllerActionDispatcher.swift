import Foundation

/// Führt die Aktionen der Controller-Steuerung aus und liefert den Zustand der
/// App, aus dem die Belegung den Zusammenhang bestimmt.
///
/// Der Ausführer kennt keine Tasten — die Zuordnung Taste → Aktion liegt im
/// puren `ControllerBindingResolver`. Hier steht nur, was eine Aktion in der
/// App bewirkt.
@MainActor
final class ControllerActionDispatcher: ControllerActionPerforming {
    private let chats: AgentChatsCommandCenter
    private let terminals: ControllerTerminalControlling
    private let dictation: ControllerDictationControlling
    private let environment: ControllerAppEnvironment
    let ui: ControllerUIModel
    private let now: () -> Date

    /// Rückmeldung am Controller (Vibration). Gesetzt vom Aufbau der Live-Kette.
    var playHaptic: (ControllerHapticPattern) -> Void = { _ in }
    var togglePause: () -> Void = {}
    /// Angaben des Debug-Kanals (Test-Instanz ohne aktives Fenster).
    var debugOverride: () -> ControllerDebugOverride? = { nil }

    /// Die laufende Aufnahme geht in einen Chat (dann darf Kreuz „fertig und
    /// senden“ sein).
    private var recordingTargetIsChat = false
    /// Der offene Umschalter wurde vom Controller geöffnet.
    private var pickerOpenedByController = false

    /// So lange nach einem Enter vom Controller gilt der Chat als „gerade
    /// gesendet“: Der Status meldet „arbeitet“ erst mit Verzögerung.
    static let recentlySubmittedWindow: TimeInterval = 3
    /// Ein zweites Escape in dieser Zeit wird verschluckt.
    static let escapeRepeatWindow: TimeInterval = 1

    init(
        chats: AgentChatsCommandCenter,
        terminals: ControllerTerminalControlling,
        dictation: ControllerDictationControlling,
        environment: ControllerAppEnvironment,
        ui: ControllerUIModel,
        now: @escaping () -> Date = Date.init
    ) {
        self.chats = chats
        self.terminals = terminals
        self.dictation = dictation
        self.environment = environment
        self.ui = ui
        self.now = now
    }

    // MARK: - Zustand

    /// Fenster, auf das Aktionen wirken: das aktive Agent-Chats-Fenster, oder
    /// das vom Debug-Kanal genannte.
    private var targetWindowID: UUID? {
        debugOverride()?.windowID ?? chats.activeWindowID
    }

    /// Ausdrückliches Ziel nur im Debug-Fall; sonst routet der Katalog selbst
    /// zum Key-Fenster und prüft, ob es wirklich Key ist.
    private var explicitWindowID: UUID? { debugOverride()?.windowID }

    /// Zustand im Moment einer Controller-Eingabe.
    func snapshot() -> ControllerAppSnapshot {
        makeSnapshot(forInput: true)
    }

    /// Zusammenhang neu bestimmen, ohne dass eine Eingabe kam (Legende nach
    /// Statuswechsel, Auswahl per Maus). Lässt einen Tastatur-Umschalter in Ruhe.
    func refreshContext() {
        _ = makeSnapshot(forInput: false)
    }

    private func makeSnapshot(forInput: Bool) -> ControllerAppSnapshot {
        var snapshot = ControllerAppSnapshot()
        snapshot.appIsActive = debugOverride()?.assumeFrontmost == true || environment.isAppActive
        snapshot.recordingPhase = dictation.phase
        snapshot.recordingTargetIsChat = recordingTargetIsChat
        snapshot.quickActionRunning = dictation.isQuickActionRunning
        snapshot.clipboardPanelOpen = environment.isClipboardPanelOpen

        guard let windowID = targetWindowID, var window = chats.snapshot(of: windowID) else {
            snapshot.window = environment.hasOtherKeyWindow ? .other : .none
            publish(snapshot)
            return snapshot
        }
        snapshot.window = .agentChats

        // Ein per Tastatur geöffneter Umschalter gehört der Tastatur: Die erste
        // Controller-Eingabe schließt ihn.
        if forInput, window.isSwitcherOpen, !pickerOpenedByController {
            chats.perform(.switcherCancel, in: windowID)
            window.isSwitcherOpen = false
        }
        if !window.isSwitcherOpen { pickerOpenedByController = false }

        snapshot.chatPickerOpen = window.isSwitcherOpen && pickerOpenedByController
        snapshot.controllerMenuOpen = ui.menu != nil
        snapshot.modalOpen = window.hasSheet || environment.isModalOpen
        let listHasFocus = ui.area == .list && ui.listWindowID == windowID && window.isSidebarVisible
        snapshot.area = listHasFocus ? .list : .content
        snapshot.chat = chatState(in: window)
        publish(snapshot)
        return snapshot
    }

    private func chatState(in window: AgentChatsWindowSnapshot) -> ControllerChatState? {
        guard let sessionID = window.selectedSessionID else { return nil }
        guard let terminal = terminals.state(of: sessionID) else {
            return ControllerChatState(status: .ended, profile: .other, gridActive: window.isGridActive, hasTerminal: false)
        }
        let moment = now()
        let status: ControllerChatState.Status
        switch terminal.status {
        case .working: status = .working
        case .awaitingInput: status = .awaitingInput
        case .idle: status = .idle
        case .stopped, .errored: status = .ended
        case nil: status = .unknown
        }
        func within(_ seconds: TimeInterval, of date: Date?) -> Bool {
            date.map { moment.timeIntervalSince($0) < seconds } ?? false
        }
        return ControllerChatState(
            status: terminal.isRunning ? status : .ended,
            profile: terminal.profile,
            draftSuspected: terminal.draftSuspected,
            recentlySubmitted: within(Self.recentlySubmittedWindow, of: terminal.lastEnterAt),
            secondsSinceAwaitingBegan: status == .awaitingInput
                ? terminal.statusSince.map { moment.timeIntervalSince($0) } : nil,
            escapeSentRecently: within(Self.escapeRepeatWindow, of: terminal.lastEscapeAt),
            gridActive: window.isGridActive,
            hasTerminal: terminal.isRunning
        )
    }

    /// Zusammenhang für die Legende festhalten (nur bei Änderung).
    private func publish(_ snapshot: ControllerAppSnapshot) {
        var snapshot = snapshot
        snapshot.isPaused = false
        let context = ControllerContextResolver.context(for: snapshot)
        if ui.context != context { ui.context = context }
        let dialogOpen = snapshot.chat?.status == .awaitingInput
        if ui.menu != nil, ui.menuDialogOpen != dialogOpen {
            ui.menuDialogOpen = dialogOpen
            ui.menu?.normalize(dialogOpen: dialogOpen)
        }
    }

    // MARK: - Ausführen

    func perform(_ action: ControllerAction, in context: ControllerContext) {
        clearMultiSelectionIfNeeded(before: action)
        switch action {
        // Diktat
        case .dictationToggle: toggleDictation(in: context)
        case .dictationStopAndSubmit: stopDictation(submit: true)
        case .dictationCancel: dictation.cancel()
        case let .outputMode(step): dictation.stepOutputMode(step)

        // Chat
        case let .chatKey(key): sendKey(key.terminalKey)
        case .chatInterrupt: sendKey(.escape)
        case .chatClearComposer: withSelectedSession { terminals.clearComposer(of: $0) }
        case .nextWaitingChat: nextWaitingChat(in: context)
        case .lastChat: command(.lastChat, orReject: true)
        case let .tab(step): command(step < 0 ? .previousTab : .nextTab, orReject: false)
        case let .moveInContent(direction): moveInContent(direction)
        case .newChat: newChat()
        case .toggleMaximize: command(.toggleMaximize, orReject: true)
        case let .scroll(lines): withSelectedSession { terminals.scroll(lines: lines, in: $0) }

        // Liste links
        case .enterList: enterList()
        case .leaveList: ui.leaveList()
        case let .listMove(step): moveInList(step)
        case .listActivate: activateMarkedRow()
        case let .listFilter(step): filterList(step)

        // Zwischenablage-Verlauf
        case .clipboardToggle: environment.toggleClipboardPanel()
        case let .clipboard(command): environment.clipboard(command)

        // Menü
        case .menuToggle: toggleMenu(in: context)
        case let .menuMove(step): ui.menu?.move(step, dialogOpen: ui.menuDialogOpen)
        case .menuActivate: activateMenuItem()

        // Chat-Auswahl
        case .pickerBegin: beginPicker()
        case let .pickerMove(direction): command(.switcherMove(direction.gridDirection), orReject: false)
        case .pickerCommit: finishPicker(.switcherCommit)
        case .pickerCancel: finishPicker(.switcherCancel)
        case .pickerCommitAndDictate:
            finishPicker(.switcherCommit)
            startDictation(target: chatTarget() ?? .frontApp)

        // Sonstiges
        case let .bridgeKey(key): environment.postBridgeKey(key)
        case .pauseToggle: togglePause()
        case .bringAppToFront: environment.bringAgentChatsToFront()
        case .rejected: playHaptic(.rejected)
        case let .holdProgress(button, duration):
            ui.holdProgress = ControllerHoldProgress(button: button, startedAt: now(), duration: duration)
        case .holdProgressCancelled:
            ui.holdProgress = nil
        }
        // Ein beendetes Halten braucht keinen Ring mehr.
        if case .holdProgress = action {} else if case .holdProgressCancelled = action {} else {
            ui.holdProgress = nil
        }
    }

    // MARK: - Befehle an das Fenster

    @discardableResult
    private func command(_ command: AgentChatsCommand, orReject: Bool) -> Bool {
        let done = chats.perform(command, in: explicitWindowID)
        if !done, orReject { playHaptic(.rejected) }
        return done
    }

    private var selectedSessionID: UUID? {
        targetWindowID.flatMap { chats.snapshot(of: $0) }?.selectedSessionID
    }

    private func withSelectedSession(_ body: (UUID) -> Void) {
        guard let sessionID = selectedSessionID else { return }
        body(sessionID)
    }

    private func sendKey(_ key: TerminalControlKey) {
        withSelectedSession { terminals.sendKey(key, to: $0) }
    }

    /// Jede Controller-Aktion im Fenster hebt eine Mehrfachauswahl zuerst auf.
    private func clearMultiSelectionIfNeeded(before action: ControllerAction) {
        switch action {
        case .holdProgress, .holdProgressCancelled, .rejected, .pauseToggle, .bringAppToFront,
             .clipboard, .clipboardToggle, .bridgeKey:
            return
        default:
            break
        }
        guard let windowID = targetWindowID, chats.snapshot(of: windowID)?.hasMultiSelection == true else { return }
        chats.perform(.clearMultiSelection, in: windowID)
    }

    private func nextWaitingChat(in context: ControllerContext) {
        // Aus einem anderen Fenster oder ohne Fenster: erst das
        // Agent-Chats-Fenster nach vorn holen.
        if targetWindowID == nil {
            environment.bringAgentChatsToFront()
            return
        }
        if command(.nextWaitingChat, orReject: true) { ui.leaveList() }
    }

    /// Linker Stick im Inhalt: im Raster von Kachel zu Kachel; nach links am
    /// Rand (oder in der Einzelansicht) geht es in die Liste.
    private func moveInContent(_ direction: ControllerDirection) {
        guard let windowID = targetWindowID, let window = chats.snapshot(of: windowID) else { return }
        if window.isGridActive, command(.gridFocus(direction.gridDirection), orReject: false) { return }
        if direction == .left { enterList() }
    }

    private func newChat() {
        if ui.area == .list, let marked = ui.markedRow,
           let projectID = currentListRows().first(where: { $0.row == marked })?.projectID {
            command(.newChat(projectID: projectID), orReject: true)
        } else {
            command(.newChatInCurrentProject, orReject: true)
        }
        ui.leaveList()
    }

    // MARK: - Liste links

    private func currentListRows() -> [AgentChatsListRow] {
        targetWindowID.map { chats.listRows(of: $0) } ?? []
    }

    private func enterList() {
        guard let windowID = targetWindowID else { return }
        command(.setSidebarVisible(true), orReject: false)
        let rows = currentListRows().map(\.row)
        guard !rows.isEmpty else {
            playHaptic(.rejected)
            return
        }
        ui.listModel = SidebarNavigationModel(rows: rows)
        ui.listModel.start(at: chats.snapshot(of: windowID)?.selectedSessionID)
        ui.listWindowID = windowID
        ui.markedRow = ui.listModel.marked
        ui.area = .list
    }

    private func moveInList(_ step: Int) {
        ui.listModel.setRows(currentListRows().map(\.row))
        ui.listModel.move(step)
        if ui.markedRow != ui.listModel.marked { ui.markedRow = ui.listModel.marked }
    }

    private func activateMarkedRow() {
        guard let marked = ui.markedRow,
              let row = currentListRows().first(where: { $0.row == marked }) else { return }
        let done: Bool
        switch row.row {
        case let .chat(sessionID), let .workspaceChat(sessionID, _):
            done = command(.selectSession(sessionID), orReject: true)
        case let .workspace(workspaceID):
            done = command(.activateWorkspace(workspaceID), orReject: true)
        case let .project(projectID):
            done = command(.openProjectAsWorkspace(projectID, activeSessionIDs: row.activeSessionIDs), orReject: true)
        }
        if done { ui.leaveList() }
    }

    private func filterList(_ step: Int) {
        guard command(.sidebarFilter(step: step), orReject: true) else { return }
        ui.listModel.setRows(currentListRows().map(\.row))
        if ui.markedRow != ui.listModel.marked { ui.markedRow = ui.listModel.marked }
    }

    // MARK: - Chat-Auswahl (L2)

    private func beginPicker() {
        pickerOpenedByController = command(.switcherBegin, orReject: true)
    }

    private func finishPicker(_ command: AgentChatsCommand) {
        self.command(command, orReject: false)
        pickerOpenedByController = false
    }

    // MARK: - Diktat

    /// Der ausgewählte Chat des aktiven Fensters als Ziel, sofern er läuft.
    private func chatTarget() -> DictationDeliveryTarget? {
        guard let sessionID = selectedSessionID, terminals.state(of: sessionID)?.isRunning == true else { return nil }
        return .agentChat(sessionID: sessionID)
    }

    private func toggleDictation(in context: ControllerContext) {
        if dictation.phase == .recording {
            stopDictation(submit: false)
            return
        }
        guard dictation.phase == nil else {
            playHaptic(.rejected)
            return
        }
        // In die Liste oder den Chat diktiert geht der Text in den Chat. In
        // Dialogen, Textfeldern, anderen Fenstern und außerhalb der App ins
        // Feld mit dem Fokus, wie beim Hotkey.
        var target = DictationDeliveryTarget.frontApp
        switch context {
        case .chat, .list: target = chatTarget() ?? .frontApp
        default: break
        }
        startDictation(target: target)
    }

    private func startDictation(target: DictationDeliveryTarget) {
        guard dictation.phase == nil else { return }
        recordingTargetIsChat = target != .frontApp
        dictation.start(target: target)
        playHaptic(.recordingStarted)
    }

    private func stopDictation(submit: Bool) {
        dictation.stop(submit: submit && recordingTargetIsChat)
        playHaptic(.recordingStopped)
    }

    // MARK: - Menü (Options)

    private func toggleMenu(in context: ControllerContext) {
        if ui.menu != nil {
            ui.menu = nil
            return
        }
        var menu = ControllerMenuModel()
        var dialogOpen = false
        if case let .chat(state) = context { dialogOpen = state.status == .awaitingInput }
        menu.normalize(dialogOpen: dialogOpen)
        ui.menuDialogOpen = dialogOpen
        ui.menu = menu
    }

    private func activateMenuItem() {
        guard let menu = ui.menu else { return }
        let item = menu.selected
        guard ControllerMenuModel.isEnabled(item, dialogOpen: ui.menuDialogOpen) else {
            playHaptic(.rejected)
            return
        }
        ui.menu = nil
        switch item {
        case .continueWork:
            withSelectedSession { terminals.sendText(ControllerMenuText.continueWork, submit: true, to: $0) }
        case .slashCommands:
            withSelectedSession { terminals.sendText("/", submit: false, to: $0) }
        case .cycleMode:
            sendKey(.backTab)
        case .compact:
            withSelectedSession { terminals.sendText("/compact", submit: false, to: $0) }
        case .closeTab:
            command(.closeSelectedTab, orReject: true)
        case .showBindings:
            environment.openControllerSettings()
        case .pause:
            togglePause()
        }
    }
}

/// Texte, die das Menü in einen Chat schreibt.
enum ControllerMenuText {
    /// Folgt der Sprache der App: „Weiter“ bzw. „Continue“.
    static var continueWork: String { String(localized: "Continue") }
}

private extension ControllerChatKey {
    var terminalKey: TerminalControlKey {
        switch self {
        case .enter: return .enter
        case .escape: return .escape
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}

private extension ControllerDirection {
    var gridDirection: GridFocusDirection {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}
