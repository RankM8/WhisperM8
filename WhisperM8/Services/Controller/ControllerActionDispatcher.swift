import Foundation

/// Führt die Aktionen der Controller-Steuerung aus und liefert den Zustand der
/// App, aus dem die Belegung den Zusammenhang bestimmt.
///
/// Der Ausführer kennt keine Tasten — die Zuordnung Taste → Aktion liegt im
/// puren `ControllerBindingResolver`. Hier steht nur, was eine Aktion in der
/// App bewirkt.
@MainActor
final class ControllerActionDispatcher: ControllerActionPerforming {
    // `internal`, weil die Insel in `ControllerActionDispatcher+Island.swift` liegt.
    let chats: AgentChatsCommandCenter
    let terminals: ControllerTerminalControlling
    let dictation: ControllerDictationControlling
    let environment: ControllerAppEnvironment
    let ui: ControllerUIModel
    let island: ControllerIslandPresenting
    let now: () -> Date

    /// Rückmeldung am Controller (Vibration). Gesetzt vom Aufbau der Live-Kette.
    var playHaptic: (ControllerHapticPattern) -> Void = { _ in }
    var togglePause: () -> Void = {}
    /// Angaben des Debug-Kanals (Test-Instanz ohne aktives Fenster).
    var debugOverride: () -> ControllerDebugOverride? = { nil }
    /// Titel eines Chats für Legende und Menü.
    var titleForSession: (UUID) -> String? = { _ in nil }
    /// Zeilen des Reiters „Chats“ der Insel für diese Chats in dieser
    /// Reihenfolge (Titel, Projekt, Status, „wartet · 2 min“). Im
    /// Ereignis-Pfad gebaut, wenn „Wohin“ aufgeht.
    var islandChatRows: (_ order: [UUID], _ current: UUID?) -> [ControllerIslandChatRow] = { _, _ in [] }
    /// Zwischenablage-Verlauf für L1 + Kreuz (Runde 5).
    var clipboard = ControllerClipboardAccess()
    /// Zuletzt geschlossene Chats für L2 + Viereck (Runde 5).
    var closedChats = ControllerClosedChatsAccess()
    /// Letzter Verbrauch eines Kontos (5 Std., Woche) für das Konto-Menü.
    var accountLimit: (ControllerAccountChoice.Kind, String) -> (fiveHour: Double?, week: Double?)? = { _, _ in nil }
    /// Stößt den passiven Abruf der Limits an, wenn der Stand alt ist.
    var refreshAccountLimits: () -> Void = {}
    /// Status eines Chats für den Kopf der Insel.
    var islandStatus: (UUID) -> ControllerIslandStatus? = { _ in nil }
    /// Limits aller Konten für Kopf und Limits-Karte der R1-Insel (Insel-Paket).
    var limits = ControllerLimitsAccess()

    /// Offene Insel: Ebene, Inhalt und der Chat, für den sie aufging.
    var islandState: ControllerIslandSession?
    /// Ebene, deren Insel eine Aktion schon geschlossen hat (Schnellbefehl,
    /// Wechsel, Abbruch): bis zum Loslassen der Taste bleibt sie zu.
    var spentLayer: ControllerLayer?
    /// Zählt Schließ-Vorgänge, damit ein verzögertes Schließen (Markierung
    /// eines Schnellbefehls) eine neu geöffnete Insel nicht trifft.
    var islandGeneration = 0
    /// Chat, dessen Eingabe R3 halten leert — gebunden beim Haltebeginn, damit
    /// ein Chatwechsel während des Haltens nicht den falschen Chat leert.
    private var clearInputTarget: UUID?

    /// So lange nach einem Enter vom Controller gilt der Chat als „gerade
    /// gesendet“: Der Status meldet „arbeitet“ erst mit Verzögerung.
    static let recentlySubmittedWindow: TimeInterval = 3
    /// Ein zweites Escape in dieser Zeit wird verschluckt.
    static let escapeRepeatWindow: TimeInterval = 1
    /// In einer erkannten Ansicht genügt eine kürzere Sperre (Runde 5).
    static let escapeInViewWindow: TimeInterval = 0.3
    /// So lange nach einer Eingabe ins Feld (Rücktaste, Diktat, Text ohne
    /// Senden) darf Kreuz auch bei arbeitendem Chat Enter schicken. 30 s
    /// reichen, um einen diktierten Entwurf zu überfliegen; ein Entwurf von
    /// vor Minuten hält Kreuz dagegen nicht mehr scharf für eine Freigabe, die
    /// erst später erscheint.
    static let draftInputWindow: TimeInterval = 30

