import AppKit
import SwiftUI

/// Triage wie in Linear: links die Liste, aus der das Ticket kommt, in der
/// Mitte das Ticket mit Beschreibung und Verlauf, rechts die Eigenschaften,
/// oben die Knöpfe. Liest nur; was in Linear etwas ändert, kommt mit dem
/// Board-Chat (WM8-113).
struct TicketTriageView: View {
    @Bindable var model: TicketBoardViewModel
    let triage: TicketTriage
    let load: TicketBoardLoad
    let source: TicketChatStatusSource
    let actions: TicketBoardActions

    static let listWidth: CGFloat = 260
    static let propertiesWidth: CGFloat = 210

    var body: some View {
        GeometryReader { proxy in
            let layout = TicketTriageLayout(width: proxy.size.width)
            HStack(spacing: 0) {
                if layout.showsList {
                    TicketTriageList(model: model, triage: triage, source: source)
                        .frame(width: Self.listWidth)
                    Rectangle().fill(AgentTheme.border).frame(width: 1)
                }
                VStack(spacing: 0) {
                    TicketTriageBar(model: model, triage: triage, load: load, actions: actions, compact: layout.compactHead)
                        .controllerTicketMenuAnchor(active: true)
                    if let windowID = model.windowID {
                        // Triage-Knöpfe sammeln für den Board-Chat (WM8-113); nur mit sichtbarem Board-Chat.
                        BoardChatTriageButtons(windowID: windowID, ticketKey: triage.current) { model.nextInTriage() }
                    }
                    if layout.propertiesInline, let content = model.detail {
                        // Wenig Platz (WM8-124): Eigenschaften als Zeile im Kopf des Tickets statt als Spalte.
                        Rectangle().fill(AgentTheme.border).frame(height: 1)
                        TicketTriagePropertyStrip(content: content, rule: model.presentation.rule, source: source,
                                                  actions: actions, focusedChat: model.focusedChatLine)
                    }
                    Rectangle().fill(AgentTheme.border).frame(height: 1)
                    HStack(spacing: 0) {
                        TicketTriageText(model: model, ticketKey: triage.current)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !layout.propertiesInline, let content = model.detail {
                            Rectangle().fill(AgentTheme.border).frame(width: 1)
                            TicketTriageProperties(content: content, rule: model.presentation.rule, source: source, actions: actions,
                                                   focusedChat: model.focusedChatLine)
                                .frame(width: Self.propertiesWidth)
                        }
                    }
                }
            }
        }
        .background(AgentTheme.background)
        .clipShape(TicketBoardStyle.shape)
        .overlay { TicketBoardStyle.shape.strokeBorder(AgentTheme.border, lineWidth: 1) }
    }
}

/// Was die Triage bei welcher Breite zeigt (WM8-124). Pur, damit die Grenzen
/// getestet sind: Wird es eng, rücken zuerst die Eigenschaften als Zeile in
/// den Kopf des Tickets; erst danach fällt die Liste links weg. So bleiben
/// Liste und Ticket lesbar, auch mit breitem Board-Chat daneben.
struct TicketTriageLayout: Equatable {
    /// Ab hier steht die Eigenschaften-Spalte: Liste, Ticket mit mindestens
    /// rund 490 pt Text und die Spalte haben Platz.
    static let propertiesColumnFrom: CGFloat = 960
    /// Ab hier steht die Liste links (mit den Eigenschaften als Zeile bleiben
    /// dem Ticket mindestens 400 pt).
    static let listFrom: CGFloat = 660

    /// Darunter (Breite der Ticket-Spalte) wird der Kopf knapp: „← Chats“ ohne
    /// Namen, „Link kopieren“ und „In Linear öffnen“ nur als Symbol (WM8-124).
    static let fullHeadFrom: CGFloat = 800

    var showsList: Bool
    var propertiesInline: Bool
    var compactHead: Bool

    init(showsList: Bool, propertiesInline: Bool, compactHead: Bool = false) {
        self.showsList = showsList
        self.propertiesInline = propertiesInline
        self.compactHead = compactHead
    }

