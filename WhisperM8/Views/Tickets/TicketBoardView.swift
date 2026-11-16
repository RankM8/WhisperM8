import SwiftUI

/// Was die Ansicht nach außen auslöst. Stufe 1 liest nur: Es gibt keinen
/// Knopf, der ein Ticket ändert.
struct TicketBoardActions {
    var refresh: () -> Void
    var openChat: (UUID) -> Void
    /// Adresse des Tickets im Ticket-Werkzeug; nur `https`.
    var openURL: (URL) -> Void
    /// Zur Seite „Tickets“ der Einstellungen.
    var openSettings: () -> Void = {}
    /// „← Chats · …“ links im Kopf (WM8-124); `nil` in Bildern ohne Fenster.
    var back: TicketsBackLinkModel? = nil

    static let none = TicketBoardActions(refresh: {}, openChat: { _ in }, openURL: { _ in })
}

/// Stand des letzten Abrufs. Nur die Zeile im Kopf und die Störungs-Zeile
/// lesen hier: Ein Abruf, der im Takt beginnt und endet, wertet
/// deshalb weder Board noch Karten neu aus.
@MainActor
@Observable
final class TicketBoardLoad {
    var fetchedAt: Date?
    var isLoading = false
    /// Fertig übersetzter Satz, wenn der letzte Abruf scheiterte. Der letzte
    /// Stand bleibt stehen.
    var problem: String?

    init(fetchedAt: Date? = nil, isLoading: Bool = false, problem: String? = nil) {
        self.fetchedAt = fetchedAt
        self.isLoading = isLoading
        self.problem = problem
    }

    func reset() {
        fetchedAt = nil
        isLoading = false
        problem = nil
    }
}

/// Die Ticket-Ansicht eines Projekts: Kopf mit Umschalter Board/Backlog,
/// Filter, Spalten oder Liste, Detail rechts und die Leiste der Chats ohne
/// Ticket. Zeichnet nur fertige Werte; gerechnet wird im `TicketBoardViewModel`.
struct TicketBoardView: View {
    let title: String
    @Bindable var model: TicketBoardViewModel
    let load: TicketBoardLoad
    let source: TicketChatStatusSource
    let actions: TicketBoardActions

    var body: some View {
        let presentation = model.presentation
        VStack(alignment: .leading, spacing: 10) {
            if let triage = model.triage {
                // Triage nimmt den Platz des Boards ein: Liste, Ticket, Eigenschaften.
                TicketBoardProblemLine(load: load)
                TicketTriageView(model: model, triage: triage, load: load, source: source, actions: actions)
            } else {
                // „Liste kopieren“ steht im Kopf: Die Filterzeile braucht die ganze
                // Breite, sobald rechts der Board-Chat steht (WM8-113).
                TicketBoardHeader(title: title, mode: $model.mode, load: load, back: actions.back, refresh: actions.refresh) { compact in
                    if model.copied == .link {
                        // ⌘C auf dem Board: Dort gibt es keinen Link-Knopf, der „Kopiert“ zeigen könnte.
                        Label("Link copied", systemImage: "checkmark")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .fixedSize()
                    }
                    TicketCopyButton(kind: .list, copied: model.copied, iconOnly: compact) { model.copyList(title: listTitle) }
                }
                TicketBoardFilterBar(filter: $model.filter, counts: presentation.counts, projects: presentation.projects)
                TicketBoardProblemLine(load: load)
                content(presentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                TicketLooseChatsBar(chats: presentation.looseChats, supervisors: presentation.supervisors, source: source,
                                    openChat: actions.openChat)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AgentTheme.background)
    }

    /// Überschrift der kopierten Liste: Board, Ansicht und Filter.
    private var listTitle: String {
        model.filter.waitingForMe ? title + " · " + String(localized: "Waiting for me") : title
    }

    @ViewBuilder
    private func content(_ presentation: TicketBoardPresentation) -> some View {
        switch model.mode {
        case .board:
            TicketBoardLanesView(lanes: presentation.lanes, rule: presentation.rule, selectedKey: model.selectedKey,
                                 source: source, open: { model.openFromLane($0) }, moreColumn: model.moreColumn)
        case .list:
            TicketBacklogListView(groups: presentation.groups, selectedKey: model.selectedKey, source: source) {
                model.openFromList($0)
            }
        }
    }
}

// MARK: - Kopieren

/// „Link kopieren“ oder „Liste kopieren“, mit kurzer Rückmeldung „Kopiert“.
struct TicketCopyButton: View {
    let kind: TicketCopyFeedback
    let copied: TicketCopyFeedback?
    /// Enger Kopf der Triage (WM8-124): nur das Symbol, der Text steht in Hilfe und Bedienungshilfen.
    var iconOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: copied == kind ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                if !iconOnly { label }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(SettingsButtonStyle.standard)
        .fixedSize()
        .help(help)
        .accessibilityLabel(labelText)
    }

    private var label: some View { labelText }

    private var labelText: Text {
        if copied == kind { return Text("Copied") }
        switch kind {
        case .link: return Text("Copy link")
        case .list: return Text("Copy list")
        }
    }

    private var help: Text {
        switch kind {
        case .link: return Text("Copy key, title and address of the ticket (⌘C)")
        case .list: return Text("Copy the tickets shown, with their addresses")
        }
    }
}

// MARK: - Kopf

private struct TicketBoardHeader<Trailing: View>: View {
    let title: String
    @Binding var mode: TicketBoardViewModel.Mode
    let load: TicketBoardLoad
    let back: TicketsBackLinkModel?
    let refresh: () -> Void
    /// `true`: knapper Kopf, Knöpfe nur als Symbol.
    @ViewBuilder let trailing: (_ compact: Bool) -> Trailing

