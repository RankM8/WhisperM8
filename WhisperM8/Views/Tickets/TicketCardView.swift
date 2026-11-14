import SwiftUI

/// Eine Karte im Board: Nummer, Titel, Projekt, Priorität, Labels, Person und
/// der Chat, der daran sitzt. Alles ist ohne Mauszeiger sichtbar.
struct TicketCardView: View {
    let entry: TicketBoardEntry
    let isSelected: Bool
    let source: TicketChatStatusSource
    let select: () -> Void

    private var ticket: Ticket { entry.ticket }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: ticket.key)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(AgentTheme.textSecondary)
                    TicketPriorityBars(priority: ticket.priority)
                    if let criteria = ticket.criteria { TicketCriteriaBadge(progress: criteria) }
                    Spacer(minLength: 4)
                    TicketAvatar(person: ticket.assignee)
                }
                Text(verbatim: ticket.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: TicketBoardText.placement(ticket))
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                TicketCardTags(ticket: ticket)
                Rectangle().fill(AgentTheme.border).frame(height: 1)
                TicketAgentRow(entry: entry, source: source)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AgentTheme.selection : AgentTheme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? AgentTheme.accent : AgentTheme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Status des Teams, „blockiert“ und die Labels des Tickets.
struct TicketCardTags: View {
    let ticket: Ticket
    /// Mehr Labels machen die Karte unruhig; der Rest steht im Detail.
    var maxLabels = 2

    var body: some View {
        HStack(spacing: 4) {
            TicketTag(text: ticket.status.name)
            if ticket.isBlocked {
                TicketTag(text: String(localized: "Blocked"), tone: AgentTheme.statusError)
            }
            ForEach(ticket.labels.prefix(maxLabels), id: \.self) { label in
                TicketTag(text: label, tone: AgentTheme.accent)
            }
            if ticket.labels.count > maxLabels {
                Text(verbatim: "+\(ticket.labels.count - maxLabels)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
        }
    }
}

/// Spalten des Boards.
struct TicketBoardColumnsView: View {
    let columns: [TicketBoardColumn]
    let selectedKey: String?
    let source: TicketChatStatusSource
    let select: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(verbatim: TicketBoardText.column(column.kind))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentTheme.textPrimary)
                        Text(verbatim: "\(column.entries.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(AgentTheme.textSecondary)
                        Spacer(minLength: 4)
                        Text("\(column.agentCount) with agent")
                            .font(.system(size: 11))
                            .foregroundStyle(AgentTheme.textSecondary)
                    }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(column.entries) { entry in
                                TicketCardView(entry: entry, isSelected: selectedKey == entry.ticket.key, source: source) {
                                    select(entry.ticket.key)
                                }
                            }
                            if column.entries.isEmpty {
                                Text("Nothing for this filter.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(AgentTheme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