    init(
        chats: AgentChatsCommandCenter,
        terminals: ControllerTerminalControlling,
        dictation: ControllerDictationControlling,
        environment: ControllerAppEnvironment,
        ui: ControllerUIModel,
        island: ControllerIslandPresenting,
        now: @escaping () -> Date = Date.init
    ) {
        self.chats = chats
        self.terminals = terminals
        self.dictation = dictation
        self.environment = environment
        self.ui = ui
        self.island = island
        self.now = now
    }

    // MARK: - Zustand

    /// Fenster, auf das Aktionen wirken: das aktive Agent-Chats-Fenster, oder
    /// das vom Debug-Kanal genannte.
    var targetWindowID: UUID? {
        debugOverride()?.windowID ?? chats.activeWindowID
    }

    /// Ausdrückliches Ziel nur im Debug-Fall; sonst routet der Katalog selbst
    /// zum Key-Fenster und prüft, ob es wirklich Key ist.
    var explicitWindowID: UUID? { debugOverride()?.windowID }

    /// Zustand im Moment einer Controller-Eingabe. Ohne Nebenwirkung — auch
    /// Trockenläufe und eine pausierte Steuerung ziehen ihn.
    func snapshot() -> ControllerAppSnapshot {
        var snapshot = ControllerAppSnapshot()
        snapshot.appIsActive = debugOverride()?.assumeFrontmost == true || environment.isAppActive
        snapshot.recordingPhase = dictation.phase
        snapshot.recordingTargetIsChat = submitAllowed(to: dictation.targetSessionID)
        snapshot.recordingTargetBound = dictation.phase != nil && dictation.targetSessionID != nil
        snapshot.quickActionRunning = dictation.isQuickActionRunning
        snapshot.clipboardPanelOpen = environment.isClipboardPanelOpen
        if snapshot.clipboardPanelOpen { snapshot.clipboard = environment.clipboardState }

        guard let windowID = targetWindowID, var window = chats.snapshot(of: windowID) else {
            snapshot.window = environment.hasOtherKeyWindow ? .other : .none
            publish(snapshot)
            return snapshot
        }
        snapshot.window = .agentChats
        snapshot.controllerMenuOpen = ui.menu != nil
        snapshot.modalOpen = window.hasSheet || window.ownsKeyOverlay || environment.isModalOpen
        let listHasFocus = ui.area == .list && ui.listWindowID == windowID && window.isSidebarVisible
        snapshot.area = listHasFocus ? .list : .content
        snapshot.chat = chatState(in: window)
        // Während eines gebundenen Diktats nennt die Legende dessen Ziel, nicht
        // die Auswahl: Die darf wechseln, der Text geht trotzdem dorthin.
        let titleSession = snapshot.recordingTargetBound ? dictation.targetSessionID : window.selectedSessionID
        let title = titleSession.flatMap(titleForSession)
        if ui.targetTitle != title { ui.targetTitle = title }
        publish(snapshot)
        return snapshot
    }

    func chatState(in window: AgentChatsWindowSnapshot) -> ControllerChatState? {
        guard let sessionID = window.selectedSessionID else { return nil }
        guard let terminal = terminals.state(of: sessionID) else {
            return ControllerChatState(status: .ended, profile: .other, gridActive: window.isGridActive,
                                       hasTerminal: false, backTarget: window.backTarget)
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
            fieldMayHaveText: terminal.fieldMayHaveText || terminal.draftSuspected,
            recentlySubmitted: within(Self.recentlySubmittedWindow, of: terminal.lastEnterAt),
            secondsSinceAwaitingBegan: status == .awaitingInput
                ? terminal.statusSince.map { moment.timeIntervalSince($0) } : nil,
            escapeSentRecently: within(Self.escapeRepeatWindow, of: terminal.lastEscapeAt),
            escapeSentJustNow: within(Self.escapeInViewWindow, of: terminal.lastEscapeAt),
            recentDraftInput: ControllerTerminalMarks.hasFreshDraftInput(
                draftAt: terminal.lastDraftInputAt, lastSubmitAt: terminal.lastEnterAt,
                window: Self.draftInputWindow, now: moment),
            recentArrowNavigation: ControllerTerminalMarks.hasFreshArrow(
                armedAt: terminal.lastArmingArrowAt, lastSubmitAt: terminal.lastEnterAt, now: moment),
            choiceListOpen: terminal.choiceListOpen,
            gridActive: window.isGridActive,
            hasTerminal: terminal.isRunning,
            shellAtPrompt: terminal.shellAtPrompt,
            backTarget: window.backTarget,
            openView: terminal.screen?.openView,
            promptField: terminal.screen?.promptField
        )
    }

