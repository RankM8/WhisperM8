import SwiftUI

// Sichtbare Auswahl im Kopf des Boards (WM8-91 Paket 3d): Ring wie an der
// gewählten Karte, ohne Hover; die Liste unter „Mehr“ (WM8-125).
//
// Kosten: Jeder Ring ist eine eigene kleine Ansicht, die nur `headerFocus`
// (und die Anmeldung des Board-Chats) liest. Bewegt sich die Auswahl im Kopf,
// werten nur die Ringe neu aus, nicht Kopf, Reiterzeile oder Board.

extension TicketHeaderContext {
    /// Derselbe Kopf wie im Fenster (`performTicketCommand`): „← Chats“ steht
    /// immer da, „→ Jarvis“ nur mit sichtbarem Board-Chat.
    @MainActor
    static func current(for model: TicketBoardViewModel) -> TicketHeaderContext {
        TicketHeaderContext(
            hasBack: true,
            hasBoardChat: model.windowID.flatMap { BoardChatInputs.shared.boardChat(in: $0) } != nil)
    }
}

struct TicketHeaderFocusRing: View {
    let item: TicketHeaderItem
    let model: TicketBoardViewModel
    var cornerRadius: CGFloat = 7

    var body: some View {
        if model.headerFocus != nil, model.headerItem(.current(for: model)) == item {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AgentTheme.accent, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Ring, solange Controller oder Tastatur diesen Knopf im Kopf gewählt haben.
    func ticketHeaderRing(_ item: TicketHeaderItem, model: TicketBoardViewModel, cornerRadius: CGFloat = 7) -> some View {
        overlay { TicketHeaderFocusRing(item: item, model: model, cornerRadius: cornerRadius) }
    }
}

/// Lage des Knopfs „Mehr“, für die Liste darunter.
struct TicketMorePickerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Liste unter „Mehr“ (WM8-125): Reiter, die nicht in die Zeile passen. ▲ ▼
/// wählen, Kreuz zeigt die Ansicht, Kreis schließt; die Maus öffnet sie über
/// den Knopf und wählt beim Drücken (wie früher die Liste der Bereiche). Steht
/// nur, solange sie offen ist. Kein `.contextMenu`, kein Hover.
struct TicketMoreViewsList: View {
    let model: TicketBoardViewModel
    let views: [TicketView]

    var body: some View {
        if let index = model.morePickerIndex {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(views.enumerated()), id: \.element.id) { offset, view in
                    HStack(spacing: 6) {
                        // Haken an der Ansicht, die gerade gilt.
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(view.id == model.activeViewID ? 1 : 0)
                            .frame(width: 12)
                        Text(verbatim: view.name)
                            .font(.system(size: 12, weight: offset == index ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(AgentTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minWidth: 200, alignment: .leading)
                    .background {
                        if offset == index {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AgentTheme.accent.opacity(0.14))
                        }
                    }
                    .overlay {
                        if offset == index {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(AgentTheme.accent, lineWidth: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.chooseMoreViewByMouse(view.id) })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.chooseMoreViewByMouse(view.id) }
                }
            }
            .padding(6)
            .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AgentTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("More views"))
        }
    }
}
