import Foundation

/// Offene Insel aus Sicht des Ausführers.
struct ControllerIslandSession: Equatable {
    var model: ControllerIslandModel
    /// Chat beim Öffnen. Eingaben aus der Raute gehen nur an ihn
    /// (`inputTarget`, wie beim Options-Menü).
    var sessionID: UUID?
    /// Lage für die Raute (wie beim Öffnen des Options-Menüs); nur bei R1.
    var setup: ControllerMenuSetup?
    /// Bildschirm des Agent-Chats-Fensters, auf dem der Controller wirkt.
    var screenDisplayID: UInt32?
}

extension ControllerAction {
    /// Ende einer Ebene: ohne offene Insel ohne jede Wirkung.
    var isIslandEnd: Bool {
        switch self {
        case .islandClose, .islandRelease: return true
        default: return false
        }
    }
}

/// Die Controller-Insel (Runde 4): L1 „Schreiben“, R1 „Schnellbefehle“,
/// L2 „Wohin“. Das Modell entsteht hier im Ereignis-Pfad; die Anzeige
/// (`ControllerIslandPresenting`) zeichnet es nur.
extension ControllerActionDispatcher {
    // MARK: - Öffnen und Schließen

    /// Insel für `layer` einblenden (Halte-Schwelle erreicht oder erste
    /// Kombination, die sie braucht). Nichts, wenn eine Aktion sie in diesem
    /// Halten schon geschlossen hat oder sie schon offen ist.
    func showIsland(_ layer: ControllerLayer) {
        guard spentLayer != layer, islandState?.model.layer != layer else { return }
        PerfBudgets.controllerIslandShow.withInterval {
            guard let session = makeIsland(layer) else { return }
            islandGeneration += 1
            islandState = session
            island.show(session.model, screenDisplayID: session.screenDisplayID)
        }
    }

    /// Insel offen halten, damit eine Kombination sie ändern kann. `false`,
    /// wenn sie in diesem Halten schon zu ist.
    @discardableResult
    func ensureIsland(_ layer: ControllerLayer) -> Bool {
        showIsland(layer)
        return islandState?.model.layer == layer
    }

    /// Insel weg (ohne Wirkung). Die Ebene darf danach wieder öffnen.
    func closeIsland() {
        guard islandState != nil else { return }
        islandState = nil
        islandGeneration += 1
        island.hide()
    }

    /// Eine Aktion schließt die Insel; bis zum Loslassen der Taste bleibt sie
    /// zu, auch wenn die Halte-Schwelle erst danach kommt.
    func spendIsland(_ layer: ControllerLayer? = nil) {
        guard let layer = layer ?? islandState?.model.layer else { return }
        spentLayer = layer
        if islandState?.model.layer == layer { closeIsland() }
    }

    /// Maus oder Tastatur greifen ein: Insel weg, und sie kommt in diesem
    /// Halten nicht wieder.
    func closeIslandForUserInput() {
        spendIsland()
    }

    private func present() {
        guard let islandState else { return }
        island.show(islandState.model, screenDisplayID: islandState.screenDisplayID)
    }

    /// Baut die Insel aus dem Zustand des Fensters, auf das der Controller
    /// wirkt. `nil` ohne Agent-Chats-Fenster.
    private func makeIsland(_ layer: ControllerLayer) -> ControllerIslandSession? {
        guard let windowID = targetWindowID, let window = chats.snapshot(of: windowID) else { return nil }
        let sessionID = window.selectedSessionID
        var target = ControllerIslandTarget(
            title: sessionID.flatMap(titleForSession), status: sessionID.flatMap(islandStatus))
        // Während eines Diktats nennt der Kopf dessen Ziel (Runde 5, Punkt 9).
        if dictation.phase != nil, let dictationTarget = dictation.targetSessionID {
            let title = titleForSession(dictationTarget) ?? String(localized: "Chat")
            target = ControllerIslandTarget(title: "→ \(title)", status: islandStatus(dictationTarget))
        }
        var setup: ControllerMenuSetup?
        let content: ControllerIslandModel.Content
        switch layer {
        case .writing:
            content = .writing(ControllerWritingSlots(state: chatState(in: window), clip: clipboard.newest()))
        case .quickDraw:
            let menuSetup = menuSetup(for: sessionID.map { .chat($0) })
            setup = menuSetup
            content = .quickDraw(ControllerQuickDrawSlots(setup: menuSetup))
        case .whereTo:
            // Reihenfolge wie die Liste links, jeder Chat einmal. Der vorige
            // Chat steht immer darin, auch wenn die Liste ihn gerade nicht
            // zeigt (Filter, Suche, eingeklappt): Loslassen soll dorthin
            // führen wie Tippen.
            let previous = Self.whereToPrevious(window.backTarget)
            let order = ControllerWhereToState.chatOrder(
                SidebarChatOrder.sessions(in: currentListRows().map(\.row)), current: sessionID, previous: previous)
            var whereTo = ControllerWhereToState(
                chats: islandChatRows(order, sessionID), currentChatID: sessionID,
                workspaces: chats.workspaceChoices(of: windowID), gridActive: window.isGridActive,
                previous: previous)
            whereTo.reopenTitle = closedChats.nextTitle()
            content = .whereTo(whereTo)
        }
        return ControllerIslandSession(
            model: ControllerIslandModel(target: target, content: content),
            sessionID: sessionID, setup: setup, screenDisplayID: window.screenDisplayID)
    }