    /// Zusammenhang für die Legende festhalten (nur bei Änderung).
    private func publish(_ snapshot: ControllerAppSnapshot) {
        var snapshot = snapshot
        snapshot.isPaused = false
        let context = ControllerContextResolver.context(for: snapshot)
        if ui.context != context { ui.context = context }
        let dialogOpen = snapshot.chat?.status == .awaitingInput
        if ui.menu != nil {
            if ui.menuDialogOpen != dialogOpen { ui.menuDialogOpen = dialogOpen }
            // Nur der Chat, für den das Menü offen ist, ändert seine Einträge.
            if ui.menu?.setup.acceptsInput == true, ui.menu?.setup.sessionID == selectedSessionID {
                ui.menu?.update(dialogOpen: dialogOpen, chatBusy: Self.isBusy(snapshot.chat))
            }
        }
    }

    /// Chat arbeitet, sein Zustand ist unklar oder es wurde gerade gesendet:
    /// „Weiter“ und „Modus wechseln“ sind dann aus (Rückfrage zählt extra).
    static func isBusy(_ chat: ControllerChatState?) -> Bool {
        guard let chat else { return true }
        return chat.status != .idle && chat.status != .awaitingInput || chat.recentlySubmitted
    }

    /// Zusammenhang neu bestimmen, ohne dass eine Eingabe kam (Legende nach
    /// Statuswechsel), und eine offene Insel nachführen. Die Insel hängt
    /// bewusst hier und nicht am Schnappschuss: Der bleibt ohne Fenster-
    /// Nebenwirkung, auch bei Trockenläufen des Debug-Kanals.
    func refreshContext() {
        let snapshot = snapshot()
        if islandState != nil { islandChatMayHaveChanged(snapshot.chat, sessionID: selectedSessionID) }
    }

    /// Schließt, was der Controller offen hat: Insel, Menü, Liste,
    /// Halte-Ring. Bei Pause, Trennung und Ausschalten.
    func closeControllerUI() {
        clearInputTarget = nil
        closeIsland()
        spentLayer = nil
        ui.menu = nil
        ui.leaveList()
        ui.holdProgress = nil
    }

    /// Darf eine Aufnahme in diesen Chat mit Kreuz auch gesendet werden? Nur
    /// bei Claude und Codex — in einer Shell wäre der Text ein Befehl.
    func submitAllowed(to sessionID: UUID?) -> Bool {
        guard let sessionID, let state = terminals.state(of: sessionID) else { return false }
        return state.profile == .claude || state.profile == .codex
    }

    // MARK: - Ausführen

