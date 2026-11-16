import Foundation

// MARK: - Board: wer sitzt woran (pur, ohne Netz und ohne App-Zustand)

/// Ein Chat an einem Ticket, aufgelöst gegen die Chats dieser Installation.
struct TicketAgent: Equatable {
    var link: TicketChatLink
    /// `nil`: Der Chat läuft nicht auf diesem Rechner oder existiert nicht mehr.
    var chat: TicketChat?
}

struct TicketBoardEntry: Equatable, Identifiable {
    var ticket: Ticket {
        didSet { derive() }
    }
    var agents: [TicketAgent]
    /// Was der Status im Team bedeutet (Regel des Teams, sonst seine Art).
    var meaning: TicketStatusMeaning?
    /// Wartet auf den Nutzer, nach der Regel des Teams.
    var waitsForMe: Bool
    /// Fortschritt der Kästchen und Rufnamen der abgebenden Chats, einmal
    /// gerechnet: Karten lesen sie bei jedem Zeichnen.
    private(set) var criteria: TicketChecklistProgress?
    private(set) var handedOverBy: [String] = []

    init(ticket: Ticket, agents: [TicketAgent], meaning: TicketStatusMeaning? = nil, waitsForMe: Bool = false) {
        self.ticket = ticket
        self.agents = agents
        self.meaning = meaning ?? (ticket.status.kind == .started ? .inProgress : nil)
        self.waitsForMe = waitsForMe
        derive()
    }

    private mutating func derive() {
        criteria = ticket.criteria
        handedOverBy = ticket.links.filter { !$0.isActive }.map { link in
            // Derselbe Rufname wie bei laufenden Chats, hier aus dem Titel der Verknüpfung.
            TicketChat(id: link.chatID, title: link.title.replacingOccurrences(of: "Chat: ", with: ""),
                       projectName: "", projectPath: "", state: nil, isRunning: false).shortName
        }
    }

    var id: String { ticket.id }
    var hasAgent: Bool { !agents.isEmpty }

    /// In Arbeit, kein Chat sitzt mehr daran, aber einer hat die Arbeit beendet:
    /// Das Ticket wartet auf den nächsten Schritt (etwa den Merge), nicht auf
    /// einen Agent.
    var isHandedOver: Bool {
        agents.isEmpty && ticket.status.kind == .started && ticket.links.contains { !$0.isActive }
    }

}

/// Laufender Chat, an dem kein offenes Ticket hängt.
struct TicketLooseChat: Equatable, Identifiable {
    var chat: TicketChat
    /// Erledigte Tickets, an denen er zuletzt saß („WM8-29 (Done)“).
    var earlier: [String]

    var id: UUID { chat.id }
}

struct TicketBoardModel: Equatable {
    var entries: [TicketBoardEntry]
    var looseChats: [TicketLooseChat]
    /// Supervisor-Chats betreuen andere Chats und brauchen kein Ticket.
    var supervisors: [TicketChat]
    /// Status des Teams in seiner Reihenfolge; daraus werden die Spalten.
    var statuses: [TicketStatus] = []
    /// Regel des Teams, mit der Bedeutungen und „wartet auf mich“ gerechnet wurden.
    var rule = TicketTeamRule()
    /// Ansicht aus Linear, deren Tickets `entries` sind (WM8-125); `nil` = alle
    /// offenen Tickets des Teams, nach Status gruppiert.
    var view: TicketView? = nil
    /// Wie viele offene Tickets des ganzen Teams auf den Nutzer warten, gleich
    /// welche Ansicht gezeigt wird (Zahl in der Board-Wahl des Controllers).
    var teamWaitingCount = 0

    /// Dasselbe Modell ohne den Zustand der Chats. Die Ansicht führt den
    /// Zustand getrennt: Ein Statuswechsel soll das Modell nicht „ändern“ und
    /// damit alles neu rechnen und zeichnen lassen.
    var withoutChatStates: TicketBoardModel {
        func plain(_ chat: TicketChat) -> TicketChat {
            var copy = chat
            copy.state = nil
            return copy
        }
        var copy = self
        copy.entries = entries.map { entry in
            var entry = entry
            entry.agents = entry.agents.map { TicketAgent(link: $0.link, chat: $0.chat.map(plain)) }
            return entry
        }
        copy.looseChats = looseChats.map { TicketLooseChat(chat: plain($0.chat), earlier: $0.earlier) }
        copy.supervisors = supervisors.map(plain)
        return copy
    }

    /// Zustand je Chat, so wie der Abzug ihn kennt.
    var chatStates: [UUID: TicketChatState] {
        var states: [UUID: TicketChatState] = [:]
        let chats = entries.flatMap { $0.agents.compactMap(\.chat) } + looseChats.map(\.chat) + supervisors
        for chat in chats { if let state = chat.state { states[chat.id] = state } }
        return states
    }
}

