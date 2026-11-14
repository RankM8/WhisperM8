import Foundation

// MARK: - Linear als Ticket-Quelle

/// Die einzige Stelle, die Linear kennt. Übersetzt GraphQL-Antworten in die
/// Modelle des Boards und Aufträge des Boards in Linears Änderungen.
struct LinearTicketSource: TicketSource {
    var client: LinearGraphQLClient = .live
    var now: () -> Date = Date.init
    /// Seiten zu je 100 offenen Tickets; darüber wird abgeschnitten.
    var maxPages = 5

    // MARK: Abfragen

    /// Verschachtelte Listen tragen eigene Grenzen, sonst rechnet Linear je
    /// Liste mit 50 Einträgen und die Abfrage wird zu teuer.
    static let ticketFields = """
    id identifier title description priority url
    state { id name type position }
    project { name }
    projectMilestone { name }
    assignee { id name }
    labels(first: 20) { nodes { name } }
    attachments(first: 20) { nodes { id title subtitle url metadata creator { name } } }
    inverseRelations(first: 20) { nodes { type issue { state { type } } } }
    """

    static let closedTypes = ["completed", "canceled", "duplicate"]

    func board(team: String) async throws -> TicketBoardSnapshot {
        let head = try await client.run("""
        query($team: String!, $closed: [String!]!, $prefix: String!) {
          teams(first: 1, filter: { key: { eq: $team } }) { nodes { id key states(first: 50) { nodes { id name type position } } } }
          closed: issues(first: 100, orderBy: updatedAt, filter: {
            team: { key: { eq: $team } }, state: { type: { in: $closed } },
            attachments: { some: { url: { startsWith: $prefix } } }
          }) { nodes { \(Self.ticketFields) } }
        }
        """, variables: ["team": team, "closed": Self.closedTypes, "prefix": TicketChatLinkFormat.urlPrefix])
        guard let teamNode = Self.nodes(head["teams"]).first else {
            throw TicketSourceError.notFound("Team \(team)")
        }
        var tickets = Self.nodes(head["closed"]).compactMap(Self.ticket)

        var cursor: String?
        for _ in 0..<maxPages {
            var variables: [String: Any] = ["team": team, "closed": Self.closedTypes]
            if let cursor { variables["after"] = cursor }
            let page = try await client.run("""
            query($team: String!, $closed: [String!]!, $after: String) {
              issues(first: 100, after: $after, filter: {
                team: { key: { eq: $team } }, state: { type: { nin: $closed } }
              }) { nodes { \(Self.ticketFields) } pageInfo { hasNextPage endCursor } }
            }
            """, variables: variables)
            let issues = page["issues"] as? [String: Any] ?? [:]
            tickets.append(contentsOf: Self.nodes(issues).compactMap(Self.ticket))
            let info = issues["pageInfo"] as? [String: Any] ?? [:]
            guard info["hasNextPage"] as? Bool == true, let next = info["endCursor"] as? String else { break }
            cursor = next
        }
        return TicketBoardSnapshot(team: team, statuses: Self.statuses(teamNode["states"]), tickets: tickets, fetchedAt: now())
    }

    func ticket(key: String) async throws -> TicketContext {
        let data = try await client.run("""
        query($id: String!) {
          issue(id: $id) { \(Self.ticketFields) team { key states(first: 50) { nodes { id name type position } } } }
        }
        """, variables: ["id": key])
        guard let node = data["issue"] as? [String: Any], let ticket = Self.ticket(node),
              let team = node["team"] as? [String: Any] else {
            throw TicketSourceError.notFound(key)
        }
        return TicketContext(ticket: ticket, team: team["key"] as? String ?? "", statuses: Self.statuses(team["states"]))
    }

    func tickets(linkedTo chatID: UUID) async throws -> [Ticket] {
        let data = try await client.run("""
        query($url: String!) {
          issues(first: 50, filter: { attachments: { some: { url: { eq: $url } } } }) { nodes { \(Self.ticketFields) } }
        }
        """, variables: ["url": TicketChatLinkFormat.url(for: chatID)])
        return Self.nodes(data["issues"]).compactMap(Self.ticket)
    }

    func person(matching query: String) async throws -> TicketPerson {
        if query == "me" {
            let data = try await client.run("{ viewer { id name } }")
            guard let viewer = data["viewer"] as? [String: Any], let person = Self.person(viewer) else {
                throw TicketSourceError.invalidResponse("viewer")
            }
            return person
        }
        let data = try await client.run("""
        query($q: String!) {
          users(filter: { or: [{ name: { containsIgnoreCase: $q } }, { displayName: { containsIgnoreCase: $q } }], active: { eq: true } }) {
            nodes { id name app }
          }
        }
        """, variables: ["q": query])
        let people = Self.nodes(data["users"]).filter { $0["app"] as? Bool != true }.compactMap(Self.person)
        if let exact = people.first(where: { $0.id == query }) { return exact }
        switch people.count {
        case 1: return people[0]
        case 0: throw TicketSourceError.notFound("Person „\(query)“")
        default:
            throw TicketSourceError.ambiguous("„\(query)“ passt auf mehrere Personen: \(people.map(\.name).sorted().joined(separator: ", "))")
        }
    }

