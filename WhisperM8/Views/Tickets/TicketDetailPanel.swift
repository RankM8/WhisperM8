import SwiftUI

/// Detail zum gewählten Ticket: Eckdaten, der Chat daran, der Text, dazu
/// „Zum Chat“ und „In Linear öffnen“. Stufe 1 ändert nichts.
struct TicketDetailPanel: View {
    let entry: TicketBoardEntry
    /// Beschreibung, schon zerlegt.
    let description: [TicketDescriptionBlock]
    let source: TicketChatStatusSource
    let actions: TicketBoardActions
    let close: () -> Void

    private var ticket: Ticket { entry.ticket }

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
                    TicketCardTags(ticket: ticket, maxLabels: 6)

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
                        if let criteria = ticket.criteria {
                            TicketDetailLine(label: "Done when") { Text("\(criteria.done) of \(criteria.total) done") }
                        }
                    }

                    Rectangle().fill(AgentTheme.border).frame(height: 1)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chat")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AgentTheme.textSecondary)
                        TicketAgentRow(entry: entry, source: source)
                        ForEach(entry.agents.dropFirst(), id: \.link.id) { agent in
                            TicketAgentRow(entry: TicketBoardEntry(ticket: ticket, agents: [agent]), source: source)
                        }
                        let earlier = ticket.links.filter { !$0.isActive }
                        if !earlier.isEmpty {
                            Text("Earlier: \(earlier.map { $0.title.replacingOccurrences(of: "Chat: ", with: "") }.joined(separator: ", "))")
                                .font(.system(size: 11))
                                .foregroundStyle(AgentTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 8) {
                        if let chat = entry.agents.first?.chat {
                            Button("Go to chat") { actions.openChat(chat.id) }
                                .buttonStyle(SettingsButtonStyle.primary)
                        }
                        if let url = ticket.url {
                            Button("Open in Linear") { actions.openURL(url) }
                                .buttonStyle(SettingsButtonStyle.standard)
                        }
                    }

                    if !description.isEmpty {
                        Rectangle().fill(AgentTheme.border).frame(height: 1)
                        TicketDescriptionView(blocks: description)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
