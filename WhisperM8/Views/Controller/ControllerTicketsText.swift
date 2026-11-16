import SwiftUI
import Foundation

/// Texte rund um das Ticket-Board am Controller (WM8-91).
enum ControllerTicketsText {
    /// Ort in Leiste und Inselkopf: „Tickets · WM8“, ohne bekanntes Team nur „Tickets“.
    static func placeTitle(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return String(localized: "Tickets") }
        return String(localized: "Tickets · \(label)")
    }

    /// Ort in Leiste und Inselkopf, wenn der Controller im Board-Chat ist
    /// (Paket 3a): „Board-Chat · Jarvis“.
    static func boardChatTitle(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return String(localized: "Board chat") }
        return String(localized: "Board chat · \(name)")
    }

    /// Kurze Bestätigung nach einer Taste im Board.
    static func notice(_ notice: ControllerTicketNotice) -> String {
        switch notice {
        case .linkCopied: return String(localized: "Link copied")
        case .listCopied: return String(localized: "List copied")
        case .refreshing: return String(localized: "Refreshing…")
        case .dictationNeedsBoardChat: return String(localized: "Dictation only with the board chat")
        }
    }
}


/// Meldet die gewählte Karte bzw. den Kopf des großen Tickets als Anker der
/// Menü-Karte, solange das Menü am Ticket offen ist (WM8-91). Die Karte hängt
/// dann rechts bündig darunter, wie am Chat-Kopf.
private struct ControllerTicketMenuAnchorMark: View {
    @State private var model = ControllerUIModel.shared

    var body: some View {
        if model.menu?.setup.ticket != nil {
            Color.clear
                .anchorPreference(key: ControllerMenuAnchorKey.self, value: .bounds) { [.header: $0] }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Anker der Menü-Karte im Ticket-Board; nur, wo `active` gilt.
    @ViewBuilder
    func controllerTicketMenuAnchor(active: Bool) -> some View {
        if active { background(ControllerTicketMenuAnchorMark()) } else { self }
    }

    /// Fokus des Controllers auf einer Zeile unter „Chats am Ticket“: Ring in
    /// Akzentfarbe, ohne Mauszeiger sichtbar.
    func ticketChatLineFocus(_ focused: Bool) -> some View {
        padding(4)
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AgentTheme.accent, lineWidth: 2)
                }
            }
    }
}