extension TicketBoardBuilder {
    /// Board des Teams; mit Ansicht (WM8-125) stehen deren Tickets statt aller
    /// offenen Tickets des Teams im Modell. Chats ohne Ticket und Supervisoren
    /// kommen weiter aus dem Team. Ist eine Ansicht gewählt, aber noch nicht
    /// geladen, bleibt die Liste leer, statt kurz die falschen Tickets zu zeigen.
    static func build(snapshot: TicketBoardSnapshot, chats: [TicketChat], projectPath: String?, rule: TicketTeamRule,
                      view: TicketView?, viewTickets: TicketViewTickets?) -> TicketBoardModel {
        var model = build(snapshot: snapshot, chats: chats, projectPath: projectPath, rule: rule)
        guard let view else { return model }
        model.view = view
        guard let viewTickets else {
            model.entries = []
            return model
        }
        let viewSnapshot = TicketBoardSnapshot(team: snapshot.team, statuses: snapshot.statuses, tickets: viewTickets.tickets,
                                               fetchedAt: viewTickets.fetchedAt, viewerID: snapshot.viewerID)
        model.entries = build(snapshot: viewSnapshot, chats: chats, projectPath: projectPath, rule: rule).entries
        return model
    }
}

enum TicketBoardBuilder {
    /// Titelanfang von Supervisor-Chats. Ein Merkmal an der Sitzung wäre
    /// sauberer; bis dahin gilt die Benennung, die der Nutzer führt.
    static let supervisorTitlePrefix = "jarvis"

    /// - Parameters:
    ///   - snapshot: Abzug inklusive erledigter Tickets, sonst fehlt die Spur
    ///     „zuletzt an …“.
    ///   - chats: alle Chats dieser Installation, laufende und ruhende.
    ///   - projectPath: nur Chats dieses Projekts gelten als „ohne Ticket“.
    static func build(snapshot: TicketBoardSnapshot, chats: [TicketChat], projectPath: String?,
                      rule: TicketTeamRule = TicketTeamRule()) -> TicketBoardModel {
        let chatsByID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var linkedChatIDs = Set<UUID>()
        var earlier: [UUID: [String]] = [:]
        var entries: [TicketBoardEntry] = []

        for ticket in snapshot.tickets {
            if ticket.status.kind.isClosed {
                // Erledigt: Der Chat gilt nicht mehr als zuständig, die Spur bleibt.
                for link in ticket.links {
                    earlier[link.chatID, default: []].append("\(ticket.key) (\(ticket.status.name))")
                }
                continue
            }
            let agents = ticket.activeLinks.map { link -> TicketAgent in
                linkedChatIDs.insert(link.chatID)
                return TicketAgent(link: link, chat: chatsByID[link.chatID])
            }
            // Beendete Verknüpfung an einem offenen Ticket (etwa „Merge-bereit“):
            // Der Chat hat abgegeben, die Spur gehört trotzdem zu ihm.
            for link in ticket.links where !link.isActive {
                earlier[link.chatID, default: []].append("\(ticket.key) (\(ticket.status.name))")
            }
            entries.append(TicketBoardEntry(ticket: ticket, agents: agents, meaning: rule.meaning(of: ticket.status),
                                            waitsForMe: rule.waitsForMe(ticket, viewerID: snapshot.viewerID)))
        }

        let candidates = chats.filter { chat in
            chat.isRunning && !linkedChatIDs.contains(chat.id)
                && (projectPath == nil || chat.projectPath == projectPath)
        }
        let supervisors = candidates.filter(isSupervisor)
        let loose = candidates.filter { !isSupervisor($0) }.map {
            TicketLooseChat(chat: $0, earlier: (earlier[$0.id] ?? []).sorted(by: keyOrder))
        }
        var model = TicketBoardModel(
            entries: entries,
            looseChats: loose.sorted { $0.chat.title.localizedStandardCompare($1.chat.title) == .orderedAscending },
            supervisors: supervisors,
            statuses: snapshot.statuses,
            rule: rule
        )
        // Erledigte stehen hier nicht mehr (siehe oben); gezählt wird über das ganze Team.
        model.teamWaitingCount = entries.filter(\.waitsForMe).count
        return model
    }

    static func isSupervisor(_ chat: TicketChat) -> Bool {
        isSupervisor(title: chat.title)
    }

    /// Eine Regel für CLI, Board und Board-Chat (WM8-113).
    static func isSupervisor(title: String) -> Bool {
        title.lowercased().hasPrefix(supervisorTitlePrefix)
    }

