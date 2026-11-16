import SwiftUI

// MARK: - Liste nach der Ansicht aus Linear (WM8-125)

/// Was eine Zeile bei welcher Breite der Liste zeigt. Wird es eng, fällt
/// zuerst das Datum weg, dann das Projekt, dann rücken die Labels zusammen und
/// die Person geht; Titel und Chat bleiben immer (Entscheidung Giuliano,
/// 16.11.2026). Pur, damit die Grenzen getestet sind.
struct TicketListRowLayout: Equatable {
    static let dateFrom: CGFloat = 900
    static let projectFrom: CGFloat = 780
    static let allLabelsFrom: CGFloat = 660
    static let personFrom: CGFloat = 560
    /// So viele Labels stehen höchstens in der Zeile, der Rest als „+N“.
    static let maxLabels = 3

    var showsDate: Bool
    var showsProject: Bool
    var labelLimit: Int
    var showsPerson: Bool

    init(width: CGFloat) {
        showsDate = width >= Self.dateFrom
        showsProject = width >= Self.projectFrom
        labelLimit = width >= Self.allLabelsFrom ? Self.maxLabels : (width >= Self.personFrom ? 1 : 0)
        showsPerson = width >= Self.personFrom
    }
}

/// Die Liste: Gruppen mit Kopf (Name, Zahl, aufklappbar) und Zeilen wie in
/// Linear plus Chat. Liest fertige Gruppen aus der Präsentation; gerechnet
/// wird im ViewModel. Die Zeilen sind ein `LazyVStack` (wenige Hundert Tickets).
struct TicketListView: View {
    let model: TicketBoardViewModel
    let source: TicketChatStatusSource

    var body: some View {
        let presentation = model.presentation
        GeometryReader { proxy in
            let layout = TicketListRowLayout(width: proxy.size.width)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(presentation.groups) { group in
                            let collapsed = model.isCollapsed(group.id)
                            TicketListGroupHeader(group: group, isCollapsed: collapsed,
                                                  isSelected: model.selectedGroupID == group.id) {
                                model.toggleGroup(group.id)
                            }
                            .id("group:" + group.id)
                            if !collapsed {
                                ForEach(group.rows) { row in
                                    TicketListRowView(row: row, layout: layout, rule: presentation.rule,
                                                      isSelected: model.selectedKey == row.id, source: source) {
                                        model.openFromList(row.id)
                                    }
                                    .id(row.id)
                                }
                            }
                        }
                        if presentation.groups.isEmpty {
                            Group {
                                if model.isViewUnavailable {
                                    Text("View not available. It may have been deleted in Linear.")
                                } else if model.isViewLoading {
                                    Text("Loading view…")
                                } else {
                                    Text("No tickets in this view.")
                                }
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(AgentTheme.textSecondary)
                            .padding(14)
                        }
                    }
                    .padding(.bottom, 10)
                }
                // Auswahl per Tastatur und Controller: nur so weit scrollen, dass sie zu sehen ist.
                .onChange(of: model.selectedKey) { _, key in if let key { reader.scrollTo(key) } }
                .onChange(of: model.selectedGroupID) { _, id in if let id { reader.scrollTo("group:" + id) } }
            }
        }
        .background(TicketBoardStyle.column, in: TicketBoardStyle.shape)
        .clipShape(TicketBoardStyle.shape)
    }
}