    init(width: CGFloat) {
        showsList = width >= Self.listFrom
        propertiesInline = width < Self.propertiesColumnFrom
        let ticketColumn = width - (showsList ? TicketTriageView.listWidth + 1 : 0)
        compactHead = ticketColumn < Self.fullHeadFrom
    }
}

// MARK: - Liste links

private struct TicketTriageList: View {
    let model: TicketBoardViewModel
    let triage: TicketTriage
    let source: TicketChatStatusSource

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: triage.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: "\(triage.keys.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                Spacer(minLength: 4)
                Button { model.copyList(title: triage.title) } label: {
                    Image(systemName: model.copied == .list ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Copy the tickets shown, with their addresses"))
                .accessibilityLabel(Text("Copy list"))
                Button { model.closeTriage() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Back to the board (Esc)"))
                .accessibilityLabel(Text("Back to the board"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(triage.keys, id: \.self) { key in
                            if let entry = model.presentation.entry(key: key) {
                                TicketTriageRow(entry: entry, isCurrent: key == triage.current, source: source,
                                                windowID: model.windowID) {
                                    model.selectInTriage(key)
                                }
                                .id(key)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onAppear { reader.scrollTo(triage.current, anchor: .center) }
                .onChange(of: triage.current) { _, key in
                    // Nur so weit, dass das Ticket sichtbar ist; kein Springen bei jedem Schritt.
                    reader.scrollTo(key)
                }
            }
        }
        .background(AgentTheme.sidebar)
    }
}

private struct TicketTriageRow: View {
    let entry: TicketBoardEntry
    let isCurrent: Bool
    let source: TicketChatStatusSource
    /// Für die gesammelte Entscheidung an der Zeile (WM8-113).
    let windowID: UUID?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.ticket.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let person = entry.ticket.assignee {
                        Text(verbatim: person.name.components(separatedBy: " ").first ?? person.name)
                    } else {
                        Text("Nobody")
                    }
                    if let chat = entry.agents.first?.chat {
                        TicketChatStatusDot(chatID: chat.id, source: source)
                        Text(verbatim: chat.shortName)
                    }
                    if entry.waitsForMe {
                        Text("for you").foregroundStyle(AgentTheme.statusAwaiting)
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: entry.ticket.key).monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textSecondary)
                .lineLimit(1)
                if let windowID { BoardChatTriageMark(windowID: windowID, ticketKey: entry.ticket.key) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isCurrent ? AgentTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TicketBoardText.spoken(entry)))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Knöpfe oben

private struct TicketTriageBar: View {
    let model: TicketBoardViewModel
    let triage: TicketTriage
    let load: TicketBoardLoad
    let actions: TicketBoardActions
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if let back = actions.back {
                // Rückweg zu den Chats (WM8-124), immer ganz zu sehen.
                TicketsBackLinkButton(link: back, compact: compact)
                    .ticketHeaderRing(.back, model: model)
                Rectangle().fill(AgentTheme.border).frame(width: 1, height: 16)
            }
            // Immer sichtbar: Im schmalen Fenster fällt die Liste samt ihrem
            // Schließen-Knopf weg, und Esc wirkt nicht, solange ein Textfeld den Fokus hat.
            Button { model.closeTriage() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Board")
                }
                .fixedSize()
            }
            .help(Text("Back to the board (Esc)"))
            .accessibilityLabel(Text("Back to the board"))
            .ticketHeaderRing(.closeTriage, model: model)
            Rectangle().fill(AgentTheme.border).frame(width: 1, height: 16)
            Button { model.previousInTriage() } label: { Image(systemName: "chevron.up") }
                .disabled(!triage.hasPrevious)
                .help(Text("Previous ticket (K or ↑)"))
                .accessibilityLabel(Text("Previous ticket"))
            Button { model.nextInTriage() } label: { Image(systemName: "chevron.down") }
                .disabled(!triage.hasNext)
                .help(Text("Next ticket (J or ↓)"))
                .accessibilityLabel(Text("Next ticket"))
            Text("\(triage.index + 1) of \(triage.keys.count)")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize()
            if let content = model.detail {
                Text(verbatim: content.entry.ticket.key)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                    .fixedSize()
                    .padding(.leading, 6)
                TicketPriorityBars(priority: content.entry.ticket.priority)
            }
            // Die Tasten (J/K, ⌘C, Esc) stehen in der Leiste unten (WM8-124),
            // nicht mehr abgeschnitten hier.
            Spacer(minLength: 8)
            if model.detail != nil {
                TicketCopyButton(kind: .link, copied: model.copied, iconOnly: compact) { model.copyLink() }
                    .ticketHeaderRing(.copyLink, model: model)
            }
            if model.detail != nil, let windowID = model.windowID {
                BoardChatHandOffButton(windowID: windowID)
                    .ticketHeaderRing(.handOff, model: model)
            }
            if let content = model.detail {
                if let url = content.url {
                    Button { actions.openURL(url) } label: {
                        if compact {
                            Image(systemName: "arrow.up.right.square")
                        } else {
                            Text("Open in Linear")
                        }
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .fixedSize()
                    .help(Text("Open in Linear"))
                    .accessibilityLabel(Text("Open in Linear"))
                    .ticketHeaderRing(.openInLinear, model: model)
                }
            }
            Button { actions.refresh(); model.reloadComments() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 18)
            }
            .disabled(load.isLoading)
            .help(Text("Refresh"))
            .accessibilityLabel(Text("Refresh"))
            .ticketHeaderRing(.refresh, model: model)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(AgentTheme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Text in der Mitte

private struct TicketTriageText: View {
    let model: TicketBoardViewModel
    let ticketKey: String

    /// Die Textansicht steht immer: Ein Wechsel zu einer anderen Ansicht baute
    /// NSTextView und Scroll-Ansicht bei jedem J/K neu auf (und schlösse ⌘F).
    /// Beim Ticketwechsel liegt sofort ein Titel-Dokument bereit; nur der Text
    /// dieses Tickets wird gezeigt, nie der vorige unter der neuen Nummer.
    var body: some View {
        let document = model.document(for: ticketKey)
        TicketTextView(document: document?.text ?? Self.empty, revision: document?.revision ?? -1,
                       ticketKey: document?.ticketKey ?? ticketKey)
    }

    private static let empty = NSAttributedString()
}

// MARK: - Eigenschaften rechts

private struct TicketTriageProperties: View {
    let content: TicketDetailContent
    let rule: TicketTeamRule
    let source: TicketChatStatusSource
    let actions: TicketBoardActions
    /// Controller (WM8-91): fokussierte Zeile unter „Chats am Ticket“.
    var focusedChat: Int? = nil

    private var entry: TicketBoardEntry { content.entry }
    private var ticket: Ticket { entry.ticket }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TicketProperty("Status") {
                    HStack(spacing: 6) {
                        Text(verbatim: ticket.status.name)
                        if entry.waitsForMe {
                            Text("waits for you").foregroundStyle(AgentTheme.statusAwaiting)
                        }
                    }
                }
                TicketProperty("Priority") {
                    HStack(spacing: 6) {
                        TicketPriorityBars(priority: ticket.priority)
                        Text(verbatim: TicketBoardText.priority(ticket.priority))
                    }
                }
                TicketProperty("Assignee") {
                    if let assignee = ticket.assignee { Text(verbatim: assignee.name) } else { Text("Nobody") }
                }
                TicketProperty("Linear project") { Text(verbatim: TicketBoardText.project(ticket.project ?? "")) }
                if let milestone = ticket.milestone {
                    TicketProperty("Milestone") { Text(verbatim: milestone) }
                }
                if let criteria = entry.criteria {
                    TicketProperty("Done when") {
                        HStack(spacing: 6) {
                            TicketCriteriaBadge(progress: criteria)
                            Text("\(criteria.done) of \(criteria.total) done")
                        }
                    }
                }
                if !ticket.labels.isEmpty || ticket.isBlocked {
                    TicketProperty("Labels") {
                        TicketCardTags(ticket: ticket, rule: rule, maxLabels: 8, hidesColumnStatus: true)
                    }
                }
                TicketProperty("Chats on this ticket") {
                    VStack(alignment: .leading, spacing: 6) {
                        if content.agents.isEmpty, !entry.isHandedOver {
                            Text("No chat").foregroundStyle(AgentTheme.textSecondary)
                        }
                        ForEach(Array(content.agents.enumerated()), id: \.element.id) { index, line in
                            VStack(alignment: .leading, spacing: 2) {
                                TicketAgentRow(entry: line.entry, source: source)
                                if let since = line.since {
                                    Text("since \(TicketBoardText.since(since))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AgentTheme.textSecondary)
                                }
                            }
                            .ticketChatLineFocus(focusedChat == index)
                        }
                        if entry.isHandedOver {
                            // Wie auf der Karte: abgegeben heißt, es wartet auf den nächsten Schritt (Merge).
                            Text("Handed over by \(entry.handedOverBy.joined(separator: ", "))")
                                .font(.system(size: 11))
                                .foregroundStyle(AgentTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !entry.handedOverBy.isEmpty {
                            Text("Earlier: \(entry.handedOverBy.joined(separator: ", "))")
                                .font(.system(size: 11))
                                .foregroundStyle(AgentTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let chatID = content.localChatID {
                            Button("Go to chat") { actions.openChat(chatID) }
                                .buttonStyle(SettingsButtonStyle.standard)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AgentTheme.surface)
    }
}

// MARK: - Eigenschaften als Zeile (wenig Platz)

/// Eine Zeile über dem Titel, wenn die Spalte „Eigenschaften“ keinen Platz hat
/// (Entscheidung Giuliano, 16.11.2026): „In Progress · Hoch · Giuliano ·
/// Feature · ● Jon [Zum Chat]“. Reicht die Breite nicht, bricht sie um
/// (Fließ-Anordnung); abgeschnitten wird nichts, auch nicht „Zum Chat“ oder
/// die Markierung des Controllers auf einer Chat-Zeile.
private struct TicketTriagePropertyStrip: View {
    let content: TicketDetailContent
    let rule: TicketTeamRule
    let source: TicketChatStatusSource
    let actions: TicketBoardActions
    var focusedChat: Int? = nil

    private var entry: TicketBoardEntry { content.entry }
    private var ticket: Ticket { entry.ticket }

    var body: some View {
        StatisticsFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            part(first: true) {
                Text(verbatim: ticket.status.name)
                if entry.waitsForMe {
                    Text("waits for you").foregroundStyle(AgentTheme.statusAwaiting)
                }
            }
            part {
                TicketPriorityBars(priority: ticket.priority)
                Text(verbatim: TicketBoardText.priority(ticket.priority))
            }
            part {
                if let assignee = ticket.assignee { Text(verbatim: assignee.name) } else { Text("Nobody") }
            }
            if let criteria = entry.criteria {
                part { TicketCriteriaBadge(progress: criteria) }
                    .help(Text("\(criteria.done) of \(criteria.total) done"))
            }
            if !ticket.labels.isEmpty || ticket.isBlocked {
                part { TicketCardTags(ticket: ticket, rule: rule, maxLabels: 8, hidesColumnStatus: true) }
            }
            ForEach(Array(content.agents.enumerated()), id: \.element.id) { index, line in
                part {
                    TicketAgentRow(entry: line.entry, source: source, compact: true)
                        .ticketChatLineFocus(focusedChat == index)
                }
            }
            if let chatID = content.localChatID {
                Button("Go to chat") { actions.openChat(chatID) }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .fixedSize()
            }
            if entry.isHandedOver {
                // Wie auf der Karte: abgegeben heißt, es wartet auf den nächsten Schritt (Merge).
                part { Text("Handed over by \(entry.handedOverBy.joined(separator: ", "))").foregroundStyle(AgentTheme.textSecondary) }
            } else if !entry.handedOverBy.isEmpty {
                part { Text("Earlier: \(entry.handedOverBy.joined(separator: ", "))").foregroundStyle(AgentTheme.textSecondary) }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(AgentTheme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.surface)
    }

    /// Ein Teil der Zeile, mit „·“ davor (außer dem ersten). Teile brechen nur
    /// als Ganzes um.
    private func part<Value: View>(first: Bool = false, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 5) {
            if !first {
                Text(verbatim: "·").foregroundStyle(AgentTheme.textTertiary)
            }
            value()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct TicketProperty<Value: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let value: Value

    init(_ label: LocalizedStringKey, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textSecondary)
            value
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }
}