    func account() async throws -> TicketAccount {
        let data = try await client.run("{ viewer { name admin } organization { name urlKey } }")
        guard let viewer = data["viewer"] as? [String: Any], let org = data["organization"] as? [String: Any] else {
            throw TicketSourceError.invalidResponse("viewer")
        }
        return TicketAccount(
            userName: viewer["name"] as? String ?? "",
            workspace: "\(org["name"] as? String ?? "") (linear.app/\(org["urlKey"] as? String ?? ""))",
            isAdmin: viewer["admin"] as? Bool ?? false
        )
    }

    // MARK: Änderungen

    func setStatus(ticketID: String, statusID: String) async throws {
        try await update(ticketID, ["stateId": statusID])
    }

    func setDescription(ticketID: String, description: String) async throws {
        try await update(ticketID, ["description": description])
    }

    func assign(ticketID: String, personID: String?) async throws {
        try await update(ticketID, ["assigneeId": personID ?? NSNull()])
    }

    private func update(_ ticketID: String, _ input: [String: Any]) async throws {
        _ = try await client.run(
            "mutation($id: String!, $in: IssueUpdateInput!) { issueUpdate(id: $id, input: $in) { success } }",
            variables: ["id": ticketID, "in": input])
    }

    func saveLink(ticketID: String, chat: TicketChat, active: Bool, at date: Date) async throws {
        // Linear führt je Adresse und Ticket einen Anhang: derselbe Aufruf
        // legt an oder frischt auf.
        _ = try await client.run(
            "mutation($in: AttachmentCreateInput!) { attachmentCreate(input: $in) { success } }",
            variables: ["in": [
                "issueId": ticketID,
                "url": TicketChatLinkFormat.url(for: chat.id),
                "title": TicketChatLinkFormat.title(for: chat),
                "subtitle": active ? TicketChatLinkFormat.activeSubtitle(for: chat, at: date)
                    : TicketChatLinkFormat.endedSubtitle(at: date),
                "metadata": TicketChatLinkFormat.metadata(for: chat, active: active, at: date),
            ] as [String: Any]])
    }

    func removeLink(id: String) async throws {
        _ = try await client.run("mutation($id: String!) { attachmentDelete(id: $id) { success } }", variables: ["id": id])
    }

    func addComment(ticketID: String, body: String) async throws {
        _ = try await client.run(
            "mutation($in: CommentCreateInput!) { commentCreate(input: $in) { success } }",
            variables: ["in": ["issueId": ticketID, "body": body]])
    }

    func create(_ draft: TicketDraft) async throws -> Ticket {
        let lookup = try await client.run("""
        query($team: String!) {
          teams(first: 1, filter: { key: { eq: $team } }) { nodes {
            id states(first: 50) { nodes { id name type position } }
            labels(first: 100) { nodes { id name } }
            projects(first: 100) { nodes { id name } }
          } }
          issueLabels(first: 100, filter: { team: { null: true } }) { nodes { id name } }
        }
        """, variables: ["team": draft.team])
        guard let team = Self.nodes(lookup["teams"]).first, let teamID = team["id"] as? String else {
            throw TicketSourceError.notFound("Team \(draft.team)")
        }
        var input: [String: Any] = ["teamId": teamID, "title": draft.title, "description": draft.description]
        if let priority = draft.priority { input["priority"] = priority }
        if let assignee = draft.assigneeID { input["assigneeId"] = assignee }
        if let name = draft.statusName {
            guard let status = Self.statuses(team["states"]).first(where: { $0.name.lowercased() == name.lowercased() }) else {
                throw TicketSourceError.notFound("Status „\(name)“")
            }
            input["stateId"] = status.id
        }
        if let name = draft.project {
            guard let id = Self.id(named: name, in: Self.nodes(team["projects"])) else {
                throw TicketSourceError.notFound("Vorhaben „\(name)“")
            }
            input["projectId"] = id
        }
        if !draft.labels.isEmpty {
            let known = Self.nodes(team["labels"]) + Self.nodes(lookup["issueLabels"])
            input["labelIds"] = try draft.labels.map { name -> String in
                guard let id = Self.id(named: name, in: known) else { throw TicketSourceError.notFound("Label „\(name)“") }
                return id
            }
        }
        let data = try await client.run(
            "mutation($in: IssueCreateInput!) { issueCreate(input: $in) { issue { \(Self.ticketFields) } } }",
            variables: ["in": input])
        guard let created = (data["issueCreate"] as? [String: Any])?["issue"] as? [String: Any],
              let ticket = Self.ticket(created) else {
            throw TicketSourceError.invalidResponse("issueCreate")
        }
        return ticket
    }

