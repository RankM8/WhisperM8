import Foundation

/// Insel per Tastatur, Paket 2 (WM8-104): Schnellbefehle als Buchstaben in
/// derselben Insel wie „Wohin“, dazu Limits-Karte, Spickzettel und das
/// Options-Menü per Tastatur. Dieselben Regeln und Wege wie die R1-Rauten am
/// Controller; nur die Rückmeldung ist der macOS-Warnton.
///
/// - S M O B K wirken auf den aktuellen Chat (Kopf der Insel), nicht auf die
///   markierte Zeile. Während eines Diktats sind sie aus.
/// - L N A C wirken auf die App und gehen immer, auch während eines Diktats.
/// - N und A lassen die Insel offen und bestätigen den Stand; L zeigt die
///   Karte, solange ⌥ gehalten ist; alle anderen schließen die Insel.
/// - Die Tastenzeile steht nur im Reiter „Chats“. Im Reiter „Workspaces &
///   Projekte“ wirken die Buchstaben (wie W und R) deshalb nicht: Was nicht
///   zu sehen ist, geht dort auch nicht.
extension ControllerActionDispatcher {
    /// Tastenzeile beim Öffnen: dieselbe Lage wie beim Öffnen der R1-Raute.
    func makeKeyboardCommands(for session: inout ControllerIslandSession) {
        let sessionID = session.sessionID
        let setup = menuSetup(for: sessionID.map { .chat($0) })
        session.setup = setup
        var slots = ControllerQuickDrawSlots(setup: setup)
        slots.app = environment.appToggles
        // Konto für die Limits-Karte („dieser Chat“), einmal beim Öffnen.
        if dictation.phase != nil, let headChat = dictation.targetSessionID {
            session.usageAccount = chats.chatActionInfo(headChat, in: targetWindowID)?.usageAccount
        } else {
            session.usageAccount = setup.chat?.usageAccount
        }
        let chatState = targetWindowID.flatMap { chats.snapshot(of: $0) }.flatMap(chatState(in:))
        session.model.keyboard = ControllerKeyboardCommands(
            slots: slots,
            transcriptEnabled: setup.acceptsInput && chatState.map(ControllerBindingResolver.transcriptToggleAllowed) == true,
            chatTitle: sessionID.flatMap(titleForSession),
            letters: keyboardLetters())
    }

    var keyboardCommands: ControllerKeyboardCommands? { islandState?.model.keyboard }

    /// Baut die Tastenzeile, falls noch nicht geschehen; eigener Messpunkt
    /// `keyboardIsland.commands`.
    func ensureKeyboardCommands() {
        guard isKeyboardIslandOpen, var state = islandState, state.model.keyboard == nil else { return }
        PerfBudgets.keyboardIslandCommands.withInterval { makeKeyboardCommands(for: &state) }
        islandState = state
    }

    /// Ein Buchstabe der Tastenzeile.
    func keyboardIslandCommand(_ command: KeyboardIslandCommand) {
        ensureKeyboardCommands()
        guard isKeyboardIslandOpen, let commands = keyboardCommands,
              islandState?.model.whereTo?.tab == .chats else { return keyboardRejected() }
        // Offene Karte oder Spickzettel: Nur L schließt die Karte wieder.
        if commands.slots.card != nil {
            return command == .limits ? closeKeyboardLimitsCard() : keyboardRejected()
        }
        if commands.cheatSheet { return keyboardRejected() }
        if command.isChatCommand {
            performKeyboardChatCommand(command)
        } else if let slot = command.appSlot {
            performKeyboardAppCommand(slot)
        }
    }

    // MARK: - Chat (S M O B K)

    private func performKeyboardChatCommand(_ command: KeyboardIslandCommand) {
        guard var setup = islandState?.setup, let commands = keyboardCommands,
              commands.isEnabled(command) else { return keyboardRejected() }
        // Seit dem Öffnen kann eine Rückfrage erschienen sein, oder der Chat
        // hat zu arbeiten begonnen (wie bei der R1-Raute).
        if setup.acceptsInput, let sessionID = setup.sessionID, let terminal = terminals.state(of: sessionID) {
            setup.dialogOpen = terminal.status == .awaitingInput
            setup.chatBusy = isBusy(terminal)
            setup.quickCross = quickCross(terminal)
        }
        withKeyboardFeedback {
            switch command {
            case .sendNow:
                sendOrContinue(setup: setup) { flashKeyboardHit(command) }
            case .transcript:
                guard setup.acceptsInput, setup.profile == .claude, !setup.dialogOpen,
                      let sessionID = setup.sessionID, sessionID == selectedSessionID else { return keyboardRejected() }
                flashKeyboardHit(command)
                if !terminals.sendKey(.toggleTranscript, to: sessionID) { keyboardRejected() }
            case .cycleMode:
                guard ControllerMenuModel.isEnabled(.cycleMode, setup: setup) else { return keyboardRejected() }
                flashKeyboardHit(command)
                perform(.cycleMode, setup: setup)
            case .commands, .account:
                guard let item = command.menuItem, ControllerMenuModel.isEnabled(item, setup: setup) else {
                    return keyboardRejected()
                }
                var menu = ControllerMenuModel(setup: setup, selected: item)
                guard menu.openSubmenu() else { return keyboardRejected() }
                closeIsland()
                ui.leaveList()
                ui.menuDialogOpen = setup.dialogOpen
                ui.menu = menu
                ui.menuByKeyboard = true
                if item == .switchAccount { refreshAccountLimits() }
            default:
                break
            }
        }
    }

