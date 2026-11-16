import AppKit
import Foundation

/// Sperre nach einem Sprung per Tastatur in ein Terminal (WM8-91 Paket 3c):
/// dieselbe Regel wie am Controller (`ControllerBindingResolver.arrivalLock`).
/// Return und Esc wirken in der ersten Sekunde nach „→ in den Board-Chat“,
/// „Return auf der Chat-Zeile“ oder „← Chats“ nicht, mit Warnton. Ein schnell
/// nachgedrücktes Return bestätigt so keine Freigabe, die dort schon lange
/// offen ist, und Esc bricht keinen Turn ab, den man noch gar nicht gesehen hat.
///
/// Gehaltenes Return (Auflage der Prüferin): Die Tastenwiederholung beginnt
/// nach rund 0,5 s und liefe sonst nach Ablauf der Sekunde als Enter in den
/// Ziel-Chat. Deshalb werden Wiederholungen von Return, Enter und Esc dort
/// geschluckt, bis ein neuer, nicht wiederholter Tastendruck kommt.
@MainActor
final class KeyboardArrivalLock {
    static let shared = KeyboardArrivalLock()

    static let duration: TimeInterval = ControllerBindingResolver.arrivalLock

    enum Verdict: Equatable {
        /// Geht ins Terminal.
        case pass
        /// Wiederholung einer gehaltenen Taste: still verschluckt.
        case swallow
        /// Neuer Druck während der Sperre: verschluckt, mit Warnton.
        case refuse
    }

    private(set) var arrival: (sessionID: UUID, at: Date)?
    /// Seit der Ankunft kam noch kein neuer, nicht wiederholter Tastendruck
    /// außerhalb der Sperre: Wiederholungen von Return, Enter, Esc bleiben gesperrt.
    private(set) var holdsRepeats = false
    var now: () -> Date = Date.init

    /// Die Tastatur ist gerade in `sessionID` angekommen.
    func arrive(at sessionID: UUID) {
        arrival = (sessionID, now())
        holdsRepeats = true
    }

    /// Chat, für den Sperre oder Schlucken der Wiederholungen gerade gelten;
    /// räumt beides weg, wenn nichts mehr gilt.
    func lockedSession() -> UUID? {
        guard let arrival else { return nil }
        if now().timeIntervalSince(arrival.at) < Self.duration || holdsRepeats { return arrival.sessionID }
        self.arrival = nil
        return nil
    }

    /// Eine Taste im angekommenen Terminal. Ein neuer Druck außerhalb der
    /// Sperre beendet das Schlucken; einer innerhalb nicht (seine eigenen
    /// Wiederholungen kämen sonst nach Ablauf durch).
    func judge(keyCode: UInt16, command: Bool, isRepeat: Bool) -> Verdict {
        guard let arrival else { return .pass }
        let guarded = Self.blocks(keyCode: keyCode, command: command)
        let within = now().timeIntervalSince(arrival.at) < Self.duration
        if !isRepeat, !(guarded && within) { holdsRepeats = false }
        guard guarded else { return .pass }
        if within { return isRepeat ? .swallow : .refuse }
        return isRepeat && holdsRepeats ? .swallow : .pass
    }

    /// Pur: Gesperrt sind Return, Enter und Esc ohne ⌘ (⌘-Kürzel bleiben frei).
    nonisolated static func blocks(keyCode: UInt16, command: Bool) -> Bool {
        guard !command else { return false }
        return keyCode == 36 || keyCode == 76 || keyCode == 53
    }
}

/// Wo die Tastatur nach „← Chats“ im Kopf des Boards ankommt (WM8-91). Einen
/// Chat kennt der Weg vorher (`backPlace()`); in einem Workspace (Raster)
/// steht die Kachel mit Fokus erst fest, wenn der Store ihn aktiviert hat
/// (synchron, mit der Kachel, auf der man dort zuletzt war). Dasselbe gilt,
/// wenn es keinen vorigen Ort gibt und nur die Tickets zugehen: Dann gilt der
/// Chat, der dahinter steht. Bleiben die Tickets offen (anderes Board oder
/// der Weg ging nicht), kommt die Tastatur in keinem Chat an. Pur.
enum KeyboardBackArrival {
    static func chatBefore(_ place: ChatPlace?) -> UUID? {
        if case .chat(let id)? = place { return id }
        return nil
    }

    static func shownAfter(placeBefore: ChatPlace?, ticketsStillOpen: Bool, shown: UUID?) -> UUID? {
        guard chatBefore(placeBefore) == nil, !ticketsStillOpen else { return nil }
        return shown
    }
}

// MARK: - Fenster

