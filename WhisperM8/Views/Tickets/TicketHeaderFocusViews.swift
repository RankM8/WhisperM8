import SwiftUI

// Sichtbare Auswahl im Kopf des Boards (WM8-91 Paket 3d): Ring wie an der
// gewählten Karte, ohne Hover; die Liste der Bereiche unter „Alle Bereiche“.
//
// Kosten: Jeder Ring ist eine eigene kleine Ansicht, die nur `headerFocus`
// (und die Anmeldung des Board-Chats) liest. Bewegt sich die Auswahl im Kopf,
// werten nur die Ringe neu aus, nicht Kopf, Filterzeile oder Board.

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

/// Zieht die Filterzeile mit, damit der gewählte Filter zu sehen ist (die
/// Zeile scrollt waagrecht, wenn rechts der Board-Chat steht).
struct TicketHeaderScroller: View {
    let model: TicketBoardViewModel
    let proxy: ScrollViewProxy

    var body: some View {
        let item = model.headerFocus == nil ? nil : model.headerItem(.current(for: model))
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: item) { _, item in
                guard let item else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item, anchor: .center) }
            }
    }
}

/// Lage des Knopfs „Alle Bereiche“, für die Liste darunter.
struct TicketProjectPickerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Liste der Bereiche (Entscheidung 16.11.2026, „Liste darunter“): ▲ ▼ wählen,
/// Kreuz übernimmt, Kreis schließt. Steht nur, solange sie offen ist. Ein
/// Mausklick auf einen Eintrag wählt ihn schon beim Drücken (WM8-91): Nach
/// jedem Klick räumt die App den Kopf, die Liste wäre beim Loslassen weg.
struct TicketProjectPickerList: View {
    let model: TicketBoardViewModel
    let projects: [String]

    var body: some View {
        if let index = model.projectPickerIndex {
            let options = TicketHeaderSelection.projectOptions(projects)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.offset) { offset, option in
                    HStack(spacing: 6) {
                        // Haken am Bereich, der gerade gilt.
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(option == model.filter.project ? 1 : 0)
                            .frame(width: 12)
                        Text(verbatim: option.map(TicketBoardText.project) ?? String(localized: "All projects"))
                            .font(.system(size: 12, weight: offset == index ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(AgentTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minWidth: 180, alignment: .leading)
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
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.chooseProjectByMouse(option) })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.chooseProjectByMouse(option) }
                }
            }
            .padding(6)
            .background(AgentTheme.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AgentTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Linear project"))
        }
    }
}
