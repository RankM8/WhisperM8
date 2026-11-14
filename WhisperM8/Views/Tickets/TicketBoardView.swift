import SwiftUI

/// Was die Ansicht nach außen auslöst. Stufe 1 liest nur: Es gibt keinen
/// Knopf, der ein Ticket ändert.
struct TicketBoardActions {
    var refresh: () -> Void
    var openChat: (UUID) -> Void
    var openURL: (String) -> Void

    static let none = TicketBoardActions(refresh: {}, openChat: { _ in }, openURL: { _ in })
}

/// Stand des letzten Abrufs, für die Zeile im Kopf.
struct TicketBoardLoadState: Equatable {
    var fetchedAt: Date?
    var isLoading = false
    /// Fertig übersetzter Satz, wenn der letzte Abruf scheiterte. Der letzte
    /// Stand bleibt stehen.
    var problem: String?
}

/// Die Ticket-Ansicht eines Projekts: Kopf mit Umschalter Board/Backlog,
/// Filter, Spalten oder Liste, Detail rechts und die Leiste der Chats ohne
/// Ticket. Zeichnet nur fertige Werte; gerechnet wird im `TicketBoardViewModel`.
struct TicketBoardView: View {
    let title: String
    @Bindable var model: TicketBoardViewModel
    let load: TicketBoardLoadState
    let source: TicketChatStatusSource
    let actions: TicketBoardActions

    var body: some View {
        let presentation = model.presentation
        VStack(alignment: .leading, spacing: 10) {
            TicketBoardHeader(title: title, mode: $model.mode, load: load, refresh: actions.refresh)
            TicketBoardFilterBar(filter: $model.filter, counts: presentation.counts, projects: presentation.projects)
            if let problem = load.problem {
                TicketBoardProblemLine(problem: problem, fetchedAt: load.fetchedAt)
            }
            HStack(alignment: .top, spacing: 12) {
                Group {
                    switch model.mode {
                    case .board:
                        TicketBoardColumnsView(columns: presentation.columns, selectedKey: model.selectedKey, source: source) {
                            model.toggle($0)
                        }
                    case .backlog:
                        TicketBacklogListView(groups: presentation.groups, selectedKey: model.selectedKey, source: source) {
                            model.toggle($0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if let selected = model.selected {
                    TicketDetailPanel(entry: selected, description: model.selectedDescription, source: source, actions: actions) {
                        model.selectedKey = nil
                    }
                    .frame(width: 340)
                }
            }
            TicketLooseChatsBar(chats: presentation.looseChats, source: source, openChat: actions.openChat)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentTheme.background)
    }
}

// MARK: - Kopf

private struct TicketBoardHeader: View {
    let title: String
    @Binding var mode: TicketBoardViewModel.Mode
    let load: TicketBoardLoadState
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
            Picker(selection: $mode) {
                Text("Board").tag(TicketBoardViewModel.Mode.board)
                Text("Backlog").tag(TicketBoardViewModel.Mode.backlog)
            } label: {
                Text("Board or backlog")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            TicketBoardSyncLabel(load: load)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AgentTheme.textSecondary)
            .disabled(load.isLoading)
            .help(Text("Refresh"))
            .accessibilityLabel(Text("Refresh"))
        }
    }
}

/// „Aktualisiert 05:41“: eine feste Uhrzeit, kein Zähler, der mitläuft.
private struct TicketBoardSyncLabel: View {
    let load: TicketBoardLoadState

    var body: some View {
        Group {
            if load.isLoading, load.fetchedAt == nil {
                Text("Loading…")
            } else if let fetchedAt = load.fetchedAt {
                Text("Updated \(TicketBoardText.time(fetchedAt))")
            } else {
                Text("Not loaded yet")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(AgentTheme.textSecondary)
    }
}

private struct TicketBoardProblemLine: View {
    let problem: String
    let fetchedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
            if let fetchedAt {
                Text("\(problem) Showing the state from \(TicketBoardText.time(fetchedAt)).")
            } else {
                Text(verbatim: problem)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(AgentTheme.statusAwaiting)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.statusAwaiting.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Filter

/// Zwei Gruppen, die sich kombinieren lassen (Agent, Person), dazu das Projekt.
/// Jede Zahl gilt innerhalb der übrigen Auswahl.
private struct TicketBoardFilterBar: View {
    @Binding var filter: TicketBoardFilter
    let counts: TicketFilterCounts
    let projects: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TicketFilterGroupLabel(text: "Agent")
                TicketFilterChip(isOn: filter.agent == .all, count: counts.all) { filter.agent = .all } label: { Text("All") }
                TicketFilterChip(isOn: filter.agent == .withAgent, count: counts.withAgent) { filter.agent = .withAgent } label: {
                    Text("With agent")
                }
                TicketFilterChip(isOn: filter.agent == .withoutAgent, count: counts.withoutAgent) { filter.agent = .withoutAgent } label: {
                    Text("Without agent")
                }

                Rectangle().fill(AgentTheme.border).frame(width: 1, height: 16).padding(.horizontal, 4)

                TicketFilterGroupLabel(text: "Person")
                TicketFilterChip(isOn: filter.person == .all, count: nil) { filter.person = .all } label: { Text("All") }
                TicketFilterChip(isOn: filter.person == .unassigned, count: counts.unassigned) { filter.person = .unassigned } label: {
                    Text("Unassigned")
                }
                ForEach(counts.people, id: \.person.id) { entry in
                    TicketFilterChip(isOn: filter.person == .person(id: entry.person.id), count: entry.count) {
                        filter.person = .person(id: entry.person.id)
                    } label: {
                        Text(verbatim: entry.person.name.components(separatedBy: " ").first ?? entry.person.name)
                    }
                }

                Rectangle().fill(AgentTheme.border).frame(width: 1, height: 16).padding(.horizontal, 4)

                Picker(selection: $filter.project) {
                    Text("All projects").tag(String?.none)
                    ForEach(projects, id: \.self) { project in
                        Text(verbatim: TicketBoardText.project(project)).tag(String?.some(project))
                    }
                } label: {
                    Text("Linear project")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }
}

private struct TicketFilterGroupLabel: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AgentTheme.textSecondary)
    }
}

private struct TicketFilterChip<Label: View>: View {
    let isOn: Bool
    let count: Int?
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                label
                    .font(.system(size: 12, weight: .medium))
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(AgentTheme.textSecondary)
                }
            }
            .foregroundStyle(AgentTheme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isOn ? AgentTheme.accentTint : AgentTheme.control, in: Capsule())
            .overlay { Capsule().strokeBorder(isOn ? AgentTheme.accent : AgentTheme.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