    /// Passt der volle Kopf nicht (Board-Chat weit gezogen, Board bei seiner
    /// Mindestbreite), nimmt er die knappe Form: „← Chats“ ohne Namen,
    /// „Liste kopieren“ als Symbol, ohne Uhrzeit. Sonst würde der Kopf breiter
    /// als das Board und schöbe die Spalte daneben aus dem Fenster (WM8-124).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            if let back {
                TicketsBackLinkButton(link: back, compact: compact)
            }
            Text(verbatim: title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
            Picker(selection: $mode) {
                Text("Board").tag(TicketBoardViewModel.Mode.board)
                Text("List").tag(TicketBoardViewModel.Mode.list)
            } label: {
                Text("Board or list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            trailing(compact)
            if !compact { TicketBoardSyncLabel(load: load) }
            TicketBoardRefreshButton(load: load, refresh: refresh)
        }
    }
}

private struct TicketBoardRefreshButton: View {
    let load: TicketBoardLoad
    let refresh: () -> Void

    var body: some View {
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

/// „Aktualisiert 05:41“: eine feste Uhrzeit, kein Zähler, der mitläuft.
private struct TicketBoardSyncLabel: View {
    let load: TicketBoardLoad

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
    let load: TicketBoardLoad

    var body: some View {
        if let problem = load.problem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                if let fetchedAt = load.fetchedAt {
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
}

// MARK: - Filter

/// Zwei Gruppen, die sich kombinieren lassen (Agent, Person), dazu das Projekt.
/// Jede Zahl gilt innerhalb der übrigen Auswahl.
private struct TicketBoardFilterBar: View {
    @Binding var filter: TicketBoardFilter
    let counts: TicketFilterCounts
    let projects: [String]

    var body: some View {
        let names = TicketBoardText.chipNames(counts.people.map(\.person))
        // Waagrecht scrollbar, mit sichtbarem Balken: Mit Board-Chat passt die
        // Zeile oft nicht ganz, und jeder Filter muss erreichbar bleiben.
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 6) {
                // Die Auswahl des Projekts zuerst: Sie bleibt sichtbar, auch
                // wenn viele Personen die Zeile füllen.
                // Zuerst, was auf den Nutzer wartet: die Frage, mit der er das Board öffnet.
                TicketFilterChip(isOn: filter.waitingForMe, count: counts.waitingForMe,
                                 tone: AgentTheme.statusAwaiting, tint: AgentTheme.statusAwaiting.opacity(0.14)) {
                    filter.waitingForMe.toggle()
                } label: {
                    Text("Waiting for me")
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

                Rectangle().fill(AgentTheme.border).frame(width: 1, height: 16).padding(.horizontal, 4)

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
                        Text(verbatim: names[entry.person.id] ?? entry.person.name)
                    }
                }
            }
            // Platz für den Balken, damit er keine Filter verdeckt.
            .padding(.bottom, 8)
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
    /// Farbe des Rahmens; Bernstein für „wartet auf mich“.
    var tone: Color = AgentTheme.accent
    var tint: Color = AgentTheme.accentTint
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
            .background(isOn ? tint : AgentTheme.control, in: Capsule())
            .overlay { Capsule().strokeBorder(isOn ? tone : AgentTheme.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
