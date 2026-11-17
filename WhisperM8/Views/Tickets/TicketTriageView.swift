import AppKit
import SwiftUI

/// Triage wie in Linear, aber mit der Liste daneben (WM8-125): links dieselbe
/// Liste schmal mit den Gruppen der Ansicht, in der Mitte das Ticket mit der
/// Eigenschaften-Zeile über dem Titel, rechts (außerhalb) der Board-Chat. Liest
/// nur; was in Linear etwas ändert, sammelt der Board-Chat (WM8-113).
struct TicketTriageView: View {
    @Bindable var model: TicketBoardViewModel
    let triage: TicketTriage
    let load: TicketBoardLoad
    let source: TicketChatStatusSource
    let actions: TicketBoardActions
    /// Projekt des Boards; daran hängt die gezogene Breite der Liste. `nil` in Bildern.
    var projectID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let listWidth = TicketTriageLayout.listWidth(stored: storedListWidth, available: proxy.size.width)
            let layout = TicketTriageLayout(width: proxy.size.width, listWidth: listWidth)
            HStack(spacing: 0) {
                if layout.showsList {
                    TicketTriageList(model: model, triage: triage, source: source,
                                     isNarrow: listWidth < TicketTriageLayout.narrowListBelow)
                        .frame(width: listWidth)
                        .overlay(alignment: .trailing) {
                            TicketTriageListResizer(width: listWidth, available: proxy.size.width,
                                                    setWidth: { setListWidth($0) }, resetWidth: { setListWidth(nil) })
                                .offset(x: 5)
                        }
                        .zIndex(1)
                    Rectangle().fill(AgentTheme.border).frame(width: 1)
                }
                VStack(spacing: 0) {
                    TicketTriageBar(model: model, triage: triage, load: load, actions: actions, compact: layout.compactHead)
                        .controllerTicketMenuAnchor(active: true)
                    if let windowID = model.windowID {
                        // Triage-Knöpfe sammeln für den Board-Chat (WM8-113); nur mit sichtbarem Board-Chat.
                        BoardChatTriageButtons(windowID: windowID, ticketKey: triage.current) { model.nextInTriage() }
                    }
                    if let content = model.detail {
                        // Eigenschaften immer als Zeile über dem Titel (WM8-125); rechts steht der Board-Chat.
                        Rectangle().fill(AgentTheme.border).frame(height: 1)
                        TicketTriagePropertyStrip(content: content, rule: model.presentation.rule, source: source,
                                                  actions: actions, focusedChat: model.focusedChatLine)
                    }
                    Rectangle().fill(AgentTheme.border).frame(height: 1)
                    TicketTriageText(model: model, ticketKey: triage.current)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(AgentTheme.background)
        .clipShape(TicketBoardStyle.shape)
        .overlay { TicketBoardStyle.shape.strokeBorder(AgentTheme.border, lineWidth: 1) }
    }

    private var storedListWidth: Double? {
        projectID.flatMap { BoardChatPreferencesStore.shared.preferences(for: $0).triageListWidth }
    }

    private func setListWidth(_ width: Double?) {
        guard let projectID else { return }
        BoardChatPreferencesStore.shared.setTriageListWidth(width, for: projectID)
    }
}

/// Was die Triage bei welcher Breite zeigt (WM8-124, WM8-125). Pur, damit die
/// Grenzen getestet sind. Die Liste links ist ziehbar; ihr bleibt das Ticket
/// mit mindestens 400 pt. Ist die Triage dafür zu schmal, fällt die Liste weg
/// (J/K blättert weiter).
struct TicketTriageLayout: Equatable {
    /// Breite der Liste ab Werk und ihre Grenzen beim Ziehen.
    static let defaultListWidth: Double = 320
    static let minListWidth: Double = 220
    static let maxListWidth: Double = 480
    /// Darunter fallen in der Liste Nummer und Chat-Name weg; Titel und Punkt bleiben.
    static let narrowListBelow: Double = 270
    /// So viel Platz behält das Ticket mindestens.
    static let ticketMinWidth: Double = 400
    /// Darunter (Breite der Ticket-Spalte) wird der Kopf knapp: „← Chats“ ohne
    /// Namen, „Link kopieren“ und „In Linear öffnen“ nur als Symbol (WM8-124).
    static let fullHeadFrom: CGFloat = 800

