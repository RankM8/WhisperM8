import SwiftUI

// Sichtbare Auswahl im Kopf der Board-Chat-Spalte (WM8-126): Ring wie an der
// gewählten Karte und im Kopf des Boards, ohne Hover; die Liste unter
// „Anderer Chat …“.
//
// Kosten: Jeder Ring und die Liste sind eigene kleine Ansichten, die nur
// `columnFocus` bzw. `columnPickerIndex` lesen. Bewegt sich die Auswahl,
// werten nur sie neu aus, nicht die Spalte und nie das Terminal.

struct BoardChatHeadFocusRing: View {
    let item: BoardChatHeadItem
    let model: TicketBoardViewModel?
    var cornerRadius: CGFloat = 7

    var body: some View {
        if let model, model.columnFocus == item {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AgentTheme.accent, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Ring, solange Controller oder Tastatur diesen Knopf im Kopf der Spalte gewählt haben.
    func boardChatHeadRing(_ item: BoardChatHeadItem, model: TicketBoardViewModel?,
                           cornerRadius: CGFloat = 7) -> some View {
        overlay { BoardChatHeadFocusRing(item: item, model: model, cornerRadius: cornerRadius) }
    }
}

/// Liste unter „Anderer Chat …“: ▲ ▼ wählen, Kreuz holt den Chat in die
/// Spalte, Kreis schließt. Steht nur, solange sie offen ist. Ein Mausklick
/// auf einen Eintrag wählt ihn schon beim Drücken: Nach jedem Klick räumt die
/// App die Köpfe, die Liste wäre beim Loslassen weg (wie die Liste der Bereiche).
struct BoardChatOtherChatsList: View {
    let model: TicketBoardViewModel?
    let options: [BoardChatHeadOption]
    let choose: (UUID) -> Void

    var body: some View {
        if let model, let index = model.columnPickerIndex {
            VStack(alignment: .leading, spacing: 4) {
                Text("Show as board chat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.horizontal, 8)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(options.enumerated()), id: \.element.id) { offset, option in
                                row(option, isSelected: offset == index, model: model)
                                    .id(option.id)
                            }
                        }
                    }
                    // Höhe nach der Zahl der Zeilen (je rund 38 pt), höchstens 220 pt.
                    .frame(height: min(CGFloat(options.count) * 38, 220))
                    .onChange(of: index) { _, index in
                        guard options.indices.contains(index) else { return }
                        proxy.scrollTo(options[index].id)
                    }
                }
            }
            .padding(6)
            .background(AgentTheme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(AgentTheme.border).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Show as board chat"))
        }
    }

    private func row(_ option: BoardChatHeadOption, isSelected: Bool, model: TicketBoardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: option.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(AgentTheme.textPrimary)
            Text(verbatim: option.title)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textSecondary)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AgentTheme.accent.opacity(0.14))
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AgentTheme.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in pick(option.id, model: model) })
        .help(option.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(String(localized: "Show \(option.title) as board chat"))
        .accessibilityAction { pick(option.id, model: model) }
    }

    /// Maus: wählt und räumt den Kopf, denn die Maus hat übernommen. Die Liste
    /// enthält nur Chats nach `BoardChatRules.rejection`; ein Wechsel schreibt
    /// nur die gespeicherte Wahl, nie in einen Chat.
    private func pick(_ id: UUID, model: TicketBoardViewModel) {
        guard model.columnPickerIndex != nil else { return }
        model.leaveHeader()
        choose(id)
    }
}
