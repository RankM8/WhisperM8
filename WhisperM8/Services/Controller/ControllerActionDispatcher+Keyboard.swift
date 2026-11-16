import Foundation

/// Insel per Tastatur (WM8-104, Variante B): ⌥Tab bedient dieselbe Insel und
/// dieselben Wege wie L2 „Wohin“ am Controller. Welche Taste was auslöst,
/// entscheidet der pure `KeyboardIslandKeys`; der `KeyboardIslandMonitor`
/// ruft hier nur an.
///
/// Unterschiede zum Controller, alle aus Plan und Entwurf:
/// - Die Markierung startet auf „vorher“ (der Druck auf Tab ist schon ein
///   Schritt, wie ⌘Tab). ⌥ kurz getippt führt deshalb wie L2 getippt zurück.
/// - Die Insel erscheint erst nach 0,2 s; bis dahin wechselt das Loslassen
///   trotzdem.
/// - „Geht nicht“ ist der macOS-Warnton, die Insel bleibt offen.
/// - Kein `spentLayer`: Der gehört den Ebenen-Tasten des Controllers.
extension ControllerActionDispatcher {
    /// Die Insel ist offen und wurde per Tastatur geöffnet.
    var isKeyboardIslandOpen: Bool { islandState?.model.input == .keyboard }

    var isKeyboardIslandRevealed: Bool { isKeyboardIslandOpen && islandState?.revealed == true }

    /// Darf ⌥Tab die Insel öffnen bzw. ein Wechsel ausgeführt werden? Nur im
    /// Agent-Chats-Fenster ohne Dialog, Sheet, Menü oder ⌃Tab-Umschalter, und
    /// während eines Diktats nur, wenn es an einen Chat gebunden ist (sonst
    /// ginge der Text per ⌘V dorthin, wo beim Stopp der Fokus liegt).
    func keyboardIslandAllowed() -> Bool {
        guard let windowID = targetWindowID, chats.snapshot(of: windowID)?.isSwitcherOpen != true else { return false }
        switch ControllerContextResolver.context(for: snapshot()) {
        // Im Ticket-Modus wie in der Liste (WM8-91): ⌥Tab führt auch vom Board weg.
        case .chat, .list, .tickets: return true
        case let .recording(_, _, navigation): return navigation != nil
        default: return false
        }
    }

    /// ⌥Tab: Insel für „Wohin“ aufbauen, Markierung auf „vorher“, noch
    /// unsichtbar. `false`, wenn sie hier nicht aufgeht; ⌥Tab läuft dann
    /// weiter wie bisher.
    @discardableResult
    func openKeyboardIsland() -> Bool {
        guard keyboardIslandAllowed() else { return false }
        // Hält der Controller gerade eine Ebene, schließt die Tastatur ihre
        // Insel wie heute; bis zum Loslassen kommt sie nicht wieder.
        if islandState != nil { closeIslandForUserInput() }
        let built = PerfBudgets.controllerIslandShow.withInterval { makeIsland(.whereTo, input: .keyboard) }
        guard var session = built, var whereTo = session.model.whereTo else { return false }
        whereTo.markPreviousForKeyboard()
        session.model.content = .whereTo(whereTo)
        // Die Tastenzeile (Menü-Angaben, Schalter, Layout) entsteht erst, wenn
        // die Insel erscheint oder ein Buchstabe kommt: ⌥Tab kurz getippt
        // braucht sie nie (`ensureKeyboardCommands`).
        session.revealed = false
        islandGeneration += 1
        islandState = session
        if ui.lastInput != .keyboard { ui.lastInput = .keyboard }
        return true
    }

    /// Nach 0,2 s noch offen: jetzt zeigen.
    func revealKeyboardIsland() {
        guard isKeyboardIslandOpen, islandState?.revealed == false else { return }
        ensureKeyboardCommands()
        guard var state = islandState else { return }
        state.revealed = true
        islandState = state
        present()
    }

    /// Tab/⇧Tab, ↓/↑: Markierung bewegen, ohne Umlauf.
    func keyboardIslandStep(_ step: Int) {
        guard isKeyboardIslandOpen, !keyboardIslandStepConsumed(step) else { return }
        keyboardMarkerMoved()
        updateKeyboardWhereTo { $0.move(step) }
    }

    /// ←/→: Reiter wechseln, Markierung dort auf „vorher“ bzw. dem aktuellen.
    /// Nicht bei offener Karte oder offenem Spickzettel.
    func keyboardIslandTab(_ step: Int) {
        guard isKeyboardIslandOpen else { return }
        guard keyboardCommands?.slots.card == nil, keyboardCommands?.cheatSheet != true else {
            return keyboardRejected()
        }
        keyboardMarkerMoved()
        updateKeyboardWhereTo { $0.switchTabForKeyboard(step) }
    }

