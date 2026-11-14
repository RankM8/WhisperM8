import SwiftUI

/// Detail zum gewählten Ticket: Eckdaten, der Chat daran, der Text, dazu
/// „Zum Chat“ und „In Linear öffnen“. Stufe 1 ändert nichts.
struct TicketDetailPanel: View {
    /// Fertig abgeleitet; im Body wird nichts gerechnet.
    let content: TicketDetailContent
    let source: TicketChatStatusSource
    let actions: TicketBoardActions
    let close: () -> Void

    private var entry: TicketBoardEntry { content.entry }
    private var ticket: Ticket { content.entry.ticket }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: ticket.key)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                TicketPriorityBars(priority: ticket.priority)
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(Text("Close"))
                .accessibilityLabel(Text("Close"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: ticket.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    TicketCardTags(ticket: ticket, maxLabels: 6, hidesColumnStatus: false)

                    VStack(alignment: .leading, spacing: 6) {
                        TicketDetailLine(label: "Linear project") { Text(verbatim: TicketBoardText.project(ticket.project ?? "")) }
                        if let milestone = ticket.milestone {
                            TicketDetailLine(label: "Milestone") { Text(verbatim: milestone) }
                        }
                        TicketDetailLine(label: "Priority") { Text(verbatim: TicketBoardText.priority(ticket.priority)) }
                        TicketDetailLine(label: "Assignee") {
                            if let assignee = ticket.assignee {
                                Text(verbatim: assignee.name)
                            } else {
                                Text("Nobody")
                            }
                        }
                        if let criteria = entry.criteria {
                            TicketDetailLine(label: "Done when") { Text("\(criteria.done) of \(criteria.total) done") }
                        }
                    }

                    Rectangle().fill(AgentTheme.border).frame(height: 1)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chat")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AgentTheme.textSecondary)
                        if entry.agents.isEmpty {
                            TicketAgentRow(entry: entry, source: source)
                        }
                        ForEach(content.agents) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                TicketAgentRow(entry: line.entry, source: source)
                                if let since = line.since {
                                    Text("since \(TicketBoardText.since(since))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AgentTheme.textSecondary)
                                }
                            }
                        }
                        if !entry.agents.isEmpty, !entry.handedOverBy.isEmpty {
                            Text("Earlier: \(entry.handedOverBy.joined(separator: ", "))")
                                .font(.system(size: 11))
                                .foregroundStyle(AgentTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 8) {
                        if let chatID = content.localChatID {
                            Button("Go to chat") { actions.openChat(chatID) }
                                .buttonStyle(SettingsButtonStyle.primary)
                        }
                        if let url = content.url {
                            Button("Open in Linear") { actions.openURL(url) }
                                .buttonStyle(SettingsButtonStyle.standard)
                        }
                    }

                    if !content.description.isEmpty {
                        Rectangle().fill(AgentTheme.border).frame(height: 1)
                        TicketDescriptionView(blocks: content.description)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Ein anderes Ticket beginnt oben, nicht an der alten Stelle.
            .id(entry.id)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AgentTheme.surface, in: TicketBoardStyle.shape)
        .overlay { TicketBoardStyle.shape.strokeBorder(AgentTheme.borderStrong, lineWidth: 1) }
    }
}

private struct TicketDetailLine<Value: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textSecondary)
                .frame(width: 96, alignment: .leading)
            value
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