extension AgentChatsView {
    /// Erster Schritt der Tasten-Kette: Hat die Tastatur gerade einen Chat
    /// erreicht und liegt der Fokus in dessen Terminal, gehen Return und Esc
    /// in der ersten Sekunde nicht hinein, ihre Wiederholungen auch danach
    /// nicht. Kosten ohne Sperre: ein Vergleich.
    func handleKeyboardArrivalLock(_ event: NSEvent) -> NSEvent? {
        let lock = KeyboardArrivalLock.shared
        guard let sessionID = lock.lockedSession(),
              let hostWindow, event.window === hostWindow,
              let terminal = terminalRegistry.controller(for: sessionID)?.terminal,
              hostWindow.firstResponder === terminal else { return event }
        switch lock.judge(keyCode: event.keyCode, command: event.modifierFlags.contains(.command),
                          isRepeat: event.isARepeat) {
        case .pass: return event
        case .swallow: return nil
        case .refuse:
            NSSound.beep()
            return nil
        }
    }

    /// Eine Taste des Boards über denselben Weg wie der Controller
    /// (`performTicketCommand`). `true`: genommen.
    func performTicketKey(_ key: TicketBoardKey) -> Bool {
        let model = TicketBoardControllers.shared.controller(for: windowID).viewModel
        let command: ControllerTicketCommand
        switch key {
        // ⌘C ohne gewähltes Ticket gehört dem Fenster (wie bisher).
        case .copyLink: return model.copyLink()
        case .leaveBoardChat:
            // Aus dem Terminal des Board-Chats zurück aufs Ticket: Board und
            // Triage haben ihre Auswahl behalten.
            guard let hostWindow, BoardChatFocusRule.isTerminal(hostWindow.firstResponder) else { return false }
            hostWindow.makeFirstResponder(nil)
            return true
        case .next: command = .adjacent(1)
        case .previous: command = .adjacent(-1)
        case .close: command = .back
        case let .move(direction, isRepeat): command = isRepeat ? .repeatMove(direction) : .move(direction)
        case .open: command = .open
        case let .adjacent(step): command = .adjacent(step)
        case .openInLinear: command = .openInLinear
        case .refresh: command = .refresh
        case .handOff: command = .handOff
        case .menu:
            // Die Menü-Karte gehört dem Controller-Ausführer; bedient wird sie
            // dann wie aus der Insel per Tastatur. Ohne Controller-Steuerung Warnton.
            if !KeyboardIslandMonitor.shared.openTicketMenu() { NSSound.beep() }
            return true
        }
        // Aus dem Terminal des Board-Chats (nur ⌘⌥←/→, ⌘⇧←/→, ⌘J kommen von
        // dort): Der Tastaturfokus bleibt im Chat, man blättert im Gespräch.
        let fromBoardChat = key.isBoardChatKey && BoardChatFocusRule.isTerminal(hostWindow?.firstResponder)
        switch performTicketCommand(command, keepsTerminalFocus: fromBoardChat) {
        case .done, .nothing:
            return true
        case .leftEdge:
            // Die Seitenleiste hat keine Tastatur-Auswahl; ← bleibt am Rand.
            return true
        case .rightEdge:
            return focusBoardChatFromKeyboard()
        case .topEdge:
            // Wandelt das Fenster selbst in den Einstieg in den Kopf um (Paket 3d).
            return true
        case .goBack:
            // „← Chats“ im Kopf (Paket 3d): wie der Knopf. Return und Esc warten
            // im Ziel-Chat 1 s, wie nach jedem Sprung per Tastatur; im Raster
            // in der Kachel mit Fokus (`KeyboardBackArrival`).
            let place = backPlace()
            if let id = KeyboardBackArrival.chatBefore(place) { KeyboardArrivalLock.shared.arrive(at: id) }
            ticketsBackLink.go()
            if let id = KeyboardBackArrival.shownAfter(
                placeBefore: place, ticketsStillOpen: isTicketsModeActive, shown: selectedSessionID) {
                KeyboardArrivalLock.shared.arrive(at: id)
            }
            return true
        case .rejected:
            // Esc außerhalb der Triage gehört dem Fenster (Dialoge, Suche).
            if key == .close { return false }
            NSSound.beep()
            return true
        }
    }

    /// → am Rand (Entscheidung 16.11.2026): Das Terminal des Board-Chats
    /// bekommt den Tastaturfokus, mit derselben Sperre von 1 s wie am Controller.
    /// Ohne sichtbaren Board-Chat Warnton.
    func focusBoardChatFromKeyboard() -> Bool {
        guard let boardChat = BoardChatInputs.shared.boardChat(in: windowID),
              let controller = terminalRegistry.controller(for: boardChat.sessionID) else {
            NSSound.beep()
            return true
        }
        KeyboardArrivalLock.shared.arrive(at: boardChat.sessionID)
        controller.focusTerminal()
        return true
    }
}