    func perform(_ action: ControllerAction, in context: ControllerContext) {
        // Das Ende einer Ebene ohne offene Insel tut nichts — auch nicht den
        // Ctrl+Tab-Umschalter der Tastatur schließen.
        if action.isIslandEnd, islandState == nil {
            spentLayer = nil
            return
        }
        closeKeyboardSwitcherIfNeeded()
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
        case .chatResume: withSelectedSession { command(.startChat($0), orReject: true) }
        case .chatClearInput: clearInput()
        case .pasteNewest: pasteNewest()
        // Danach gleich neu lesen: Die Legende nennt sonst noch den Ort, an
        // dem man jetzt ist, als Ziel.
        case .lastChat: if command(.lastChat, orReject: true) { refreshContext() }
        case let .moveInContent(direction): moveInContent(direction)
        case let .adjacentChat(step): moveToAdjacentChat(step)
        case .newChat: newChat()
        case .toggleMaximize: command(.toggleMaximize, orReject: true)
        case let .scroll(lines): withSelectedSession { terminals.scroll(lines: lines, in: $0) }

        // Liste links
        case let .enterList(step): enterList(step: step)
        case .leaveList: ui.leaveList()
        case let .listMove(step): moveInList(step)
        case .listActivate: activateMarkedRow()
        case let .listFilter(step): filterList(step)
        case .listCloseRow: closeMarkedRow()
        case .listStartRow:
            // Nur gestoppte Chats; sonst still (R3 wird beim Scrollen leicht gedrückt).
            if let sessionID = ui.markedRow?.sessionID { command(.startChat(sessionID), orReject: false) }

        // Zwischenablage-Verlauf
        case .clipboardToggle:
            // L2 + Touchpad: Die Insel macht dem Verlauf Platz.
            spendIsland()
            environment.toggleClipboardPanel()
        case let .clipboard(command): environment.clipboard(command)

        // Menü
        case .menuToggle: toggleMenu(in: context)
        case let .menuMove(step): ui.menu?.move(step)
        case .menuActivate: activateMenuItem()
        case .menuBack:
            if ui.menu?.back() != true { ui.menu = nil }

        // Insel (L1, R1, L2 gehalten)
        case let .islandShow(layer): showIsland(layer)
        case .islandClose:
            closeIsland()
            spentLayer = nil
        case .islandRelease:
            // Loslassen wechselt nur im Chat. Hat inzwischen etwas anderes die
            // Eingaben (Aufnahme per Hotkey, Dialog, Sheet), nur schließen.
            if case .chat = context {
                releaseWhereTo()
            } else {
                closeIsland()
                spentLayer = nil
            }
        case .islandCancel: spendIsland(.whereTo)
        case let .islandMove(step): moveInWhereTo(step)
        case let .islandTab(step): switchWhereToTab(step)
        case .islandCommit: commitWhereTo(dictate: false)
        case .islandCommitAndDictate: commitWhereTo(dictate: true)
        case .islandNextWaiting: jumpToNextWaitingChat()
        case .islandReopenClosed: reopenClosedChat()
        case let .quickDraw(item): performQuickDraw(item)
        case let .appSlot(slot): performAppSlot(slot)
        case let .islandScroll(step): scrollLimitsCard(step)

        // Sonstiges
        case let .bridgeKey(key): environment.postBridgeKey(key)
        case .pauseToggle: togglePause()
        case .bringAppToFront: environment.bringAgentChatsToFront()
        case .rejected: playHaptic(.rejected)
        case let .holdProgress(button, duration):
            if button == .r3 { clearInputTarget = selectedSessionID }
            ui.holdProgress = ControllerHoldProgress(button: button, startedAt: now(), duration: duration)
        case let .holdProgressCancelled(button):
            if button == .r3 { clearInputTarget = nil }
            ui.holdProgress = nil
        }
        // Ein beendetes Halten braucht keinen Ring mehr.
        if case .holdProgress = action {} else if case .holdProgressCancelled = action {} else {
            ui.holdProgress = nil
        }
    }

    // MARK: - Befehle an das Fenster

    @discardableResult
    func command(_ command: AgentChatsCommand, orReject: Bool) -> Bool {
        let done = chats.perform(command, in: explicitWindowID)
        if !done, orReject { playHaptic(.rejected) }
        return done
    }

    var selectedSessionID: UUID? {
        targetWindowID.flatMap { chats.snapshot(of: $0) }?.selectedSessionID
    }

    private func withSelectedSession(_ body: (UUID) -> Void) {
        guard let sessionID = selectedSessionID else { return }
        body(sessionID)
    }

    private func sendKey(_ key: TerminalControlKey) {
        withSelectedSession { terminals.sendKey(key, to: $0) }
    }

    /// R3 halten: Eingabe des Chats leeren, der beim Haltebeginn ausgewählt
    /// war. Ist inzwischen ein anderer ausgewählt (L1/R1, Maus,
    /// Benachrichtigung), wird nichts geleert — wie bei den Menü-Eingaben.
    private func clearInput() {
        let target = clearInputTarget
        clearInputTarget = nil
        guard let target, target == selectedSessionID, terminals.clearInput(in: target) else {
            return playHaptic(.rejected)
        }
        playHaptic(.inputCleared)
    }

    /// Der Ctrl+Tab-Umschalter gehört der Tastatur (am Controller ersetzt ihn
    /// die Insel): Die erste ausgeführte Controller-Aktion schließt ihn. Erst
    /// hier, nicht im Schnappschuss — sonst beendete schon eine pausierte
    /// Steuerung oder leichtes Stick-Rauschen den Ctrl+Tab-Durchlauf.
    private func closeKeyboardSwitcherIfNeeded() {
        guard let windowID = targetWindowID,
              chats.snapshot(of: windowID)?.isSwitcherOpen == true else { return }
        chats.perform(.switcherCancel, in: windowID)
    }

    /// Jede Controller-Aktion im Fenster hebt eine Mehrfachauswahl zuerst auf.
    private func clearMultiSelectionIfNeeded(before action: ControllerAction) {
        switch action {
        case .holdProgress, .holdProgressCancelled, .rejected, .pauseToggle, .bringAppToFront,
             .clipboard, .clipboardToggle, .bridgeKey, .islandShow, .islandClose, .islandCancel,
             .islandMove, .islandTab, .appSlot, .islandScroll:
            return
        default:
            break
        }
        guard let windowID = targetWindowID, chats.snapshot(of: windowID)?.hasMultiSelection == true else { return }
        chats.perform(.clearMultiSelection, in: windowID)
    }

    /// Linker Stick im Inhalt: im Raster von Kachel zu Kachel; nach links am
    /// Rand (oder in der Einzelansicht) geht es in die Liste.
    private func moveInContent(_ direction: ControllerDirection) {
        guard let windowID = targetWindowID, let window = chats.snapshot(of: windowID) else { return }
        if window.isGridActive, command(.gridFocus(direction.gridDirection), orReject: false) { return }
        if direction == .left { enterList() }
    }

    /// Create: Projekt-Auswahl „Neuer Chat“ öffnen. In der Liste ist das
    /// Projekt der markierten Zeile vorausgewählt, sonst das aktuelle — so
    /// startet „Create, Kreuz“ einen Chat im selben Projekt.
    private func newChat() {
        var projectID: UUID?
        if ui.area == .list, let marked = ui.markedRow {
            projectID = currentListRows().first(where: { $0.row == marked })?.projectID
        }
        command(.showNewChatPicker(preferredProjectID: projectID), orReject: true)
        ui.leaveList()
    }

    /// L1/R1: voriger bzw. nächster Chat in der Reihenfolge der Liste links,
    /// ohne die Liste zu betreten.
    /// Im sichtbaren Workspace setzt die Auswahl den Kachel-Fokus. Am Rand
    /// gibt es „geht nicht“.
    private func moveToAdjacentChat(_ step: Int) {
        let selected = selectedSessionID
        // Beim Halten kommen zehn Schritte pro Sekunde: ein kurz
        // zurückliegender Stand der Zeilen genügt, solange der aktuelle Chat
        // darin steht.
        var rows = currentListRows(allowCached: true).map(\.row)
        if let selected, !rows.contains(where: { $0.sessionID == selected }) {
            rows = currentListRows().map(\.row)
        }
        guard let target = SidebarChatOrder.neighbor(of: selected, step: step, in: rows),
              command(.selectSession(target), orReject: false) else {
            playHaptic(.rejected)
            return
        }
    }

    // MARK: - Liste links

    /// Zeilen der Liste. Beim Bewegen genügt ein kurz zurückliegender Stand:
    /// Das Modell der Seitenleiste zu bauen kostet, und bei gehaltenem Stick
    /// kommen zehn Schritte pro Sekunde.
    private var listRowsCache: (rows: [AgentChatsListRow], at: Date)?

    func currentListRows(allowCached: Bool = false) -> [AgentChatsListRow] {
        if allowCached, let cache = listRowsCache, now().timeIntervalSince(cache.at) < 1.5 {
            return cache.rows
        }
        let rows = targetWindowID.map { chats.listRows(of: $0) } ?? []
        listRowsCache = (rows, now())
        return rows
    }

    /// Liste betreten: Markierung auf dem aktuellen Chat (bei Workspace-
    /// Mitgliedschaft dort), dann `step` Schritte weiter. Am Rand bleibt die
    /// Markierung stehen. Nichts wird ausgewählt — erst Kreuz öffnet.
    private func enterList(step: Int = 0) {
        guard let windowID = targetWindowID else { return }
        command(.setSidebarVisible(true), orReject: false)
        let rows = currentListRows().map(\.row)
        guard !rows.isEmpty else {
            playHaptic(.rejected)
            return
        }
        let selected = chats.snapshot(of: windowID)?.selectedSessionID
        ui.listModel = SidebarNavigationModel(rows: rows)
        ui.listModel.start(at: selected)
        // Nur vom aktuellen Chat aus weiterrücken. Steht er nicht in der
        // Liste (Filter), bleibt die Markierung auf der ersten Zeile.
        if step != 0, let selected, SidebarNavigationModel.preferredRow(of: selected, in: rows) != nil {
            ui.listModel.move(step)
        }
        ui.listWindowID = windowID
        ui.markedRow = ui.listModel.marked
        ui.area = .list
    }

    private func moveInList(_ step: Int) {
        ui.listModel.setRows(currentListRows(allowCached: true).map(\.row))
        ui.listModel.move(step)
        if ui.markedRow != ui.listModel.marked { ui.markedRow = ui.listModel.marked }
    }

    private func activateMarkedRow() {
        guard let marked = ui.markedRow,
              let row = currentListRows().first(where: { $0.row == marked }) else { return }
        let done: Bool
        switch row.row {
        case let .chat(sessionID):
            done = command(.selectSession(sessionID), orReject: true)
        case let .workspaceChat(sessionID, workspaceID):
            // Wie der Klick auf die Zeile: Ist der Workspace hier nicht
            // sichtbar, wechselt das Fenster hinein (Runde 3).
            done = command(.selectWorkspaceChat(sessionID, workspaceID: workspaceID), orReject: true)
        case let .workspace(workspaceID):
            done = command(.activateWorkspace(workspaceID), orReject: true)
        case let .project(projectID):
            done = command(.openProjectAsWorkspace(projectID, activeSessionIDs: row.activeSessionIDs), orReject: true)
        }
        if done { ui.leaveList() }
    }

    /// Viereck halten in der Liste: „−“/„×“ der markierten Zeile. Kopfzeilen
    /// haben keins. Die Markierung bleibt in der Liste und rückt auf den
    /// Nachbarn, sobald die Zeile verschwindet (bei einer Rückfrage erst nach
    /// dem Bestätigen, spätestens beim nächsten Schritt).
    private func closeMarkedRow() {
        guard let marked = ui.markedRow, marked.sessionID != nil else {
            playHaptic(.rejected)
            return
        }
        guard command(.closeListRow(marked), orReject: true) else { return }
        refreshListMarker()
        // Die Seitenleiste baut ihre Zeilen erst nach dem Zustandswechsel neu.
        DispatchQueue.main.async { [weak self] in self?.refreshListMarker() }
    }

    func refreshListMarker() {
        guard ui.area == .list else { return }
        ui.listModel.setRows(currentListRows().map(\.row))
        if ui.markedRow != ui.listModel.marked { ui.markedRow = ui.listModel.marked }
    }

    private func filterList(_ step: Int) {
        guard command(.sidebarFilter(step: step), orReject: true) else { return }
        ui.listModel.setRows(currentListRows().map(\.row))
        if ui.markedRow != ui.listModel.marked { ui.markedRow = ui.listModel.marked }
    }

    // MARK: - Diktat

    /// Der ausgewählte Chat des aktiven Fensters als Ziel, sofern er läuft.
    func chatTarget() -> DictationDeliveryTarget? {
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

    func startDictation(target: DictationDeliveryTarget) {
        guard dictation.phase == nil else { return }
        let label: String
        if case let .agentChat(sessionID) = target {
            label = titleForSession(sessionID) ?? String(localized: "Chat")
        } else {
            label = String(localized: "App in front")
        }
        dictation.start(target: target, label: label)
        playHaptic(.recordingStarted)
    }

    private func stopDictation(submit: Bool) {
        dictation.stop(submit: submit && submitAllowed(to: dictation.targetSessionID))
        playHaptic(.recordingStopped)
    }

    // MARK: - Menü (Options)

    /// Öffnet das eine Menü des Controllers. Eingaben gehen in den
    /// ausgewählten Chat, Aktionen am Chat wirken in der Liste auf die
    /// markierte Chat-Zeile, sonst auf den ausgewählten Chat.
    private func toggleMenu(in context: ControllerContext) {
        if ui.menu != nil {
            ui.menu = nil
            return
        }
        var target: SidebarNavigationRow? = selectedSessionID.map { .chat($0) }
        if case .list = context, let marked = ui.markedRow, marked.sessionID != nil { target = marked }
        let setup = menuSetup(for: target)
        ui.menuDialogOpen = setup.dialogOpen
        ui.menu = ControllerMenuModel(setup: setup)
    }

    /// Lage beim Öffnen des Menüs bzw. der R1-Raute: Aktionen am Chat wirken
    /// auf `target`, Eingaben nur, wenn das der ausgewählte, lebende Chat ist.
    func menuSetup(for target: SidebarNavigationRow?) -> ControllerMenuSetup {
        let selected = selectedSessionID
        var setup = ControllerMenuSetup()
        setup.sessionID = target?.sessionID
        setup.target = target
        setup.chat = setup.sessionID.flatMap { chats.chatActionInfo($0, in: targetWindowID) }
        if var chat = setup.chat, !chat.accounts.isEmpty {
            chat.accounts = accountsWithUsage(chat.accounts)
            setup.chat = chat
        }
        if let selected, setup.sessionID == selected, let terminal = terminals.state(of: selected), terminal.isRunning {
            setup.acceptsInput = true
            setup.profile = terminal.profile
            setup.dialogOpen = terminal.status == .awaitingInput
            setup.chatBusy = isBusy(terminal)
            setup.quickCross = quickCross(terminal)
        }
        // Während eines Diktats geht nichts ins Feld (Runde 5, Punkt 9).
        setup.dictationRunning = dictation.phase != nil
        setup.archiveModeActive = targetWindowID.flatMap { chats.snapshot(of: $0) }?.isArchiveMode == true
        return setup
    }

    /// Was R1 + Kreuz aus dem Zustand des Terminals tut (Runde 5, R1).
    func quickCross(_ terminal: ControllerTerminalState) -> ControllerQuickDrawCross? {
        guard terminal.isRunning else { return nil }
        let fieldHasText = ControllerScreenReading.fieldHasText(
            screen: terminal.screen, tracker: terminal.fieldMayHaveText || terminal.draftSuspected)
        return ControllerQuickDrawSlots.crossAction(
            profile: terminal.profile, busy: isBusy(terminal),
            dialogOpen: terminal.status == .awaitingInput, viewOpen: terminal.screen?.openView != nil,
            fieldHasText: fieldHasText, queuedOwnPrompts: terminal.queuedOwnPrompts,
            onlyRecalledPrompt: terminal.onlyRecalledPrompt)
    }

    /// Wie `isBusy(_:)`, aus dem Zustand des Terminals.
    func isBusy(_ terminal: ControllerTerminalState) -> Bool {
        let justSent = terminal.lastEnterAt.map { now().timeIntervalSince($0) < Self.recentlySubmittedWindow } ?? false
        return !(terminal.status == .idle || terminal.status == .awaitingInput) || justSent
    }

    private func activateMenuItem() {
        guard var menu = ui.menu else { return }
        switch menu.submenu {
        case .commands(let list):
            guard let text = list.selectedEnabled else { return playHaptic(.rejected) }
            ui.menu = nil
            sendCommand(ControllerSlashCommand(text: text), setup: menu.setup)
        case .accounts(let list) where list.selectedEnabled == ControllerMenuModel.cancelSwitchID:
            ui.menu = nil
            guard let sessionID = menu.setup.sessionID else { return playHaptic(.rejected) }
            command(.cancelAccountSwitch(sessionID), orReject: true)
        case .accounts(let list) where list.selectedEnabled == ControllerMenuModel.undoSwitchID:
            ui.menu = nil
            command(.undoLastAccountSwitch, orReject: true)
        case .accounts(let list):
            guard let id = list.selectedEnabled, let sessionID = menu.setup.sessionID,
                  let account = menu.setup.chat?.accounts.first(where: { $0.id == id }) else {
                return playHaptic(.rejected)
            }
            ui.menu = nil
            switch account.kind {
            case .claude: command(.moveChatToAccount(sessionID, profileName: account.name), orReject: true)
            case .gpt: command(.setGPTAccount(sessionID, profileName: account.name), orReject: true)
            }
        case .workspaces(let list):
            guard let raw = list.selectedEnabled, let workspaceID = UUID(uuidString: raw),
                  let sessionID = menu.setup.sessionID else { return playHaptic(.rejected) }
            ui.menu = nil
            command(.addChatToWorkspace(sessionID, workspaceID: workspaceID), orReject: true)
        case .capacities(let list):
            guard let id = list.selectedEnabled, let context = menu.setup.chat?.shownInWorkspace,
                  let choice = context.capacities.first(where: { $0.id == id }) else { return playHaptic(.rejected) }
            ui.menu = nil
            command(.setWorkspaceCapacity(context.id, capacity: choice.capacity), orReject: true)
        case nil:
            guard let item = menu.top.selectedEnabled else { return playHaptic(.rejected) }
            if item.opensSubmenu {
                if menu.openSubmenu() { ui.menu = menu } else { playHaptic(.rejected) }
                // Verbrauch erst beim Öffnen der Konten auffrischen, nicht bei
                // jedem Menü oder R1-Halten.
                if item == .switchAccount { refreshAccountLimits() }
                return
            }
            ui.menu = nil
            perform(item, setup: menu.setup)
        }
    }

    func perform(_ item: ControllerMenuItem, setup: ControllerMenuSetup) {
        // „Weiter“ und „Modus wechseln“ prüfen beim Auslösen noch einmal frisch,
        // ob der Chat ruht — auf jedem Weg (Menü und R1-Raute).
        if item.needsRestingChat {
            guard let sessionID = setup.sessionID, let terminal = terminals.state(of: sessionID),
                  terminal.status == .idle, !isBusy(terminal) else {
                return playHaptic(.rejected)
            }
        }
        switch item {
        case .continueWork:
            // Steht schon ein Entwurf im Feld, würde „Weiter“ daran angehängt
            // und beides gesendet.
            guard let sessionID = inputTarget(of: setup),
                  terminals.state(of: sessionID)?.draftSuspected != true else {
                return playHaptic(.rejected)
            }
            terminals.sendText(ControllerMenuText.continueWork, submit: true, to: sessionID)
        case .cycleMode:
            guard let sessionID = inputTarget(of: setup) else { return playHaptic(.rejected) }
            terminals.sendKey(.backTab, to: sessionID)
        case .commands, .switchAccount, .addToWorkspace, .gridCapacity:
            break
        case .redraw:
            guard let sessionID = inputTarget(of: setup) else { return playHaptic(.rejected) }
            if !terminals.sendKey(.redraw, to: sessionID) { playHaptic(.rejected) }
        case .refreshTitle, .openProject, .revealInFinder, .toggleTileNote, .toggleNotes, .removeFromWorkspace,
             .moveToNewWindow, .restart, .backgroundLogs, .backgroundStop, .backgroundRestart, .stopJob,
             .renameWorkspace:
            performChatAction(item, setup: setup)
        case .rename, .fork, .pin, .archive, .closeChat:
            guard let sessionID = setup.sessionID else { return playHaptic(.rejected) }
            switch item {
            case .rename: command(.renameChat(sessionID), orReject: true)
            case .fork: command(.forkChat(sessionID), orReject: true)
            case .pin: command(.togglePin(sessionID), orReject: true)
            case .archive: command(.archiveChat(sessionID), orReject: true)
            default:
                if command(.closeListRow(setup.target ?? .chat(sessionID)), orReject: true) { refreshListMarker() }
            }
        case .archiveMode:
            command(.toggleArchiveMode, orReject: true)
        case .clipboardHistory:
            environment.toggleClipboardPanel()
        case .showBindings:
            environment.openControllerSettings()
        case .pause:
            togglePause()
        }
    }

    /// Chat, in den Eingaben aus dem Menü gehen: der, für den das Menü
    /// geöffnet wurde (`setup.sessionID`), wie bei Konten und Umbenennen.
    /// Hat sich die Auswahl seither geändert (Maus, Tastatur, Benachrichtigung),
    /// geht nichts raus — sonst landete „Weiter“ oder ein Befehl in einem Chat,
    /// den man nicht vor Augen hatte. Der Aufrufer meldet „geht nicht“; das
    /// Menü ist dann schon zu.
    private func inputTarget(of setup: ControllerMenuSetup) -> UUID? {
        guard setup.acceptsInput, let sessionID = setup.sessionID, sessionID == selectedSessionID else { return nil }
        return sessionID
    }

    /// Befehl aus der zweiten Ebene: „/“ bleibt ungesendet stehen, damit sich
    /// die Liste der CLI öffnet; feste Befehle werden gesendet (so öffnet
    /// `/model` gleich die Modellwahl). Nie an einen Entwurf hängen.
    func sendCommand(_ command: ControllerSlashCommand, setup: ControllerMenuSetup) {
        guard let sessionID = inputTarget(of: setup), let state = terminals.state(of: sessionID),
              !state.draftSuspected else {
            return playHaptic(.rejected)
        }
        terminals.sendText(command.text, submit: command.submits, to: sessionID)
        // Öffnet der Befehl eine Liste (`/model`, „/“ …), gehen Steuerkreuz und
        // Kreuz hinein, bis Enter, Escape, eine andere Taste oder zwei Minuten
        // sie schließen. Bei Claude nur aus dem Ruhezustand: An einen
        // arbeitenden Chat gesendet, öffnet sich die Liste nicht sicher, und
        // Pfeile oder Kreuz gingen in den laufenden Turn.
        let listCanOpen = setup.profile != .claude || state.status == .idle
        if listCanOpen, ControllerSlashCommands.opensChoiceList(command, profile: setup.profile) {
            terminals.noteChoiceListOpened(in: sessionID)
            refreshContext()   // Legende zeigt gleich „Pfeiltasten“
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
        case .backspace: return .backspace
        case .space: return .space
        case .deleteWord: return .deleteWord
        case .deleteToLineStart: return .killLineStart
        case .newline: return .newline
        case .wordLeft: return .wordLeft
        case .wordRight: return .wordRight
        case .undo: return .undo
        case .toggleTranscript: return .toggleTranscript
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