    /// Return: wie ⌥ loslassen; bei offener Karte frisch abrufen, im
    /// Spickzettel schließen.
    func keyboardIslandReturn() {
        guard isKeyboardIslandOpen, !keyboardIslandReturnConsumed() else { return }
        commitKeyboardIsland()
    }

    /// Karte oder Spickzettel offen: Dort wirken Leertaste, W und R nicht.
    private var keyboardIslandShowsList: Bool {
        keyboardCommands?.slots.card == nil && keyboardCommands?.cheatSheet != true
    }

    /// ⌥ losgelassen oder Return: zum markierten Eintrag. Steht die
    /// Markierung auf dem aktuellen Eintrag, passiert nichts. Ist inzwischen
    /// ein Dialog oder eine Aufnahme per Hotkey dazwischengekommen, schließt
    /// die Insel nur (wie am Controller).
    func commitKeyboardIsland() {
        guard isKeyboardIslandOpen, let whereTo = islandState?.model.whereTo else { return }
        let switches = keyboardCommands?.releaseSwitches ?? true
        closeIsland()
        // Nach einem Schalter, der Karte oder dem Spickzettel wechselt das
        // Loslassen nicht mehr, bis sich die Markierung bewegt.
        guard switches else { return }
        guard keyboardIslandAllowed() else { return }
        if !go(to: whereTo.destination, previous: whereTo.previous) { keyboardRejected() }
    }

    /// Esc, ein entgangenes Loslassen, ein Klick, die App verliert den Fokus:
    /// schließen, nichts passiert. Eine laufende Aufnahme läuft weiter.
    func cancelKeyboardIsland() {
        guard isKeyboardIslandOpen else { return }
        closeIsland()
    }

    /// Leertaste (oder der Diktat-Hotkey, solange die Insel offen ist): hin
    /// und diktieren; während eines Diktats „stopp“. Ein anderer Workspace oder
    /// ein Projekt ist kein Ziel — „hin und diktieren“ braucht einen Chat.
    func keyboardIslandDictate() {
        guard isKeyboardIslandOpen, let whereTo = islandState?.model.whereTo else { return }
        guard keyboardIslandShowsList else { return keyboardRejected() }
        if let phase = dictation.phase {
            guard phase == .recording else { return keyboardRejected() }
            closeIsland()
            dictation.stop(submit: false)
            return
        }
        let destination = whereTo.destination
        switch destination {
        case .workspace, .project: return keyboardRejected()
        // Board: hin und diktieren erst mit dem Board-Chat (WM8-113, E4).
        case .tickets: return keyboardRejected()
        case .stay, .chat:
            // Im Board gibt es keinen Chat, in den „hier“ diktiert würde.
            if destination == .stay, whereTo.ticketBoards?.inTickets == true { return keyboardRejected() }
        }
        closeIsland()
        let switched = go(to: destination, previous: whereTo.previous)
        // Diktat nur in den Chat, der jetzt wirklich ausgewählt ist: Scheiterte
        // der Wechsel, geht nichts in einen anderen.
        if case let .chat(sessionID) = destination {
            guard switched, selectedSessionID == sessionID, let target = chatTarget() else {
                return keyboardRejected()
            }
            startDictation(target: target)
        } else {
            startDictation(target: chatTarget() ?? .frontApp)
        }
    }

    /// W: nächster wartender Chat, reihum (derselbe Weg wie ⌃⌥Tab). Ohne
    /// wartenden Chat Warnton, die Insel bleibt.
    func keyboardIslandNextWaiting() {
        guard isKeyboardIslandOpen else { return }
        // Nur, wo W in der Fußzeile steht: im Reiter „Chats“ mit Liste.
        guard keyboardIslandShowsList, islandState?.model.whereTo?.tab == .chats else { return keyboardRejected() }
        guard command(.nextWaitingChat, orReject: false) else { return keyboardRejected() }
        closeIsland()
        refreshContext()
    }

    /// R: zuletzt geschlossenen Chat dieses App-Starts wieder öffnen. Ohne
    /// geschlossenen Chat Warnton, die Insel bleibt.
    func keyboardIslandReopen() {
        guard isKeyboardIslandOpen else { return }
        guard keyboardIslandShowsList, islandState?.model.whereTo?.tab == .chats else { return keyboardRejected() }
        guard closedChats.reopen() else { return keyboardRejected() }
        closeIsland()
        refreshContext()
    }

    private func updateKeyboardWhereTo(_ change: (inout ControllerWhereToState) -> Void) {
        guard isKeyboardIslandOpen, var state = islandState, var whereTo = state.model.whereTo else { return }
        change(&whereTo)
        state.model.content = .whereTo(whereTo)
        guard state != islandState else { return }
        islandState = state
        present()
    }
}
