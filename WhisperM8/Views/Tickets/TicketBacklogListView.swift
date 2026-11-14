import SwiftUI

/// Backlog als Liste: alle sichtbaren Tickets nach Projekt.
struct TicketBacklogListView: View {
    let groups: [TicketBoardPresentation.Group]
    let selectedKey: String?
    let source: TicketChatStatusSource
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(groups) { group in
                    HStack(spacing: 8) {
                        Text(verbatim: TicketBoardText.project(group.project))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentTheme.textPrimary)
                        TicketGroupCount(tickets: group.entries.count, withAgent: group.agentCount)
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .padding(.horizontal, 10)

                    ForEach(group.entries) { entry in
                        TicketBacklogRow(entry: entry, isSelected: selectedKey == entry.ticket.key, source: source) {
                            select(entry.ticket.key)
                        }
                    }
                }
                if groups.isEmpty {
                    Text("Nothing for this filter.")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .padding(14)
                }
            }
            .padding(.bottom, 10)
        }
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TicketBacklogRow: View {
    let entry: TicketBoardEntry
    let isSelected: Bool
    let source: TicketChatStatusSource
    let select: () -> Void

    private var ticket: Ticket { entry.ticket }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Text(verbatim: ticket.key)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 62, alignment: .leading)
                TicketPriorityBars(priority: ticket.priority)
                Text(verbatim: ticket.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if ticket.isBlocked {
                    TicketTag(text: String(localized: "Blocked"), tone: AgentTheme.statusError)
                }
                if let criteria = ticket.criteria { TicketCriteriaBadge(progress: criteria) }
                Text(verbatim: ticket.status.name)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                TicketAvatar(person: ticket.assignee)
                TicketAgentRow(entry: entry, source: source, compact: true)
                    .frame(width: 150, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? AgentTheme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// „6 Tickets · 1 mit Agent“, mit eigener Fassung für genau eines.
private struct TicketGroupCount: View {
    let tickets: Int
    let withAgent: Int

    var body: some View {
        Group {
            if tickets == 1 {
                Text("1 ticket · \(withAgent) with agent")
            } else {
                Text("\(tickets) tickets · \(withAgent) with agent")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(AgentTheme.textSecondary)
    }
}

/// Leiste unter dem Board: laufende Chats, an denen kein offenes Ticket hängt.
struct TicketLooseChatsBar: View {
    let chats: [TicketLooseChat]
    let source: TicketChatStatusSource
    let openChat: (UUID) -> Void

    var body: some View {
        if !chats.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("Running chats without a ticket (\(chats.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.textSecondary)
                    ForEach(chats) { loose in
                        Button {
                            openChat(loose.chat.id)
                        } label: {
                            HStack(spacing: 6) {
                                TicketChatStatusDot(chatID: loose.chat.id, source: source, fallback: loose.chat.state)
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
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