    var showsList: Bool
    var compactHead: Bool

    init(showsList: Bool, compactHead: Bool = false) {
        self.showsList = showsList
        self.compactHead = compactHead
    }

    init(width: CGFloat, listWidth: Double) {
        showsList = Double(width) - listWidth >= Self.ticketMinWidth
        let ticketColumn = Double(width) - (showsList ? listWidth + 1 : 0)
        compactHead = ticketColumn < Double(Self.fullHeadFrom)
    }

    /// Gezogene Breite, sonst die Vorgabe; immer in den Grenzen. Bei wenig
    /// Platz gibt die Liste bis zu ihrer Mindestbreite nach, bevor sie wegfällt.
    static func listWidth(stored: Double?, available: CGFloat) -> Double {
        let wanted = min(max(stored ?? defaultListWidth, minListWidth), maxListWidth)
        let room = Double(available) - ticketMinWidth
        return max(minListWidth, min(wanted, room)).rounded()
    }

    /// Neue Breite nach dem Ziehen am rechten Rand der Liste.
    static func draggedListWidth(from start: Double, translation: Double, available: CGFloat) -> Double {
        let room = Double(available) - ticketMinWidth
        return max(minListWidth, min(start + translation, maxListWidth, max(minListWidth, room))).rounded()
    }
}

// MARK: - Liste links

/// Dieselbe Liste wie im Modus Liste, schmal: Gruppen der Ansicht mit Zahl,
/// aufklappbar, Zeilen mit Priorität, Nummer, Titel und Chat-Punkt; das offene
/// Ticket markiert. Kommt die Triage aus einer Spalte des Boards, steht deren
/// Liste ohne Gruppen da.
private struct TicketTriageList: View {
    let model: TicketBoardViewModel
    let triage: TicketTriage
    let source: TicketChatStatusSource
    let isNarrow: Bool

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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rectangle().fill(AgentTheme.border).frame(height: 1)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if triage.source == .list {
                            ForEach(model.presentation.groups) { group in
                                let collapsed = model.isCollapsed(group.id)
                                TicketListGroupHeader(group: group, isCollapsed: collapsed, isSelected: false, compact: true) {
                                    model.toggleGroup(group.id)
                                }
                                if !collapsed {
                                    ForEach(group.rows) { row in
                                        TicketTriageRow(entry: row.entry, depth: row.depth, isCurrent: row.id == triage.current,
                                                        parentOutside: row.parentKeyOutsideView, isNarrow: isNarrow, source: source,
                                                        windowID: model.windowID) { model.selectInTriage(row.id) }
                                            .id(row.id)
                                    }
                                }
                            }
                        } else {
                            ForEach(triage.keys, id: \.self) { key in
                                if let entry = model.entry(key: key) {
                                    TicketTriageRow(entry: entry, depth: 0, isCurrent: key == triage.current, parentOutside: nil,
                                                    isNarrow: isNarrow, source: source, windowID: model.windowID) { model.selectInTriage(key) }
                                        .id(key)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
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

/// Eine Zeile der schmalen Liste. Unter 270 pt fallen Nummer und Chat-Name weg;
/// Titel und Chat-Punkt bleiben.
private struct TicketTriageRow: View {
    let entry: TicketBoardEntry
    let depth: Int
    let isCurrent: Bool
    let parentOutside: String?
    let isNarrow: Bool
    let source: TicketChatStatusSource
    /// Für die gesammelte Entscheidung an der Zeile (WM8-113).
    let windowID: UUID?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                line(showsKey: !isNarrow, showsChatName: !isNarrow)
                if let windowID { BoardChatTriageMark(windowID: windowID, ticketKey: entry.ticket.key) }
            }
            .padding(.leading, 7 + CGFloat(depth) * 14)
            .padding(.trailing, 7)
            .frame(minHeight: 30)
            .background(isCurrent ? AgentTheme.accent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 1.5).fill(AgentTheme.accent).frame(width: 3).padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TicketBoardText.spoken(entry)))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : [.isButton])
    }

