import AppKit
import SwiftUI

/// Rahmen um die Spalte des Board-Chats, solange er die Tasten hat
/// (WM8-91): der Controller nach ▶ über den Rand (Paket 3a) oder die Tastatur
/// mit Fokus in seinem Terminal (Paket 3c, → am Rand oder ein Klick). Ohne
/// Hover: Der Rahmen steht, solange das gilt, und zeigt so, welcher Teil des
/// Fensters Return, Esc und die Pfeile bekommt. Gleiche Farbe und Stärke wie
/// der Ring der gewählten Karte.
///
/// Kosten: Der Body liest nur `ControllerUIModel.boardChatFocus`, die
/// Anmeldung des Board-Chats dieses Fensters und einen Merker für den
/// Tastaturfokus, den eine KVO-Beobachtung von `firstResponder` setzt; alles
/// ändert sich nur beim Wechsel hinein oder heraus, nie im Takt des Terminals.
struct BoardChatControllerFocusFrame: ViewModifier {
    let windowID: UUID

    func body(content: Content) -> some View {
        content.overlay {
            BoardChatControllerFocusRing(windowID: windowID)
        }
    }
}

private struct BoardChatControllerFocusRing: View {
    let windowID: UUID
    @State private var ui = ControllerUIModel.shared
    @State private var inputs = BoardChatInputs.shared
    @State private var keyboardFocus = false

    var body: some View {
        let shown = inputs.boardChat(in: windowID)?.sessionID
        ZStack {
            BoardChatKeyboardFocusObserver(sessionID: shown, hasFocus: $keyboardFocus)
                .frame(width: 0, height: 0)
            if keyboardFocus && shown != nil
                || BoardChatControllerFocusFrame.isShown(focus: ui.boardChatFocus, windowID: windowID,
                                                         shownSessionID: shown) {
                Rectangle()
                    .strokeBorder(AgentTheme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text("The board chat has the keys"))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Meldet, ob das Terminal des Board-Chats der First Responder seines Fensters
/// ist. Beobachtet `NSWindow.firstResponder` per KVO; ohne Fenster nichts.
private struct BoardChatKeyboardFocusObserver: NSViewRepresentable {
    let sessionID: UUID?
    @Binding var hasFocus: Bool

    func makeNSView(context: Context) -> BoardChatKeyboardFocusView {
        let view = BoardChatKeyboardFocusView()
        view.onChange = { focused in if hasFocus != focused { hasFocus = focused } }
        return view
    }

    func updateNSView(_ view: BoardChatKeyboardFocusView, context: Context) {
        view.onChange = { focused in if hasFocus != focused { hasFocus = focused } }
        if view.sessionID != sessionID {
            view.sessionID = sessionID
            view.evaluate()
        }
    }

    static func dismantleNSView(_ view: BoardChatKeyboardFocusView, coordinator: ()) { view.stop() }
}

final class BoardChatKeyboardFocusView: NSView {
    var sessionID: UUID?
    var onChange: ((Bool) -> Void)?
    private var observation: NSKeyValueObservation?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        guard let window else { return }
        observation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            self?.evaluate()
        }
        evaluate()
    }

    /// Immer im nächsten Durchgang: Nie den SwiftUI-Zustand mitten in einer
    /// Auswertung ändern (Aufruf auch aus `updateNSView`).
    func evaluate() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let focused: Bool
            if let window = self.window, let sessionID = self.sessionID,
               let terminal = AgentTerminalRegistry.shared.controller(for: sessionID)?.terminal {
                focused = window.firstResponder === terminal
            } else {
                focused = false
            }
            self.onChange?(focused)
        }
    }

    func stop() {
        observation = nil
        onChange = nil
    }
}

extension BoardChatControllerFocusFrame {
    /// Pur: nur für dieses Fenster und nur, solange die Spalte genau diesen
    /// Chat zeigt.
    static func isShown(focus: ControllerBoardChatFocus?, windowID: UUID, shownSessionID: UUID?) -> Bool {
        guard let focus, focus.windowID == windowID else { return false }
        return shownSessionID == focus.sessionID
    }
}