    /// `WM8-9` vor `WM8-10`.
    static func keyOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

// MARK: - Filter

enum TicketAgentFilter: String, Equatable, CaseIterable {
    case all
    case withAgent
    /// In Arbeit oder bereit, aber niemand sitzt daran. Backlog zählt nicht:
    /// dort ist ein fehlender Agent kein Befund. Abgegebene Tickets auch nicht:
    /// Sie warten auf den Merge, nicht auf einen Chat. Ebenso Status, die nach
    /// der Regel des Teams „fertig“ oder „wartet auf mich“ bedeuten.
    case withoutAgent
}

enum TicketPersonFilter: Hashable {
    case all
    case unassigned
    case person(id: String)
}

/// Filter der Kommandozeile (`tickets list --no-agent`, `--person`, `--project`). Das Board
/// filtert seit WM8-125 nicht mehr selbst, sondern zeigt Ansichten aus Linear.
struct TicketBoardFilter: Equatable {
    var agent: TicketAgentFilter = .all
    var person: TicketPersonFilter = .all
    /// Name des Vorhabens; `""` steht für „ohne Vorhaben“.
    var project: String?

    static let all = TicketBoardFilter()

    func matches(_ entry: TicketBoardEntry) -> Bool {
        matchesProject(entry) && matchesPerson(entry) && matchesAgent(entry)
    }

    func apply(to entries: [TicketBoardEntry]) -> [TicketBoardEntry] {
        entries.filter(matches)
    }

    private func matchesProject(_ entry: TicketBoardEntry) -> Bool {
        guard let project else { return true }
        return (entry.ticket.project ?? "") == project
    }

    private func matchesPerson(_ entry: TicketBoardEntry) -> Bool {
        switch person {
        case .all: return true
        case .unassigned: return entry.ticket.assignee == nil
        case .person(let id): return entry.ticket.assignee?.id == id
        }
    }

    private func matchesAgent(_ entry: TicketBoardEntry) -> Bool {
        switch agent {
        case .all: return true
        case .withAgent: return entry.hasAgent
        case .withoutAgent:
            return !entry.hasAgent && entry.ticket.status.kind != .backlog && !entry.isHandedOver
                && entry.meaning != .done && entry.meaning != .waitsForMe
        }
    }
}

// MARK: - Gruppen für Board und Liste

struct TicketBoardColumn: Equatable, Identifiable {
    var kind: TicketStatusKind
    var entries: [TicketBoardEntry]

    var id: String { kind.rawValue }
    var agentCount: Int { entries.filter(\.hasAgent).count }
}

enum TicketBoardLayout {
    /// Spalten des Boards: in Arbeit, als Nächstes, Backlog. Der Eingang (Triage)
    /// steht bei „als Nächstes“. Innerhalb nach Priorität, bei Gleichstand das
    /// Ticket mit Agent zuerst.
    ///
    /// „In Arbeit“ fasst mehrere Status zusammen (etwa in Arbeit, wartet auf den
    /// Merge, gemergt und wartet aufs Ausliefern). Dort stehen die Tickets
    /// zuerst nach ihrem Status in der Reihenfolge des Teams, damit jede dieser
    /// Stufen als Gruppe zusammensteht.
    static func columns(_ entries: [TicketBoardEntry]) -> [TicketBoardColumn] {
        let kinds: [TicketStatusKind] = [.started, .unstarted, .backlog]
        return kinds.map { kind in
            var rows = entries.filter { column(for: $0.ticket.status.kind) == kind }.sorted(by: order)
            if kind == .started {
                // Stabil: Innerhalb eines Status bleibt die Reihenfolge nach Priorität.
                rows = rows.enumerated().sorted { lhs, rhs in
                    let ls = lhs.element.ticket.status, rs = rhs.element.ticket.status
                    if ls.position != rs.position { return ls.position < rs.position }
                    // Zwei Status an derselben Stelle bleiben trotzdem je eine Gruppe.
                    if ls.id != rs.id { return ls.id < rs.id }
                    return lhs.offset < rhs.offset
                }.map(\.element)
            }
            return TicketBoardColumn(kind: kind, entries: rows)
        }
    }

    static func column(for kind: TicketStatusKind) -> TicketStatusKind {
        kind == .triage ? .unstarted : kind
    }

    /// Priorität 1 (dringend) zuerst, „keine“ zuletzt; dann mit Agent, dann Nummer.
    static func order(_ lhs: TicketBoardEntry, _ rhs: TicketBoardEntry) -> Bool {
        let lp = lhs.ticket.priority == 0 ? 9 : lhs.ticket.priority
        let rp = rhs.ticket.priority == 0 ? 9 : rhs.ticket.priority
        if lp != rp { return lp < rp }
        if lhs.hasAgent != rhs.hasAgent { return lhs.hasAgent }
        return TicketBoardBuilder.keyOrder(lhs.ticket.key, rhs.ticket.key)
    }
}
