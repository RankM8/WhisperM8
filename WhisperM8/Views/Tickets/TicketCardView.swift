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
                    if let criteria = entry.criteria { TicketCriteriaBadge(progress: criteria) }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TicketBoardText.spoken(entry)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Status des Teams, „blockiert“ und die Labels des Tickets.
struct TicketCardTags: View {
    let ticket: Ticket
    /// Mehr Labels machen die Karte unruhig; der Rest steht im Detail.
    var maxLabels = 2
    /// Auf der Karte fällt der Status weg, wenn er nur die Spalte wiederholt.
    var hidesColumnStatus = true

    var body: some View {
        let labels = TicketBoardText.cardLabels(ticket.labels)
        HStack(spacing: 4) {
            if !(hidesColumnStatus && TicketBoardText.repeatsColumn(ticket.status)) {
                TicketTag(text: ticket.status.name)
            }
            if ticket.isBlocked {
                TicketTag(text: String(localized: "Blocked"), tone: AgentTheme.statusError)
            }
            ForEach(labels.prefix(maxLabels), id: \.self) { label in
                // Die Art des Tickets zurückhaltend, alles andere mit Akzent.
                if TicketBoardText.typeLabels.contains(label.lowercased()) {
                    TicketTag(text: label)
                } else {
                    TicketTag(text: label, tone: AgentTheme.accent)
                }
            }
            if labels.count > maxLabels {
                Text(verbatim: "+\(labels.count - maxLabels)")
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

    /// Schmaler wird keine Spalte; darunter scrollt das Board waagrecht.
    static let minColumnWidth: CGFloat = 260
    static let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let count = CGFloat(max(columns.count, 1))
            let width = max(Self.minColumnWidth, (proxy.size.width - Self.spacing * (count - 1)) / count)
            ScrollView(.horizontal, showsIndicators: true) {
                columnStack(width: width)
                    .frame(height: proxy.size.height)
            }
        }
    }

    private func columnStack(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Self.spacing) {
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
                                Text("No tickets for this filter.")
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
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(TicketBoardStyle.column, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// Flächen der Ticket-Ansicht. Im hellen Modus sind Hintergrund und Karten
/// beide weiß; die Spalten brauchen deshalb einen eigenen Ton.
enum TicketBoardStyle {
    static let column = AgentTheme.header
    static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
}