    /// Markiert den Buchstaben kurz und schließt die Insel danach. Bis dahin
    /// wechselt ⌥ loslassen nicht mehr.
    private func flashKeyboardHit(_ command: KeyboardIslandCommand) {
        guard var state = islandState, var commands = state.model.keyboard else { return }
        if command == .transcript { commands.transcriptHit = true } else { commands.slots.hit = command.menuItem }
        commands.releaseSwitches = false
        state.model.keyboard = commands
        islandState = state
        present()
        let generation = islandGeneration
        scheduleOnMain(Self.quickDrawHitDuration) { [weak self] in
            guard let self, self.islandGeneration == generation, self.isKeyboardIslandOpen else { return }
            self.closeIsland()
        }
    }

    // MARK: - App (L N A C)

    private func performKeyboardAppCommand(_ slot: ControllerAppSlot) {
        guard var slots = quickDrawSlots else { return }
        switch slot {
        case .limits:
            openLimitsCard()
            setKeyboardReleaseSwitches(false)
        case .alerts:
            let stage = environment.cycleAlertLevel()
            slots.app = environment.appToggles
            slots.confirmation = .alert(stage, next: slots.app.nextAlert)
            slots.appHit = .alerts
            setQuickDrawSlots(slots)
            setKeyboardReleaseSwitches(false)
        case .stayAwake:
            setKeyboardReleaseSwitches(false)
            let generation = islandGeneration
            environment.cycleStayAwake { [weak self] result in
                guard let self else { return }
                if case .changed = result {} else { self.keyboardRejected() }
                self.stayAwakeCycled(result, generation: generation)
            }
        case .clipboard:
            closeIsland()
            environment.toggleClipboardPanel()
        }
    }

    private func closeKeyboardLimitsCard() {
        guard var slots = quickDrawSlots else { return }
        slots.card = nil
        setQuickDrawSlots(slots)
    }

    private func setKeyboardReleaseSwitches(_ value: Bool) {
        guard var state = islandState, state.model.keyboard?.releaseSwitches != value else { return }
        state.model.keyboard?.releaseSwitches = value
        islandState = state
    }

    // MARK: - Karte und Spickzettel

    /// ↑/↓ und Tab bei offener Karte scrollen sie; im Spickzettel nichts.
    /// `true`, wenn der Schritt dort verbraucht wurde.
    func keyboardIslandStepConsumed(_ step: Int) -> Bool {
        guard let commands = keyboardCommands else { return false }
        if commands.slots.card != nil {
            scrollLimitsCard(step)
            return true
        }
        return commands.cheatSheet
    }

    /// Return bei offener Karte: frisch abrufen (wie ✕ am Controller), bei
    /// laufendem Abruf oder Diktat Warnton. Im Spickzettel: schließen.
    /// `true`, wenn Return dort verbraucht wurde.
    func keyboardIslandReturnConsumed() -> Bool {
        guard let commands = keyboardCommands else { return false }
        if let card = commands.slots.card {
            guard card.canRefresh, !limits.isLoading() else {
                keyboardRejected()
                return true
            }
            limits.refresh()
            limitsMayHaveChanged()
            return true
        }
        if commands.cheatSheet {
            closeIsland()
            return true
        }
        return false
    }

    /// ?: Spickzettel der Schreib-Tasten an und aus (nur im Reiter „Chats“).
    func toggleKeyboardCheatSheet() {
        ensureKeyboardCommands()
        guard isKeyboardIslandOpen, var state = islandState, var commands = state.model.keyboard,
              commands.slots.card == nil, state.model.whereTo?.tab == .chats else { return keyboardRejected() }
        commands.cheatSheet.toggle()
        commands.releaseSwitches = false
        state.model.keyboard = commands
        islandState = state
        present()
    }

    /// Ein Schritt in der Liste macht die Markierung wieder zum Ziel.
    func keyboardMarkerMoved() {
        guard var state = islandState, var commands = state.model.keyboard else { return }
        commands.releaseSwitches = true
        commands.slots.confirmation = nil
        commands.slots.appHit = nil
        guard commands != state.model.keyboard else { return }
        state.model.keyboard = commands
        islandState = state
    }

    // MARK: - Options-Menü per Tastatur

    /// B und K öffnen das Options-Menü direkt auf der Unterseite. Per Tastatur
    /// geht es mit ↑/↓, Return und Esc (am Controller Stick, Kreuz, Kreis).
    var isKeyboardMenuOpen: Bool { ui.menuByKeyboard && ui.menu != nil }

    func keyboardMenu(_ action: KeyboardIslandKeys.MenuAction) {
        guard isKeyboardMenuOpen else { return }
        let context = ControllerContextResolver.context(for: snapshot())
        performingForKeyboard = true
        defer { performingForKeyboard = false }
        if ui.lastInput != .keyboard { ui.lastInput = .keyboard }
        withKeyboardFeedback {
            switch action {
            case let .move(step): perform(.menuMove(step: step), in: context)
            case .activate: perform(.menuActivate, in: context)
            case .back: perform(.menuBack, in: context)
            case .closeAndPassThrough: ui.menu = nil
            }
        }
    }

    // MARK: - Hilfen

    /// „Geht nicht“ aus den gemeinsamen Wegen (Vibration am Controller) wird
    /// per Tastatur zum Warnton.
    func withKeyboardFeedback(_ body: () -> Void) {
        let haptic = playHaptic
        playHaptic = { [weak self] pattern in
            haptic(pattern)
            if pattern == .rejected { self?.keyboardRejected() }
        }
        body()
        playHaptic = haptic
    }
}