    func changeLabels(ticketID: String, team: String, add: [String], remove: [String]) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        let lookup = try await client.run("""
        query($team: String!) {
          teams(first: 1, filter: { key: { eq: $team } }) { nodes { labels(first: 100) { nodes { id name } } } }
          issueLabels(first: 100, filter: { team: { null: true } }) { nodes { id name } }
        }
        """, variables: ["team": team])
        let known = Self.nodes(Self.nodes(lookup["teams"]).first?["labels"]) + Self.nodes(lookup["issueLabels"])
        func labelID(_ name: String) throws -> String {
            guard let id = Self.id(named: name, in: known) else { throw TicketSourceError.notFound("Label „\(name)“") }
            return id
        }
        for name in add {
            _ = try await client.run(
                "mutation($id: String!, $label: String!) { issueAddLabel(id: $id, labelId: $label) { success } }",
                variables: ["id": ticketID, "label": try labelID(name)])
        }
        for name in remove {
            _ = try await client.run(
                "mutation($id: String!, $label: String!) { issueRemoveLabel(id: $id, labelId: $label) { success } }",
                variables: ["id": ticketID, "label": try labelID(name)])
        }
    }

    // MARK: Übersetzung (pur, mit Fixtures getestet)

    static func nodes(_ value: Any?) -> [[String: Any]] {
        ((value as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    }

    static func id(named name: String, in nodes: [[String: Any]]) -> String? {
        nodes.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["id"] as? String
    }

    static func person(_ node: [String: Any]) -> TicketPerson? {
        guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
        return TicketPerson(id: id, name: name)
    }

    /// Linear kennt neben den sechs Arten noch `duplicate`; für das Board ist
    /// das ein verworfenes Ticket.
    static func kind(_ raw: String) -> TicketStatusKind {
        raw == "duplicate" ? .canceled : (TicketStatusKind(rawValue: raw) ?? .backlog)
    }

    static func status(_ node: [String: Any]) -> TicketStatus? {
        guard let id = node["id"] as? String, let name = node["name"] as? String else { return nil }
        return TicketStatus(id: id, name: name, kind: kind(node["type"] as? String ?? ""),
                            position: (node["position"] as? NSNumber)?.doubleValue ?? 0)
    }

    static func statuses(_ value: Any?) -> [TicketStatus] {
        nodes(value).compactMap(status).sorted { ($0.kind.boardOrder, $0.position) < ($1.kind.boardOrder, $1.position) }
    }

    static func link(_ node: [String: Any]) -> TicketChatLink? {
        guard let id = node["id"] as? String, let url = node["url"] as? String,
              let chatID = TicketChatLinkFormat.chatID(fromURL: url) else { return nil }
        // Fremde Anhänge mit unserer Adresse zählen nicht: Die Marke muss stimmen.
        guard (node["metadata"] as? [String: Any])?["source"] as? String == TicketChatLinkFormat.source else { return nil }
        let subtitle = node["subtitle"] as? String ?? ""
        return TicketChatLink(
            id: id, chatID: chatID, isActive: TicketChatLinkFormat.isActive(subtitle: subtitle),
            title: node["title"] as? String ?? "", subtitle: subtitle,
            creatorName: (node["creator"] as? [String: Any])?["name"] as? String)
    }

    static func ticket(_ node: [String: Any]) -> Ticket? {
        guard let id = node["id"] as? String, let key = node["identifier"] as? String,
              let state = (node["state"] as? [String: Any]).flatMap(status) else { return nil }
        let blocked = nodes(node["inverseRelations"]).contains { relation in
            guard relation["type"] as? String == "blocks" else { return false }
            let type = ((relation["issue"] as? [String: Any])?["state"] as? [String: Any])?["type"] as? String ?? ""
            return !closedTypes.contains(type)
        }
        return Ticket(
            id: id, key: key,
            title: node["title"] as? String ?? "",
            description: node["description"] as? String ?? "",
            priority: (node["priority"] as? NSNumber)?.intValue ?? 0,
            status: state,
            project: (node["project"] as? [String: Any])?["name"] as? String,
            milestone: (node["projectMilestone"] as? [String: Any])?["name"] as? String,
            assignee: (node["assignee"] as? [String: Any]).flatMap(person),
            labels: nodes(node["labels"]).compactMap { $0["name"] as? String },
            links: nodes(node["attachments"]).compactMap(link),
            isBlocked: blocked,
            url: node["url"] as? String)
    }
}
