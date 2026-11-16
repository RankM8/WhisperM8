import AppKit
import SwiftUI

/// Tastaturfokus im Ticket-Modus mit Board-Chat (WM8-113).
///
/// Ins Terminal des Board-Chats kommt der Fokus nur durch einen Klick ins
/// Terminal. Jeder andere Klick (Karte, Listenzeile, Pfeile, Knöpfe, freie
/// Fläche) gibt ihn vorher ans Fenster zurück. SwiftUI-Knöpfe nehmen den Fokus
/// nicht selbst: Ohne diese Regel blieben J/K, Esc und ⌘C nach einem Klick
/// ins Terminal dort, und Esc bräche Jarvis' laufenden Turn ab, obwohl
/// Giuliano am Board arbeitet.
enum BoardChatFocusRule {
    /// Pur: Fokus abgeben, wenn ein Terminal ihn hat und der Klick außerhalb liegt.
    static func releasesFocus(responderIsTerminal: Bool, clickInsideResponder: Bool) -> Bool {
        responderIsTerminal && !clickInsideResponder
    }

    /// Dieselbe Erkennung wie die Tasten des Boards (`handleTicketBoardKey`).
    static func isTerminal(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        return String(describing: type(of: responder)).contains("TerminalView")
    }

    /// Hört der Board-Chat auf zu laufen, behielte sein Terminal den Fokus,
    /// und das Board reagierte erst nach einem Klick daneben auf Tasten.
    static func releasesFocusWhenStopped(wasRunning: Bool, isRunning: Bool) -> Bool {
        wasRunning && !isRunning
    }

    /// Für Bedienwege ohne Maus (Controller, WM8-91): Fokus aus dem Terminal
    /// ans Fenster zurück, bevor Board oder Triage etwas tun.
    @MainActor
    static func releaseTerminalFocus(in window: NSWindow?) {
        guard let window, isTerminal(window.firstResponder) else { return }
        window.makeFirstResponder(nil)
    }
}

/// Unsichtbarer Wächter in der Spalte: beobachtet Mausklicks seines Fensters,
/// solange die Tickets offen sind, und wendet `BoardChatFocusRule` an. Der Klick
/// selbst geht danach unverändert weiter.
struct BoardChatFocusGuard: NSViewRepresentable {
    /// Läuft der Prozess des Board-Chats? Wechsel auf „gestoppt“ gibt den Fokus frei.
    var isBoardChatRunning = true

    func makeNSView(context: Context) -> BoardChatFocusGuardView {
        let view = BoardChatFocusGuardView()
        view.wasRunning = isBoardChatRunning
        return view
    }

    func updateNSView(_ nsView: BoardChatFocusGuardView, context: Context) {
        if BoardChatFocusRule.releasesFocusWhenStopped(wasRunning: nsView.wasRunning, isRunning: isBoardChatRunning) {
            BoardChatFocusRule.releaseTerminalFocus(in: nsView.window)
        }
        nsView.wasRunning = isBoardChatRunning
    }
    static func dismantleNSView(_ nsView: BoardChatFocusGuardView, coordinator: ()) { nsView.stop() }
}

final class BoardChatFocusGuardView: NSView {
    private var monitor: Any?
    /// Zuletzt gesehener Zustand des Board-Chats (für `updateNSView`).
    var wasRunning = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let window = self?.window, event.window === window,
                  let responder = window.firstResponder as? NSView else { return event }
            let inside = responder.bounds.contains(responder.convert(event.locationInWindow, from: nil))
            if BoardChatFocusRule.releasesFocus(responderIsTerminal: BoardChatFocusRule.isTerminal(responder),
                                                clickInsideResponder: inside) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Doppelpfeil am Ziehgriff über Cursor-Bereiche: AppKit setzt ihn zurück,
/// sobald der Griff verschwindet (anders als `NSCursor.push`/`pop`).
struct BoardChatResizeCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> BoardChatResizeCursorView { BoardChatResizeCursorView() }
    func updateNSView(_ nsView: BoardChatResizeCursorView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class BoardChatResizeCursorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}
