import AppKit
import Foundation

/// Sperre nach einem Sprung per Tastatur in ein Terminal (WM8-91 Paket 3c):
/// dieselbe Regel wie am Controller (`ControllerBindingResolver.arrivalLock`).
/// Return und Esc wirken in der ersten Sekunde nach „→ in den Board-Chat“ oder
/// „Return auf der Chat-Zeile“ nicht, mit Warnton. Ein schnell nachgedrücktes
/// Return bestätigt so keine Freigabe, die dort schon lange offen ist, und
/// Esc bricht keinen Turn ab, den man noch gar nicht gesehen hat.
@MainActor
final class KeyboardArrivalLock {
    static let shared = KeyboardArrivalLock()

    static let duration: TimeInterval = ControllerBindingResolver.arrivalLock

    private(set) var arrival: (sessionID: UUID, at: Date)?
    var now: () -> Date = Date.init

    /// Die Tastatur ist gerade in `sessionID` angekommen.
    func arrive(at sessionID: UUID) {
        arrival = (sessionID, now())
    }

    /// Chat, für den die Sperre gerade gilt; räumt eine abgelaufene weg.
    func lockedSession() -> UUID? {
        guard let arrival else { return nil }
        guard now().timeIntervalSince(arrival.at) < Self.duration else {
            self.arrival = nil
            return nil
        }
        return arrival.sessionID
    }

    /// Pur: Gesperrt sind Return, Enter und Esc ohne ⌘ (⌘-Kürzel bleiben frei).
    nonisolated static func blocks(keyCode: UInt16, command: Bool) -> Bool {
        guard !command else { return false }
        return keyCode == 36 || keyCode == 76 || keyCode == 53
    }
}

// MARK: - Fenster

extension AgentChatsView {
    /// Erster Schritt der Tasten-Kette: Hat die Tastatur gerade einen Chat
    /// erreicht und liegt der Fokus in dessen Terminal, gehen Return und Esc
    /// in der ersten Sekunde nicht hinein. Kosten ohne Sperre: ein Vergleich.
    func handleKeyboardArrivalLock(_ event: NSEvent) -> NSEvent? {
        guard let sessionID = KeyboardArrivalLock.shared.lockedSession(),
              let hostWindow, event.window === hostWindow,
              KeyboardArrivalLock.blocks(keyCode: event.keyCode, command: event.modifierFlags.contains(.command)),
              let terminal = terminalRegistry.controller(for: sessionID)?.terminal,
              hostWindow.firstResponder === terminal else { return event }
        NSSound.beep()
        return nil
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