    private func line(showsKey: Bool, showsChatName: Bool) -> some View {
        HStack(spacing: 6) {
            TicketPriorityBars(priority: entry.ticket.priority).frame(width: 12)
            if showsKey {
                Text(verbatim: entry.ticket.key)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                    .fixedSize()
            }
            if let parentOutside {
                Text(verbatim: "↳")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .help(Text("Sub-issue of \(parentOutside), which is not in this view"))
            }
            Text(verbatim: entry.ticket.title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            if let chat = entry.agents.first?.chat {
                HStack(spacing: 4) {
                    TicketChatStatusDot(chatID: chat.id, source: source)
                    if showsChatName {
                        Text(verbatim: chat.shortName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AgentTheme.textSecondary)
                    }
                }
                .fixedSize()
            } else if entry.waitsForMe {
                Text("for you")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentTheme.statusAwaiting)
                    .fixedSize()
            }
        }
        .frame(minHeight: 26)
    }
}

/// Griff am rechten Rand der Liste: immer sichtbar (kein Hover-only). Während
/// des Ziehens zeigt eine Linie die neue Kante; die Breite gilt beim Loslassen.
/// Doppelklick: zurück auf die Vorgabe.
private struct TicketTriageListResizer: View {
    let width: Double
    let available: CGFloat
    let setWidth: (Double) -> Void
    let resetWidth: () -> Void
    @State private var dragStart: Double?
    @State private var translation: Double = 0

    var body: some View {
        let preview = dragStart.map { TicketTriageLayout.draggedListWidth(from: $0, translation: translation, available: available) }
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .overlay {
                BoardChatResizeGrip(isActive: preview != nil)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                if let preview {
                    Rectangle()
                        .fill(AgentTheme.accent)
                        .frame(width: 2)
                        .offset(x: preview - width - 4)
                        .allowsHitTesting(false)
                }
            }
            .background(BoardChatResizeCursor())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = width }
                        translation = value.translation.width
                    }
                    .onEnded { value in
                        let start = dragStart ?? width
                        dragStart = nil
                        translation = 0
                        setWidth(TicketTriageLayout.draggedListWidth(from: start, translation: value.translation.width,
                                                                     available: available))
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { resetWidth() })
            .help(String(localized: "Drag to resize the list. Double-click for the default width."))
            .accessibilityHidden(true)
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
                    if model.mode == .list { Text("List") } else { Text("Board") }
                }
                .fixedSize()
            }
            .help(model.mode == .list ? Text("Back to the list (Esc)") : Text("Back to the board (Esc)"))
            .accessibilityLabel(model.mode == .list ? Text("Back to the list") : Text("Back to the board"))
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

// MARK: - Eigenschaften als Zeile

/// Eine Zeile über dem Titel (Entscheidung Giuliano, 16.11.2026; seit WM8-125
/// immer, rechts steht der Board-Chat): „In Progress · Hoch · Giuliano ·
/// Feature · Tickets · ● Jon [Zum Chat]“. Reicht die Breite nicht, bricht sie um
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
                TicketStatusSymbol(status: ticket.status, meaning: entry.meaning)
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
            if let project = ticket.project {
                part { Text(verbatim: project).foregroundStyle(AgentTheme.textSecondary) }
            }
            if let parent = ticket.parentKey {
                part { Text("Sub-issue of \(parent)").foregroundStyle(AgentTheme.textSecondary) }
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