    /// Voriger Ort des Fensters (Ziel von L2 getippt) als Startpunkt der
    /// Markierung.
    static func whereToPrevious(_ target: ControllerBackTarget?) -> ControllerWhereToState.Destination {
        guard let target, let id = target.id else { return .stay }
        switch target.kind {
        case .chat: return .chat(id)
        case .workspace: return .workspace(id)
        }
    }

    /// Rückfrage geht auf oder zu, während die Insel offen ist: Raute und
    /// Schreiben zeigen dann, was gerade geht. Aufgerufen beim Schnappschuss.
    func islandChatMayHaveChanged(_ chat: ControllerChatState?, sessionID: UUID?) {
        guard var state = islandState, state.sessionID == sessionID, spentLayer != state.model.layer else { return }
        switch state.model.content {
        case .writing(let slots):
            let fresh = ControllerWritingSlots(state: chat, clip: slots.clip)
            guard fresh != slots else { return }
            state.model.content = .writing(fresh)
        case .quickDraw(let slots):
            guard var setup = state.setup else { return }
            let dialogOpen = chat?.status == .awaitingInput
            let busy = Self.isBusy(chat)
            let cross = sessionID.flatMap { terminals.state(of: $0) }.flatMap(quickCross)
            guard setup.acceptsInput,
                  setup.dialogOpen != dialogOpen || setup.chatBusy != busy || setup.quickCross != cross
            else { return }
            setup.dialogOpen = dialogOpen
            setup.chatBusy = busy
            setup.quickCross = cross
            state.setup = setup
            state.model.content = .quickDraw(ControllerQuickDrawSlots(setup: setup, hit: slots.hit))
        case .whereTo:
            return
        }
        islandState = state
        present()
    }

    // MARK: - Wohin (L2)

    func moveInWhereTo(_ step: Int) {
        guard ensureIsland(.whereTo), var state = islandState, var whereTo = state.model.whereTo else { return }
        whereTo.move(step)
        state.model.content = .whereTo(whereTo)
        islandState = state
        present()
    }

    func switchWhereToTab(_ step: Int) {
        guard ensureIsland(.whereTo), var state = islandState, var whereTo = state.model.whereTo,
              whereTo.switchTab(step) else { return }
        state.model.content = .whereTo(whereTo)
        islandState = state
        present()
    }

    /// L2 losgelassen: wie Kreuz — zum markierten Eintrag, wie Cmd-Tab.
    /// Steht die Markierung auf dem aktuellen Eintrag, passiert nichts.
    func releaseWhereTo() {
        defer { spentLayer = nil }
        guard let whereTo = islandState?.model.whereTo else { return closeIsland() }
        closeIsland()
        if !go(to: whereTo.destination, previous: whereTo.previous) { playHaptic(.rejected) }
    }

    /// Kreuz (`dictate == false`) oder R2. Steht die Markierung auf dem
    /// aktuellen Eintrag, schließt Kreuz nur, R2 diktiert in den aktuellen
    /// Chat. Ein anderer Workspace ist kein Ziel für R2 („geht nicht“, die
    /// Insel bleibt) — „hin und diktieren“ braucht einen Chat.
    func commitWhereTo(dictate: Bool) {
        guard spentLayer != .whereTo else { return }
        let whereTo = islandState?.model.whereTo
        let destination = whereTo?.destination ?? .stay
        if dictate, case .workspace = destination {
            return playHaptic(.rejected)
        }
        spendIsland(.whereTo)
        let switched = go(to: destination, previous: whereTo?.previous ?? .stay)
        guard dictate else {
            if !switched { playHaptic(.rejected) }
            return
        }
        // Diktat nur in den Chat, der jetzt wirklich ausgewählt ist: Scheiterte
        // der Wechsel (Konflikt, Chat weg), geht nichts in einen anderen.
        if case let .chat(sessionID) = destination {
            guard switched, selectedSessionID == sessionID, let target = chatTarget() else {
                return playHaptic(.rejected)
            }
            startDictation(target: target)
        } else {
            startDictation(target: chatTarget() ?? .frontApp)
        }
    }

