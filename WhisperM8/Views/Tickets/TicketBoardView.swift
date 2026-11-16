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
    /// Fertiger Satz, wenn Reiter oder Tickets einer Ansicht nicht kamen (WM8-125).
    var viewProblem: String?

    init(fetchedAt: Date? = nil, isLoading: Bool = false, problem: String? = nil) {
        self.fetchedAt = fetchedAt
        self.isLoading = isLoading
        self.problem = problem
    }

    func reset() {
        fetchedAt = nil
        isLoading = false
        problem = nil
        viewProblem = nil
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
    /// Projekt des Boards, für die Breite der Liste in der Triage (WM8-125).
    var projectID: UUID? = nil

    var body: some View {
        let presentation = model.presentation
        VStack(alignment: .leading, spacing: 10) {
            if let triage = model.triage {
                // Triage nimmt den Platz des Boards ein: Liste, Ticket, Eigenschaften.
                TicketBoardProblemLine(load: load)
                TicketTriageView(model: model, triage: triage, load: load, source: source, actions: actions, projectID: projectID)
            } else {
                // Kopf, darunter die Reiter aus Linear und was die Ansicht tut (WM8-125).
                TicketBoardHeader(title: title, mode: $model.mode, load: load, back: actions.back, refresh: actions.refresh,
                                  model: model) { compact in
                    if model.copied == .link {
                        // ⌘C auf dem Board: Dort gibt es keinen Link-Knopf, der „Kopiert“ zeigen könnte.
                        Label("Link copied", systemImage: "checkmark")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .fixedSize()
                    }
                    TicketCopyButton(kind: .list, copied: model.copied, iconOnly: compact) { model.copyList(title: listTitle) }
                        .ticketHeaderRing(.copyList, model: model)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TicketViewTabsBar(model: model)
                    TicketViewInfoLine(model: model, load: load, openURL: actions.openURL)
                        .padding(.horizontal, 4)
                }
                // Über dem Board: Die Liste unter „Mehr“ hängt darunter.
                .zIndex(1)
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

    /// Überschrift der kopierten Liste: Board und Ansicht.
    private var listTitle: String { model.listTitle(board: title) }

    @ViewBuilder
    private func content(_ presentation: TicketBoardPresentation) -> some View {
        switch model.mode {
        case .board:
            TicketBoardLanesView(lanes: presentation.lanes, rule: presentation.rule, selectedKey: model.selectedKey,
                                 source: source, open: { model.openFromLane($0) }, moreColumn: model.moreColumn)
        case .list:
            TicketListView(model: model, source: source)
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
    /// Für die Ringe der Auswahl per Controller und Tastatur (Paket 3d).
    let model: TicketBoardViewModel
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
                    .ticketHeaderRing(.back, model: model)
            }
            Text(verbatim: title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
            // Liste zuerst: Sie ist der Standard (WM8-125), wie in Linear.
            Picker(selection: $mode) {
                Text("List").tag(TicketBoardViewModel.Mode.list)
                Text("Board").tag(TicketBoardViewModel.Mode.board)
            } label: {
                Text("Board or list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // Je eine Hälfte für Liste und Board (beide Wörter sind etwa gleich lang).
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.ticketHeaderRing(.modeList, model: model, cornerRadius: 6)
                    Color.clear.ticketHeaderRing(.modeBoard, model: model, cornerRadius: 6)
                }
            }

            Spacer(minLength: 8)

            trailing(compact)
            if !compact { TicketBoardSyncLabel(load: load) }
            TicketBoardRefreshButton(load: load, refresh: refresh)
                .ticketHeaderRing(.refresh, model: model)
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
