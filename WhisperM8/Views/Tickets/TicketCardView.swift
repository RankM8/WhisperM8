import SwiftUI

/// Eine Karte im Board: Nummer, Titel, Projekt, Priorität, Labels, Person und
/// der Chat, der daran sitzt. Alles ist ohne Mauszeiger sichtbar.
struct TicketCardView: View {
    let entry: TicketBoardEntry
    var rule = TicketTeamRule()
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
                TicketCardTags(ticket: ticket, rule: rule)
                // Die Chat-Zeile nur, wo es einen Chat gibt: Ohne Chat sagt sie nichts.
                if entry.hasAgent || entry.isHandedOver {
                    Rectangle().fill(AgentTheme.border).frame(height: 1)
                    TicketAgentRow(entry: entry, source: source)
                }
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
    /// Labels, die nach der Regel des Teams auf den Nutzer warten, stehen in Bernstein.
    var rule = TicketTeamRule()
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
                // Die Art des Tickets zurückhaltend, „wartet auf dich“ in
                // Bernstein, alles andere mit Akzent.
                if rule.isWaitingLabel(label) {
                    TicketTag(text: label, tone: AgentTheme.statusAwaiting)
                } else if TicketBoardText.typeLabels.contains(label.lowercased()) {
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

/// Spalten des Boards: eine je Status des Teams.
struct TicketBoardLanesView: View {
    let lanes: [TicketBoardLane]
    let rule: TicketTeamRule
    let selectedKey: String?
    let expanded: Set<String>
    let source: TicketChatStatusSource
    let select: (String) -> Void
    let expand: (String) -> Void

    /// Schmaler wird keine Spalte; darunter scrollt das Board waagrecht.
    static let minColumnWidth: CGFloat = 260
    static let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            // Eingeklappte Spalten sind schmal; die gefüllten teilen sich den Rest.
            let folded = CGFloat(lanes.filter(\.isFolded).count)
            let open = CGFloat(max(lanes.count - Int(folded), 1))
            let free = proxy.size.width - Self.spacing * CGFloat(max(lanes.count - 1, 0)) - folded * TicketBoardLanes.foldedWidth
            let width = max(Self.minColumnWidth, free / open)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(lanes) { lane in
                        if lane.isFolded {
                            TicketBoardFoldedLaneView(lane: lane)
                                .frame(width: TicketBoardLanes.foldedWidth)
                        } else {
                            TicketBoardLaneView(lane: lane, rule: rule, selectedKey: selectedKey,
                                                isExpanded: expanded.contains(lane.id), source: source,
                                                select: select, expand: { expand(lane.id) })
                                .frame(width: width)
                        }
                    }
                }
                .frame(height: proxy.size.height)
            }
        }
    }
}

/// Eine Spalte, die ein Filter geleert hat: schmal, nur Statusname und 0.
private struct TicketBoardFoldedLaneView: View {
    let lane: TicketBoardLane

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: lane.status.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentTheme.textSecondary)
                .lineLimit(2)
            Text(verbatim: "0")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(AgentTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TicketBoardStyle.column, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Eine Spalte: Status, Zahl, Hinweis „wartet auf dich“ und die Karten.
private struct TicketBoardLaneView: View {
    let lane: TicketBoardLane
    let rule: TicketTeamRule
    let selectedKey: String?
    let isExpanded: Bool
    let source: TicketChatStatusSource
    let select: (String) -> Void
    let expand: () -> Void

    var body: some View {
        let (shown, hidden) = TicketBoardLanes.shown(lane, expanded: isExpanded)
        let isMine = lane.meaning == .waitsForMe
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: lane.status.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: "\(lane.entries.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                Spacer(minLength: 4)
                if isMine {
                    Text("Waiting for you")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.statusAwaiting)
                } else if lane.waitingCount > 0 {
                    Text("\(lane.waitingCount) for you")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.statusAwaiting)
                }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shown) { entry in
                        TicketCardView(entry: entry, rule: rule, isSelected: selectedKey == entry.ticket.key, source: source) {
                            select(entry.ticket.key)
                        }
                    }
                    if hidden > 0 {
                        Button(action: expand) {
                            Text("\(hidden) more · show all")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(AgentTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if lane.entries.isEmpty {
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
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TicketBoardStyle.column, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isMine {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AgentTheme.statusAwaiting.opacity(0.55), lineWidth: 1)
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