/// Kopf einer Gruppe: Pfeil, Symbol, Name, Zahl, rechts wie viele einen Chat haben.
struct TicketListGroupHeader: View {
    let group: TicketListGroup
    let isCollapsed: Bool
    let isSelected: Bool
    var compact = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .frame(width: 10)
                TicketListGroupSymbolView(symbol: group.symbol, waitsForMe: group.waitsForMe)
                Text(verbatim: group.title)
                    .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: "\(group.rows.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                if group.waitsForMe {
                    Group { if compact { Text("for you") } else { Text("waits for you") } }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.statusAwaiting)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !compact, group.agentCount > 0 {
                    Text("\(group.agentCount) with chat")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? 28 : 32)
            .background(compact ? Color.clear : AgentTheme.background.opacity(0.5))
            .overlay(alignment: .bottom) {
                if !compact { Rectangle().fill(AgentTheme.border).frame(height: 1) }
            }
            .overlay { if isSelected { TicketListSelectionRing() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(group.title), \(group.rows.count)"))
        .accessibilityValue(isCollapsed ? Text("Collapsed") : Text("Expanded"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Ring der Auswahl per Controller und Pfeiltasten, wie an der gewählten Karte.
struct TicketListSelectionRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(AgentTheme.accent, lineWidth: 2)
            .padding(1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Eine Zeile: Priorität, Nummer, Status, Titel; rechts Labels, Projekt, Chat,
/// Person, Datum (Entscheidung Giuliano, 16.11.2026: „Wie Linear plus Chat“).
struct TicketListRowView: View {
    let row: TicketListRow
    let layout: TicketListRowLayout
    let rule: TicketTeamRule
    let isSelected: Bool
    let source: TicketChatStatusSource
    let open: () -> Void

    /// Feste Spalte für den Chat, damit die Punkte untereinander stehen.
    static let chatWidth: CGFloat = 96
    static let indentStep: CGFloat = 20

    private var ticket: Ticket { row.entry.ticket }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                if row.depth > 0 {
                    TicketListIndent()
                        .frame(width: CGFloat(row.depth) * Self.indentStep)
                }
                TicketPriorityBars(priority: ticket.priority)
                    .frame(width: 14)
                Text(verbatim: ticket.key)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 64, alignment: .leading)
                TicketStatusSymbol(status: ticket.status, meaning: row.entry.meaning)
                title
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                labels
                if layout.showsProject, let project = ticket.project {
                    TicketProjectChip(name: project)
                }
                TicketAgentRow(entry: row.entry, source: source, compact: true)
                    .frame(width: Self.chatWidth, alignment: .leading)
                if layout.showsPerson { TicketAvatar(person: ticket.assignee) }
                if layout.showsDate {
                    Text(verbatim: ticket.updatedAt.map(TicketBoardText.shortDate) ?? "")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(AgentTheme.textSecondary)
                        .lineLimit(1)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(isSelected ? AgentTheme.selection : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(AgentTheme.border).frame(height: 1) }
            .overlay { if isSelected { TicketListSelectionRing() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TicketBoardText.spoken(row.entry)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private var title: some View {
        HStack(spacing: 6) {
            if let parent = row.parentKeyOutsideView {
                Text(verbatim: "↳ " + parent)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(Text("Sub-issue of \(parent), which is not in this view"))
            }
            Text(verbatim: ticket.title)
                .font(.system(size: 12.5))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let children = row.children {
                Text(verbatim: "\(children.done)/\(children.total)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(AgentTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .overlay(Capsule().strokeBorder(AgentTheme.border, lineWidth: 1))
                    .fixedSize()
                    .help(Text("Sub-issues in this view"))
            }
            if ticket.isBlocked {
                TicketTag(text: String(localized: "Blocked"), tone: AgentTheme.statusError)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var labels: some View {
        if layout.labelLimit > 0, !ticket.labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(ticket.labels.prefix(layout.labelLimit), id: \.self) { label in
                    TicketLabelChip(name: label, waits: rule.waitingLabels.contains { $0.caseInsensitiveCompare(label) == .orderedSame })
                }
                if ticket.labels.count > layout.labelLimit {
                    Text(verbatim: "+\(ticket.labels.count - layout.labelLimit)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .help(Text(verbatim: ticket.labels.dropFirst(layout.labelLimit).joined(separator: ", ")))
                }
            }
            .fixedSize()
        }
    }
}

/// Einrückung einer Unteraufgabe: ein kleiner Haken vom Eltern-Ticket her.
struct TicketListIndent: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let x = proxy.size.width - 12
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: proxy.size.height / 2 - 3))
                path.addQuadCurve(to: CGPoint(x: x + 6, y: proxy.size.height / 2),
                                  control: CGPoint(x: x, y: proxy.size.height / 2))
            }
            .stroke(AgentTheme.borderStrong, lineWidth: 1.2)
        }
        .accessibilityHidden(true)
    }
}

/// Status als Kreis wie in Linear: gestrichelt (Backlog), leer (offen), halb
/// (in Arbeit), dreiviertel in Bernstein (wartet auf dich), voll (gebaut, wartet
/// auf andere). Kein Grün: Grün heißt in der App nur „Chat arbeitet“.
struct TicketStatusSymbol: View {
    let status: TicketStatus
    let meaning: TicketStatusMeaning?

    var body: some View {
        ZStack {
            switch status.kind {
            case .backlog, .triage:
                Circle().strokeBorder(tone, style: StrokeStyle(lineWidth: 1.4, dash: [2, 1.6]))
            case .unstarted:
                Circle().strokeBorder(tone, lineWidth: 1.4)
            default:
                Circle().strokeBorder(tone, lineWidth: 1.4)
                TicketStatusFill(fraction: fraction).fill(tone).padding(3)
            }
        }
        .frame(width: 13, height: 13)
        .help(Text(verbatim: status.name))
        .accessibilityLabel(Text(verbatim: status.name))
    }

    private var tone: Color {
        if meaning == .waitsForMe { return AgentTheme.statusAwaiting }
        switch status.kind {
        case .started, .completed: return AgentTheme.accent
        case .triage: return AgentTheme.accent
        default: return AgentTheme.textSecondary
        }
    }

    private var fraction: Double {
        switch meaning {
        case .waitsForMe: return 0.75
        case .done: return 1
        default: return status.kind == .completed ? 1 : 0.5
        }
    }
}

/// Tortenstück für den Status-Kreis.
struct TicketStatusFill: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Label als Kapsel; Labels, mit denen ein Ticket auf dich wartet, in Bernstein.
struct TicketLabelChip: View {
    let name: String
    let waits: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(waits ? AgentTheme.statusAwaiting : AgentTheme.textSecondary.opacity(0.6)).frame(width: 6, height: 6)
            Text(verbatim: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .overlay(Capsule().strokeBorder(AgentTheme.border, lineWidth: 1))
    }
}

struct TicketProjectChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack")
                .font(.system(size: 9, weight: .medium))
            // Lange Namen gekürzt, damit der Chip nie den Titel verdrängt; er selbst wird nie zusammengedrückt.
            Text(verbatim: name.count > 24 ? String(name.prefix(23)) + "…" : name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(AgentTheme.textSecondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(AgentTheme.border, lineWidth: 1))
        .fixedSize()
        .help(Text(verbatim: name))
    }
}

/// Symbol vor dem Namen einer Gruppe.
struct TicketListGroupSymbolView: View {
    let symbol: TicketListGroupSymbol
    var waitsForMe = false

    var body: some View {
        switch symbol {
        case .status(let status):
            TicketStatusSymbol(status: status, meaning: waitsForMe ? .waitsForMe : nil)
        case .priority(let priority):
            TicketPriorityBars(priority: priority).frame(width: 14)
        case .project:
            Image(systemName: "square.stack").font(.system(size: 10, weight: .medium)).foregroundStyle(AgentTheme.textSecondary)
        case .person:
            Image(systemName: "person").font(.system(size: 10, weight: .medium)).foregroundStyle(AgentTheme.textSecondary)
        case .label:
            Image(systemName: "tag").font(.system(size: 10, weight: .medium)).foregroundStyle(AgentTheme.textSecondary)
        case .none:
            EmptyView()
        }
    }
}
