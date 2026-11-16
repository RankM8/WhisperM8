import SwiftUI

/// Rahmen um die Spalte des Board-Chats, solange der Controller dort die
/// Tasten hat (WM8-91 Paket 3a). Ohne Hover: Der Rahmen steht, solange der
/// Fokus gilt, und zeigt so, welcher Teil des Fensters Kreuz, Kreis und die
/// Pfeile bekommt. Gleiche Farbe und Stärke wie der Ring der gewählten Karte.
///
/// Kosten: Der Body liest nur `ControllerUIModel.boardChatFocus` und die
/// Anmeldung des Board-Chats dieses Fensters; beides ändert sich nur beim
/// Wechsel hinein oder heraus, nie im Takt des Terminals.
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

    var body: some View {
        if BoardChatControllerFocusFrame.isShown(focus: ui.boardChatFocus, windowID: windowID,
                                                 shownSessionID: inputs.boardChat(in: windowID)?.sessionID) {
            Rectangle()
                .strokeBorder(AgentTheme.accent, lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityLabel(Text("The controller is in the board chat"))
        }
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
