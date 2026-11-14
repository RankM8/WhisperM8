import Foundation

// MARK: - Board: wer sitzt woran (pur, ohne Netz und ohne App-Zustand)

/// Ein Chat an einem Ticket, aufgelöst gegen die Chats dieser Installation.
struct TicketAgent: Equatable {
    var link: TicketChatLink
    /// `nil`: Der Chat läuft nicht auf diesem Rechner oder existiert nicht mehr.
    var chat: TicketChat?
}

struct TicketBoardEntry: Equatable, Identifiable {
    var ticket: Ticket
    var agents: [TicketAgent]

    var id: String { ticket.id }
    var hasAgent: Bool { !agents.isEmpty }

    /// In Arbeit, kein Chat sitzt mehr daran, aber einer hat die Arbeit beendet:
    /// Das Ticket wartet auf den nächsten Schritt (etwa den Merge), nicht auf
    /// einen Agent.
    var isHandedOver: Bool {
        agents.isEmpty && ticket.status.kind == .started && ticket.links.contains { !$0.isActive }
    }

    /// Chats, die das Ticket abgegeben haben (Kurzname aus dem Titel der Verknüpfung).
    var handedOverBy: [String] {
        ticket.links.filter { !$0.isActive }.map { link in
            // Derselbe Rufname wie bei laufenden Chats, hier aus dem Titel der Verknüpfung.
            TicketChat(id: link.chatID, title: link.title.replacingOccurrences(of: "Chat: ", with: ""),
                       projectName: "", projectPath: "", state: nil, isRunning: false).shortName
        }
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
    static func build(snapshot: TicketBoardSnapshot, chats: [TicketChat], projectPath: String?) -> TicketBoardModel {
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
            entries.append(TicketBoardEntry(ticket: ticket, agents: agents))
        }

        let candidates = chats.filter { chat in
            chat.isRunning && !linkedChatIDs.contains(chat.id)
                && (projectPath == nil || chat.projectPath == projectPath)
        }
        let supervisors = candidates.filter(isSupervisor)
        let loose = candidates.filter { !isSupervisor($0) }.map {
            TicketLooseChat(chat: $0, earlier: (earlier[$0.id] ?? []).sorted(by: keyOrder))
        }
        return TicketBoardModel(
            entries: entries,
            looseChats: loose.sorted { $0.chat.title.localizedStandardCompare($1.chat.title) == .orderedAscending },
            supervisors: supervisors
        )
    }

    static func isSupervisor(_ chat: TicketChat) -> Bool {
        chat.title.lowercased().hasPrefix(supervisorTitlePrefix)
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
    /// Sie warten auf den Merge, nicht auf einen Chat.
    case withoutAgent
}

enum TicketPersonFilter: Equatable {
    case all
    case unassigned
    case person(id: String)
}

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
        case .withoutAgent: return !entry.hasAgent && entry.ticket.status.kind != .backlog && !entry.isHandedOver
        }
    }
}

/// Zahlen für die Filter-Knöpfe. Jede Gruppe zählt innerhalb der übrigen
/// Auswahl, damit die Zahl am Knopf stimmt, wenn man ihn drückt.
struct TicketFilterCounts: Equatable {
    var all: Int
    var withAgent: Int
    var withoutAgent: Int
    var unassigned: Int
    /// Personen mit Anzahl, alphabetisch.
    var people: [(person: TicketPerson, count: Int)]

    static func == (lhs: TicketFilterCounts, rhs: TicketFilterCounts) -> Bool {
        lhs.all == rhs.all && lhs.withAgent == rhs.withAgent && lhs.withoutAgent == rhs.withoutAgent
            && lhs.unassigned == rhs.unassigned
            && lhs.people.map(\.person) == rhs.people.map(\.person)
            && lhs.people.map(\.count) == rhs.people.map(\.count)
    }

    static func make(entries: [TicketBoardEntry], filter: TicketBoardFilter) -> TicketFilterCounts {
        var agentBase = filter
        agentBase.agent = .all
        let forAgents = agentBase.apply(to: entries)

        var personBase = filter
        personBase.person = .all
        let forPeople = personBase.apply(to: entries)

        var byPerson: [TicketPerson: Int] = [:]
        for entry in forPeople {
            if let person = entry.ticket.assignee { byPerson[person, default: 0] += 1 }
        }
        var without = agentBase
        without.agent = .withoutAgent
        return TicketFilterCounts(
            all: forAgents.count,
            withAgent: forAgents.filter(\.hasAgent).count,
            withoutAgent: without.apply(to: entries).count,
            unassigned: forPeople.filter { $0.ticket.assignee == nil }.count,
            people: byPerson.map { (person: $0.key, count: $0.value) }
                .sorted { $0.person.name.localizedStandardCompare($1.person.name) == .orderedAscending }
        )
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
                    let lp = lhs.element.ticket.status.position, rp = rhs.element.ticket.status.position
                    return lp != rp ? lp < rp : lhs.offset < rhs.offset
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
