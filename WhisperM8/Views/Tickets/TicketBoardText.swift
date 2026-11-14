import SwiftUI

// MARK: - Texte der Ticket-Ansicht

enum TicketBoardText {
    static func state(_ state: TicketChatState?) -> String {
        switch state {
        case .working: return String(localized: "working")
        case .needsYou: return String(localized: "waiting for you")
        case .idle: return String(localized: "idle")
        case .errored: return String(localized: "error")
        case .stopped: return String(localized: "stopped")
        case nil: return String(localized: "state unknown")
        }
    }

    /// „seit 14. Nov., 04:21“ für die Zeile unter dem Chat.
    static func since(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func priority(_ priority: Int) -> String {
        switch priority {
        case 1: return String(localized: "Urgent")
        case 2: return String(localized: "High")
        case 3: return String(localized: "Medium")
        case 4: return String(localized: "Low")
        default: return String(localized: "No priority")
        }
    }

    static func column(_ kind: TicketStatusKind) -> String {
        switch kind {
        case .started: return String(localized: "In progress")
        case .unstarted, .triage: return String(localized: "Up next")
        default: return String(localized: "Backlog")
        }
    }

    static func project(_ name: String) -> String {
        name.isEmpty ? String(localized: "No Linear project") : name
    }

    /// Projekt und Meilenstein in einer Zeile.
    static func placement(_ ticket: Ticket) -> String {
        let project = project(ticket.project ?? "")
        return ticket.milestone.map { "\(project) · \($0)" } ?? project
    }

    /// Kürzel aus dem Namen für das runde Zeichen einer Person.
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// Namen für die Personen-Knöpfe: der Vorname, bei gleichen Vornamen der ganze Name.
    static func chipNames(_ people: [TicketPerson]) -> [String: String] {
        func first(_ person: TicketPerson) -> String { person.name.components(separatedBy: " ").first ?? person.name }
        let counts = Dictionary(grouping: people, by: first).mapValues(\.count)
        return Dictionary(people.map { ($0.id, counts[first($0), default: 0] > 1 ? $0.name : first($0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Labels in der Reihenfolge für die Karte: zuerst, was etwas über den
    /// Stand sagt, zuletzt die Art des Tickets (Linears Standard-Labels), die
    /// auf fast jeder Karte stünde.
    static let typeLabels: Set<String> = ["bug", "feature", "improvement"]

    static func cardLabels(_ labels: [String]) -> [String] {
        labels.filter { !typeLabels.contains($0.lowercased()) } + labels.filter { typeLabels.contains($0.lowercased()) }
    }

    /// Der Statusname sagt nichts Neues, wenn er nur die Spalte wiederholt
    /// (Linears Standard: In Progress, Todo, Backlog, Triage).
    static func repeatsColumn(_ status: TicketStatus) -> Bool {
        ["inprogress", "todo", "backlog", "triage"].contains(status.name.lowercased().filter { !$0.isWhitespace })
    }

    /// Was VoiceOver zu einer Karte sagt: ein Satz statt jedes Einzelteils.
    static func spoken(_ entry: TicketBoardEntry) -> String {
        let agent = entry.agents.first?.chat?.shortName ?? String(localized: "No agent")
        return [entry.ticket.key, entry.ticket.title, entry.ticket.status.name, priority(entry.ticket.priority), agent]
            .joined(separator: ", ")
    }

    /// Uhrzeit des letzten Abrufs. Fest, kein mitlaufender Zähler.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Kleine Bausteine

/// Status-Punkt eines Chats. Liest als einziges Stück der Ansicht den
/// Live-Zustand und nutzt den gemeinsamen Punkt der App (Grün heißt nur
/// „arbeitet“).
struct TicketChatStatusDot: View {
    let chatID: UUID
    let source: TicketChatStatusSource
    @State private var status: AgentSessionRuntimeStatus?

    init(chatID: UUID, source: TicketChatStatusSource) {
        self.chatID = chatID
        self.source = source
        _status = State(initialValue: source.current(chatID))
    }

    var body: some View {
        // Kompakt wie in den Tabs: Eine Wand pulsierender Punkte wäre unruhig.
        AgentStatusIndicator(status: status, compact: true)
            .frame(width: 10, height: 10)
            .onReceive(source.changes(chatID)) { status = $0 }
    }
}

/// Text zum Zustand eines Chats, live wie der Punkt.
struct TicketChatStateLabel: View {
    let chatID: UUID
    let source: TicketChatStatusSource
    @State private var status: AgentSessionRuntimeStatus?

    init(chatID: UUID, source: TicketChatStatusSource) {
        self.chatID = chatID
        self.source = source
        _status = State(initialValue: source.current(chatID))
    }

    var body: some View {
        Text(verbatim: TicketBoardText.state(TicketChatState(status)))
            .font(.system(size: 11))
            .foregroundStyle(AgentTheme.textSecondary)
            .onReceive(source.changes(chatID)) { status = $0 }
    }
}

/// Drei Balken für die Priorität, mit Text für VoiceOver.
struct TicketPriorityBars: View {
    let priority: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(index < filled ? color : AgentTheme.border)
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .frame(height: 10, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TicketBoardText.priority(priority)))
        .help(Text(verbatim: TicketBoardText.priority(priority)))
    }

    private var filled: Int {
        switch priority {
        case 1, 2: return 3
        case 3: return 2
        case 4: return 1
        default: return 0
        }
    }

    private var color: Color { priority == 1 ? AgentTheme.statusAwaiting : AgentTheme.textSecondary }
}

struct TicketTag: View {
    let text: String
    var tone: Color = AgentTheme.textSecondary

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tone.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

struct TicketAvatar: View {
    let person: TicketPerson?

    var body: some View {
        Group {
            if let person {
                Text(verbatim: TicketBoardText.initials(person.name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .frame(width: 20, height: 20)
                    .background(AgentTheme.accentTint, in: Circle())
                    .help(Text(verbatim: person.name))
                    .accessibilityLabel(Text(verbatim: person.name))
            } else {
                Circle()
                    .strokeBorder(AgentTheme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 20, height: 20)
                    .help(Text("Unassigned"))
                    .accessibilityLabel(Text("Unassigned"))
            }
        }
    }
}

/// Fortschritt der Kästchen unter „Fertig, wenn“.
struct TicketCriteriaBadge: View {
    let progress: TicketChecklistProgress

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checklist")
                .font(.system(size: 10, weight: .medium))
            Text(verbatim: "\(progress.done)/\(progress.total)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(progress.done == progress.total ? AgentTheme.statusWorking : AgentTheme.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(progress.done) of \(progress.total) done"))
    }
}

// MARK: - Zeile „wer sitzt daran“

/// Der Chat an einem Ticket, oder sichtbar, dass keiner daran sitzt.
struct TicketAgentRow: View {
    let entry: TicketBoardEntry
    let source: TicketChatStatusSource
    /// In der Liste nur Punkt und Name; die Karte nennt auch den Zustand.
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if let agent = entry.agents.first {
                if let chat = agent.chat {
                    TicketChatStatusDot(chatID: chat.id, source: source)
                    Text(verbatim: chat.shortName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .lineLimit(1)
                    if !compact { TicketChatStateLabel(chatID: chat.id, source: source) }
                } else {
                    Circle().strokeBorder(AgentTheme.borderStrong, lineWidth: 1).frame(width: 7, height: 7)
                    Text("Other Mac or deleted")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .lineLimit(1)
                }
                if entry.agents.count > 1 {
                    Text(verbatim: "+\(entry.agents.count - 1)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AgentTheme.textSecondary)
                }
            } else if entry.isHandedOver {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AgentTheme.textSecondary)
                Text("Handed over by \(entry.handedOverBy.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .lineLimit(1)
            } else if entry.ticket.status.kind == .backlog {
                Circle().fill(AgentTheme.border).frame(width: 7, height: 7)
                Text("Not scheduled yet")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
            } else {
                // Auffällig durch Form und Gewicht, nicht durch eine Statusfarbe:
                // Gelb heißt in der App „wartet auf dich“, Rot „Fehler“.
                Circle()
                    .strokeBorder(AgentTheme.textPrimary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                    .frame(width: 9, height: 9)
                Text("No agent")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AgentTheme.textPrimary)
            }
        }
    }
}
