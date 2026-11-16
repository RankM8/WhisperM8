import SwiftUI

/// Laufende Chats ohne Ticket und die Supervisor-Chats, als eine Zeile
/// mit Zahl. Aufgeklappt stehen die Chats als Knöpfe da. Die Zeile dient vor
/// allem dem Supervisor; zugeklappt nimmt sie dem Board keinen Platz.
struct TicketLooseChatsBar: View {
    let chats: [TicketLooseChat]
    /// Supervisor-Chats betreuen andere und brauchen kein Ticket; sie stehen
    /// getrennt und zählen nicht als Lücke.
    var supervisors: [TicketChat] = []
    let source: TicketChatStatusSource
    let openChat: (UUID) -> Void
    /// Für Bilder und Tests aufgeklappt.
    @State var isExpanded = false

    var body: some View {
        if !chats.isEmpty || !supervisors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .frame(width: 12)
                        Text("Running chats without a ticket: \(chats.count)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(AgentTheme.textSecondary)
                        if !isExpanded, let first = supervisors.first {
                            Text("Supervisor")
                                .font(.system(size: 11))
                                .foregroundStyle(AgentTheme.textSecondary)
                                .padding(.leading, 6)
                            TicketChatStatusDot(chatID: first.id, source: source)
                            Text(verbatim: first.shortName)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AgentTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isExpanded ? [.isSelected] : [])

                if isExpanded {
                    chips
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(TicketBoardStyle.column, in: TicketBoardStyle.shape)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chats) { loose in
                    Button {
                        openChat(loose.chat.id)
                    } label: {
                        HStack(spacing: 6) {
                            TicketChatStatusDot(chatID: loose.chat.id, source: source)
                            Text(verbatim: loose.chat.shortName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AgentTheme.textPrimary)
                            TicketLooseChatTrail(earlier: loose.earlier)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AgentTheme.surface, in: Capsule())
                        .overlay { Capsule().strokeBorder(AgentTheme.border, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .help(Text("Go to chat"))
                }
                if !supervisors.isEmpty {
                    Text("Supervisor")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .padding(.leading, chats.isEmpty ? 0 : 8)
                    ForEach(supervisors) { chat in
                        Button {
                            openChat(chat.id)
                        } label: {
                            HStack(spacing: 6) {
                                TicketChatStatusDot(chatID: chat.id, source: source)
                                Text(verbatim: chat.shortName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AgentTheme.textSecondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .help(Text("Go to chat"))
                    }
                }
            }
            .padding(.leading, 20)
        }
    }
}

/// Woran der Chat zuletzt saß.
private struct TicketLooseChatTrail: View {
    let earlier: [String]

    var body: some View {
        Group {
            if let last = earlier.last {
                Text("last on \(last)")
            } else {
                Text("never linked")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(AgentTheme.textSecondary)
        .lineLimit(1)
    }
}