    /// Dreieck: nächster wartender Chat, reihum über alle wartenden (derselbe
    /// Weg wie ⌃⌥Tab). Schließt die Insel; ohne wartenden Chat „geht nicht“.
    func jumpToNextWaitingChat() {
        guard spentLayer != .whereTo else { return }
        spendIsland(.whereTo)
        command(.nextWaitingChat, orReject: true)
    }

    /// Wechsel: Ist das Ziel der vorige Ort, derselbe Weg wie L2 getippt
    /// (`lastChat`), damit Halten und Tippen gleich enden. Sonst ein Chat wie
    /// der Klick in der Seitenleiste (wie L1/R1), ein Workspace wie der Klick
    /// auf seinen Kopf mit der gemerkten Kachel, aber still: Gehört er einem
    /// anderen Fenster, kommt nichts nach vorn und kein Dialog. `false`, wenn
    /// der Wechsel nicht ging; „geht nicht“ meldet der Aufrufer.
    @discardableResult
    private func go(
        to destination: ControllerWhereToState.Destination, previous: ControllerWhereToState.Destination
    ) -> Bool {
        if destination != .stay, destination == previous { return command(.lastChat, orReject: false) }
        switch destination {
        case .stay: return true
        case let .chat(sessionID): return command(.selectSession(sessionID), orReject: false)
        case let .workspace(workspaceID): return command(.switchToWorkspace(workspaceID), orReject: false)
        }
    }

    // MARK: - Schnellbefehle (R1)

    /// Ein Eintrag der Raute: dieselben Regeln und Wege wie im Options-Menü.
    /// Eingaben gehen an den Chat beim Öffnen der Insel; ist inzwischen ein
    /// anderer ausgewählt, „geht nicht“. Ein Eintrag, der gerade nicht geht,
    /// vibriert und lässt die Insel offen. „›“ öffnet das Menü direkt auf der
    /// Unterseite.
    func performQuickDraw(_ item: ControllerMenuItem) {
        guard spentLayer != .quickDraw else { return }
        var setup = islandState?.setup ?? menuSetup(for: selectedSessionID.map { .chat($0) })
        // Eine Rückfrage kann seit dem Öffnen erschienen sein, oder der Chat
        // hat zu arbeiten begonnen.
        if setup.acceptsInput, let sessionID = setup.sessionID, let terminal = terminals.state(of: sessionID) {
            setup.dialogOpen = terminal.status == .awaitingInput
            setup.chatBusy = isBusy(terminal)
            setup.quickCross = quickCross(terminal)
        }
        // R1 + Kreuz mit Text im Feld oder Wartendem: Senden bzw. „Jetzt
        // senden“ statt „Weiter“ (Runde 5, R1). Leeres Feld bei arbeitendem
        // Chat: „geht nicht“.
        if item == .continueWork, setup.acceptsInput {
            switch setup.quickCross {
            case let cross? where cross != .continueWork:
                guard let sessionID = setup.sessionID, sessionID == selectedSessionID else {
                    return playHaptic(.rejected)
                }
                flashQuickDrawHit(item)
                if !terminals.sendKey(cross == .sendNow ? .sendNow : .enter, to: sessionID) { playHaptic(.rejected) }
                return
            case nil:
                return playHaptic(.rejected)
            default:
                break
            }
        }
        guard ControllerMenuModel.isEnabled(item, setup: setup) else { return playHaptic(.rejected) }
        flashQuickDrawHit(item)
        if item.opensSubmenu {
            var menu = ControllerMenuModel(setup: setup, selected: item)
            guard menu.openSubmenu() else { return playHaptic(.rejected) }
            ui.leaveList()
            ui.menuDialogOpen = setup.dialogOpen
            ui.menu = menu
        } else {
            perform(item, setup: setup)
        }
    }

    /// Markiert den gedrückten Eintrag kurz und schließt die Insel danach.
    /// Bis zum Loslassen von R1 kommt sie nicht wieder.
    private func flashQuickDrawHit(_ item: ControllerMenuItem) {
        spentLayer = .quickDraw
        guard var state = islandState, case let .quickDraw(slots) = state.model.content else { return }
        var hit = slots
        hit.hit = item
        state.model.content = .quickDraw(hit)
        islandState = state
        present()
        let generation = islandGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quickDrawHitDuration) { [weak self] in
            guard let self, self.islandGeneration == generation else { return }
            self.closeIsland()
        }
    }

    /// So lange bleibt der gedrückte Schnellbefehl markiert.
    static let quickDrawHitDuration: TimeInterval = 0.12
}
