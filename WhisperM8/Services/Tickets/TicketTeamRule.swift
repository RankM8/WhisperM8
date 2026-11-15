import Foundation

// MARK: - Was ein Status in einem Team bedeutet

/// Bedeutung eines Status für das Board. Die Namen der Status sind je Team
/// verschieden, und derselbe Name kann in zwei Teams Verschiedenes heißen
/// (ein Status, der nach Code-Prüfung klingt, kann „Produktentscheidung offen“
/// bedeuten). Deshalb steht hier kein Name fest im Code: Welcher Status was
/// bedeutet, hält die Regel des Teams in `tickets.json` fest.
enum TicketStatusMeaning: String, Codable, CaseIterable, Equatable {
    /// Wartet auf den Nutzer (Abnahme, Entscheidung, Handtest).
    case waitsForMe
    /// Jemand arbeitet daran.
    case inProgress
    /// Gebaut; wartet auf Merge, Ausliefern oder Prüfung durch andere, nicht auf einen Chat.
    case done

    /// Wörter der Kommandozeile (`tickets setup --status NAME=WORT`).
    static func parse(_ word: String) -> TicketStatusMeaning? {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "wartet", "wartet-auf-mich", "mine", "waiting", "waitsforme": return .waitsForMe
        case "arbeit", "in-arbeit", "working", "inprogress": return .inProgress
        case "fertig", "done", "built": return .done
        default: return nil
        }
    }

    /// Wortlaut in der Kommandozeile (deutsch wie die übrige CLI).
    var cliWord: String {
        switch self {
        case .waitsForMe: return "wartet"
        case .inProgress: return "arbeit"
        case .done: return "fertig"
        }
    }
}

/// Regel eines Teams: was seine Status bedeuten und wann ein Ticket auf den
/// Nutzer wartet. Ohne Eintrag gilt die leere Regel: Status der Art „begonnen“
/// heißen „in Arbeit“, und auf den Nutzer wartet, was ihm zugewiesen ist.
struct TicketTeamRule: Codable, Equatable {
    /// Name des Status → Bedeutung. Verglichen wird ohne Groß/Klein.
    var statusMeanings: [String: TicketStatusMeaning] = [:]
    /// Labels, die ein dem Nutzer zugewiesenes Ticket zu „wartet auf mich“
    /// machen. Leer: jedes ihm zugewiesene offene Ticket.
    var waitingLabels: [String] = []

    init(statusMeanings: [String: TicketStatusMeaning] = [:], waitingLabels: [String] = []) {
        self.statusMeanings = statusMeanings
        self.waitingLabels = waitingLabels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unbekannte Bedeutungen (aus einer neueren Fassung) fallen still weg.
        let raw = try container.decodeIfPresent([String: String].self, forKey: .statusMeanings) ?? [:]
        self.init(statusMeanings: raw.compactMapValues(TicketStatusMeaning.init(rawValue:)),
                  waitingLabels: try container.decodeIfPresent([String].self, forKey: .waitingLabels) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(statusMeanings.mapValues(\.rawValue), forKey: .statusMeanings)
        try container.encode(waitingLabels, forKey: .waitingLabels)
    }

    private enum CodingKeys: String, CodingKey {
        case statusMeanings, waitingLabels
    }

    var isEmpty: Bool { statusMeanings.isEmpty && waitingLabels.isEmpty }

    /// Bedeutung eines Status: die Regel, sonst die Art des Status.
    func meaning(of status: TicketStatus) -> TicketStatusMeaning? {
        let wanted = Self.key(status.name)
        if let set = statusMeanings.first(where: { Self.key($0.key) == wanted })?.value { return set }
        return status.kind == .started ? .inProgress : nil
    }

    /// Wartet das Ticket auf den Nutzer? Entweder sein Status bedeutet das,
    /// oder es ist ihm zugewiesen (und trägt, falls die Regel Labels nennt,
    /// eines davon). Erledigte Tickets warten nie.
    func waitsForMe(_ ticket: Ticket, viewerID: String?) -> Bool {
        guard !ticket.status.kind.isClosed else { return false }
        if meaning(of: ticket.status) == .waitsForMe { return true }
        guard let viewerID, ticket.assignee?.id == viewerID else { return false }
        guard !waitingLabels.isEmpty else { return true }
        return ticket.labels.contains(where: isWaitingLabel)
    }

    /// Hebt die Karte dieses Label hervor?
    func isWaitingLabel(_ label: String) -> Bool {
        waitingLabels.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
    }

    static func key(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Ändern über die Kommandozeile

/// `tickets setup --team T --status NAME=WORT --waiting-labels a,b --clear-rule`.
/// Pur: bekommt die Einrichtung, gibt die geänderte samt Meldung zurück.
enum TicketTeamRuleChange {
    struct Request: Equatable {
        var team: String
        /// `NAME=WORT`, so wie auf der Kommandozeile; `NAME=` nimmt die Bedeutung weg.
        var statuses: [String] = []
        /// `nil`: unverändert; leer: keine Labels mehr.
        var waitingLabels: [String]?
        var clear = false

        /// Nur zeigen, nichts ändern.
        var isShowOnly: Bool { statuses.isEmpty && waitingLabels == nil && !clear }
    }

    struct Problem: Error, Equatable {
        var message: String
    }

    static func apply(_ request: Request, to config: TicketConfig) throws -> (config: TicketConfig, message: String) {
        var rule = request.clear ? TicketTeamRule() : config.rule(forTeam: request.team)
        for entry in request.statuses {
            guard let separator = entry.firstIndex(of: "=") else {
                throw Problem(message: "„\(entry)“: erwartet NAME=BEDEUTUNG, etwa \"Merge-bereit=wartet\".")
            }
            let name = entry[..<separator].trimmingCharacters(in: .whitespaces)
            let word = entry[entry.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw Problem(message: "„\(entry)“: Der Name des Status fehlt.") }
            // Gleicher Name in anderer Schreibweise ersetzt den alten Eintrag.
            rule.statusMeanings = rule.statusMeanings.filter { TicketTeamRule.key($0.key) != TicketTeamRule.key(name) }
            if word.isEmpty { continue }
            guard let meaning = TicketStatusMeaning.parse(word) else {
                throw Problem(message: "„\(word)“ ist keine Bedeutung. Erlaubt: wartet, arbeit, fertig.")
            }
            rule.statusMeanings[name] = meaning
        }
        if let labels = request.waitingLabels { rule.waitingLabels = labels }
        var changed = config
        if !request.isShowOnly { changed.set(rule: rule, forTeam: request.team) }
        return (changed, describe(rule, team: request.team))
    }

    static func describe(_ rule: TicketTeamRule, team: String) -> String {
        var lines = ["Regel für \(team):"]
        if rule.statusMeanings.isEmpty {
            lines.append("  Status: keine eigenen Bedeutungen (begonnene Status gelten als „in Arbeit“).")
        } else {
            for name in rule.statusMeanings.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                lines.append("  \(name) = \(rule.statusMeanings[name]!.cliWord)")
            }
        }
        lines.append(rule.waitingLabels.isEmpty
            ? "  Wartet auf mich: alles, was mir zugewiesen ist, dazu Status mit „wartet“."
            : "  Wartet auf mich: mir zugewiesen mit Label \(rule.waitingLabels.joined(separator: ", ")), dazu Status mit „wartet“.")
        return lines.joined(separator: "\n")
    }
}
