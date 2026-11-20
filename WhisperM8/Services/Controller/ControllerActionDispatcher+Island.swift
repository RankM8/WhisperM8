import Foundation
import OSLog

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
    /// Konto für Kopf und Limits-Karte (nur R1), einmal beim Öffnen bestimmt:
    /// während eines Diktats das seines Ziels, sonst das des Chats. Es bleibt,
    /// auch wenn inzwischen ein anderer Chat ausgewählt ist.
    var usageAccount: ControllerUsageAccount?
    /// Konten der Limits-Karte, einmal beim Öffnen der Karte gelesen. Neue
    /// Zahlen ordnen sich diesen Namen zu, ohne die Profile neu zu lesen.
    var limitAccounts: ControllerLimitAccounts?
    /// Sichtbar. Per Tastatur erscheint die Insel erst nach 0,2 s (⌥Tab kurz
    /// getippt blitzt sie nicht auf); bis dahin zeigt `present()` nichts.
    var revealed = true
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

    /// Halte-Schwelle erreicht (Aktion `islandShow`). Wie `showIsland`, nennt
    /// aber im Log, warum die Insel nicht aufgeht: Ebene in diesem Halten
    /// schon verbraucht oder laut Ausführer schon offen. Nur einmal je Halten,
    /// nie bei Kombinationen (die gehen über `ensureIsland`).
    func showIslandOnHold(_ layer: ControllerLayer) {
        if spentLayer == layer || islandState?.model.layer == layer {
            let reason = spentLayer == layer ? "spent" : "already_open"
            let revealed = islandState?.revealed ?? false
            Logger.controller.info(
                "controller_island_show_ignored reason=\(reason, privacy: .public) layer=\(String(describing: layer), privacy: .public) revealed=\(revealed, privacy: .public)")
            return
        }
        showIsland(layer)
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

    func present() {
        guard var state = islandState, state.revealed else { return }
        // Die Spalten folgen dem Bildschirm, auf dem die Insel gerade
        // wirklich steht: Fällt er weg (Deckel zu), zeigt das Fenster sie
        // woanders als Liste, und das Steuerkreuz rechnet dann auch so.
        if var whereTo = state.model.whereTo {
            let columns = island.columns(onDisplay: state.screenDisplayID)
            if whereTo.columns != columns {
                whereTo.setColumns(columns)
                state.model.content = .whereTo(whereTo)
                islandState = state
            }
        }
        island.show(state.model, screenDisplayID: state.screenDisplayID)
    }

    /// Baut die Insel aus dem Zustand des Fensters, auf das der Controller
    /// wirkt. `nil` ohne Agent-Chats-Fenster. `input`: per Tastatur geöffnet
    /// (⌥Tab), dann Tastenkappen in Kopf und Fußzeile.
    func makeIsland(_ layer: ControllerLayer, input: ControllerIslandInput = .controller) -> ControllerIslandSession? {
        guard let windowID = targetWindowID else {
            // Stille Rückwege ins Log (WM8-91, Befund 16.11.): Ohne Fenster
            // geht die Insel nicht auf, obwohl die Taste ankam.
            Logger.controller.info(
                "controller_island_make_skipped reason=no_window layer=\(String(describing: layer), privacy: .public)")
            return nil
        }
        guard let window = chats.snapshot(of: windowID) else {
            Logger.controller.info(
                "controller_island_make_skipped reason=no_snapshot layer=\(String(describing: layer), privacy: .public)")
            return nil
        }
        let sessionID = window.selectedSessionID
        var target = ControllerIslandTarget(
            title: sessionID.flatMap(titleForSession), status: sessionID.flatMap(islandStatus))
        // Im Ticket-Modus nennt der Kopf den Ort (WM8-91): „Tickets · WM8“.
        if let tickets = window.tickets {
            target = ControllerIslandTarget(title: ControllerTicketsText.placeTitle(tickets.label), status: nil)
        }
        // Während eines Diktats nennt der Kopf dessen Ziel (Runde 5, Punkt 9).
        if dictation.phase != nil, let dictationTarget = dictation.targetSessionID {
            let title = titleForSession(dictationTarget) ?? String(localized: "Chat")
            target = ControllerIslandTarget(
                title: "→ \(title)", status: islandStatus(dictationTarget), dictating: true)
        }
        var setup: ControllerMenuSetup?
        var usageAccount: ControllerUsageAccount?
        let content: ControllerIslandModel.Content
        switch layer {
        case .writing:
            content = .writing(ControllerWritingSlots(state: chatState(in: window), clip: clipboard.newest()))
        case .quickDraw:
            let menuSetup = menuSetup(for: sessionID.map { .chat($0) })
            setup = menuSetup
            var slots = ControllerQuickDrawSlots(setup: menuSetup)
            slots.app = environment.appToggles
            // Im Board wirkt die Chat-Raute erst auf den Board-Chat (WM8-113).
            if window.tickets != nil, dictation.phase == nil { slots.note = .noBoardChat }
            // Der Kopf nennt während eines Diktats dessen Ziel, also auch dessen Konto.
            // Einmal hier bestimmt und in der Sitzung gemerkt: Neue Zahlen
            // ziehen Kopf und Karte nach, wechseln aber nie das Konto.
            if dictation.phase != nil, let headChat = dictation.targetSessionID {
                usageAccount = chats.chatActionInfo(headChat, in: targetWindowID)?.usageAccount
            } else {
                usageAccount = menuSetup.chat?.usageAccount
            }
            slots.account = accountBadge(usageAccount)
            content = .quickDraw(slots)
        case .whereTo:
            // Reihenfolge wie die Liste links, jeder Chat einmal. Der vorige
            // Chat steht immer darin, gleich unter dem aktuellen, auch wenn
            // die Liste ihn weiter unten oder gar nicht zeigt (Filter, Suche,
            // eingeklappt): ein Schritt bis dorthin.
            let previous = Self.whereToPrevious(window.backTarget)
            let order = ControllerWhereToState.chatOrder(
                SidebarChatOrder.sessions(in: currentListRows().map(\.row)), current: sessionID, previous: previous)
            var whereTo = ControllerWhereToState(
                chats: islandChatRows(order, sessionID), currentChatID: sessionID,
                workspaces: chats.workspaceChoices(of: windowID), gridActive: window.isGridActive,
                previous: previous, tickets: chats.ticketBoards(of: windowID))
            whereTo.reopenTitle = closedChats.nextTitle()
            // Große Form an der Kamera-Insel: Kacheln in zwei Spalten.
            whereTo.setColumns(island.columns(onDisplay: window.screenDisplayID))
            content = .whereTo(whereTo)
        }
        return ControllerIslandSession(
            model: ControllerIslandModel(target: target, content: content, input: input),
            sessionID: sessionID, setup: setup, screenDisplayID: window.screenDisplayID,
            usageAccount: usageAccount)
    }

    /// Voriger Ort des Fensters (Ziel von L2 getippt): Seine Zeile trägt
    /// „vorher“. Eine Projekt-Ansicht ist als Workspace gemerkt; das Modell
    /// ordnet sie ihrer Projekt-Zeile zu.
    static func whereToPrevious(_ target: ControllerBackTarget?) -> ControllerWhereToState.Destination {
        guard let target, let id = target.id else { return .stay }
        switch target.kind {
        case .chat: return .chat(id)
        case .workspace: return .workspace(id)
        case .tickets: return .tickets(id)
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
            state.model.content = .quickDraw(slots.refreshed(setup: setup))
        case .whereTo:
            return
        }
        islandState = state
        present()
    }

    // MARK: - Wohin (L2)

    func moveInWhereTo(_ step: Int) {
        guard ensureIsland(.whereTo), var state = islandState, var whereTo = state.model.whereTo else { return }
        whereTo.moveRow(step)
        state.model.content = .whereTo(whereTo)
        islandState = state
        present()
    }

    func switchWhereToTab(_ step: Int) {
        // Mit Kacheln (Kamera-Insel) erst die Nachbar-Kachel, am Rand der Reihe der Reiter.
        guard ensureIsland(.whereTo), var state = islandState, var whereTo = state.model.whereTo,
              whereTo.moveSideways(step) else { return }
        state.model.content = .whereTo(whereTo)
        islandState = state
        present()
    }

    /// L2 losgelassen: wie Kreuz — zum markierten Eintrag. Die Markierung
    /// beginnt auf dem aktuellen Eintrag; ohne Bewegung passiert also nichts.
    func releaseWhereTo() {
        defer { spentLayer = nil }
        guard let whereTo = islandState?.model.whereTo else { return closeIsland() }
        closeIsland()
        if !go(to: whereTo.destination, previous: whereTo.previous) { playHaptic(.rejected) }
    }

    /// Kreuz (`dictate == false`) oder R2. Steht die Markierung auf dem
    /// aktuellen Eintrag, schließt Kreuz nur, R2 diktiert in den aktuellen
    /// Chat. Ein anderer Workspace oder ein Projekt ist kein Ziel für R2
    /// („geht nicht“, die Insel bleibt) — „hin und diktieren“ braucht einen Chat.
    func commitWhereTo(dictate: Bool) {
        guard spentLayer != .whereTo else { return }
        let whereTo = islandState?.model.whereTo
        let destination = whereTo?.destination ?? .stay
        switch destination {
        case .workspace, .project:
            if dictate { return playHaptic(.rejected) }
        case .tickets:
            // Hin und diktieren an den Board-Chat kommt mit WM8-113; bis dahin
            // „geht nicht“, die Insel bleibt (E4).
            if dictate { return playHaptic(.rejected) }
        case .stay, .chat:
            // Im Board gibt es keinen Chat, in den „hier“ diktiert würde.
            if dictate, destination == .stay, whereTo?.ticketBoards?.inTickets == true { return playHaptic(.rejected) }
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
    func go(
        to destination: ControllerWhereToState.Destination, previous: ControllerWhereToState.Destination
    ) -> Bool {
        // Ankunftssperre für Kreuz und Kreis im Chat, in den das führt (WM8-91).
        let before = visibleChatID
        var target: UUID?
        switch destination {
        case let .chat(sessionID): target = sessionID
        default: target = destination == previous ? backTargetChatID : nil
        }
        defer { if destination != .stay { noteArrival(at: target, before: before) } }
        if destination != .stay, destination == previous { return command(.lastChat, orReject: false) }
        switch destination {
        case .stay: return true
        case let .chat(sessionID): return command(.selectSession(sessionID), orReject: false)
        case let .workspace(workspaceID): return command(.switchToWorkspace(workspaceID), orReject: false)
        case let .project(projectID): return command(.switchToProject(projectID), orReject: false)
        case let .tickets(projectID): return command(.showTickets(projectID: projectID), orReject: false)
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
        // Offene Limits-Karte (Insel-Paket): ✕ holt die Zahlen frisch, die
        // übrigen Tasten der Chat-Raute gehen dort nicht.
        if quickDrawSlots?.card != nil {
            return item == .continueWork ? refreshLimitsCard() : playHaptic(.rejected)
        }
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
            return sendOrContinue(setup: setup) { self.flashQuickDrawHit(item) }
        }
        guard ControllerMenuModel.isEnabled(item, setup: setup) else { return playHaptic(.rejected) }
        flashQuickDrawHit(item)
        if item.opensSubmenu {
            var menu = ControllerMenuModel(setup: setup, selected: item)
            guard menu.openSubmenu() else { return playHaptic(.rejected) }
            ui.leaveList()
            ui.menuDialogOpen = setup.dialogOpen
            ui.menu = menu
            if item == .switchAccount { refreshAccountLimits() }
        } else {
            perform(item, setup: setup)
        }
    }

    /// Kreuz der R1-Raute und das Paddle „Jetzt senden / Weiter“: mit Text im
    /// Feld oder Wartendem Senden bzw. „Jetzt senden“ (Ctrl+X Ctrl+S), bei
    /// leerem Feld und ruhendem Chat „Weiter“; leeres Feld bei arbeitendem
    /// Chat, offene Rückfrage oder Ansicht: „geht nicht“. `onHit` läuft, bevor
    /// etwas rausgeht (die Raute leuchtet kurz auf).
    func sendOrContinue(setup: ControllerMenuSetup, onHit: () -> Void) {
        // Zuletzt noch einmal am Bildschirm: Steht bei Codex eine Freigabe
        // offen, bestätigte Enter (oder „Weiter“ mit Enter) sie. Der Stand im
        // `setup` kann älter sein (Insel offen, Freigabe erscheint danach).
        // Gilt für R1 + Kreuz, das Paddle und S in der Tastatur-Insel (WM8-104).
        if let sessionID = setup.sessionID, terminals.state(of: sessionID)?.screen?.codexApproval == true {
            return playHaptic(.rejected)
        }
        // Offene Ansicht (WM8-123): Enter, „Jetzt senden“ und „Weiter“ gingen in sie.
        if let sessionID = setup.sessionID, openViewBlocksSending(to: sessionID) {
            return playHaptic(.rejected)
        }
        switch setup.quickCross {
        case let cross? where cross != .continueWork:
            guard let sessionID = setup.sessionID, sessionID == selectedSessionID else {
                return playHaptic(.rejected)
            }
            onHit()
            if !terminals.sendKey(cross == .sendNow ? .sendNow : .enter, to: sessionID) { playHaptic(.rejected) }
        case nil:
            playHaptic(.rejected)
        default:
            guard ControllerMenuModel.isEnabled(.continueWork, setup: setup) else { return playHaptic(.rejected) }
            onHit()
            perform(.continueWork, setup: setup)
        }
    }

    /// Markiert den gedrückten Eintrag kurz und schließt die Insel danach.
    /// Bis zum Loslassen von R1 kommt sie nicht wieder.
    func flashQuickDrawHit(_ item: ControllerMenuItem) {
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
