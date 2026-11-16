import Foundation

/// Triage-Entscheidung am Ticket (WM8-113, Teil d). Das Board schreibt nicht
/// selbst nach Linear (Entscheidung E1 vom 15.11.2026): Die Knöpfe sammeln,
/// der Board-Chat führt nach Giulianos Enter aus.
enum TriageDecision: String, CaseIterable, Equatable {
    case accept
    case askBack
    case assign
    case later
    case duplicate
    case decline

    /// Beschriftung des Knopfs.
    var label: String {
        switch self {
        case .accept: return String(localized: "Accept")
        case .askBack: return String(localized: "Ask back")
        case .assign: return String(localized: "Assign…")
        case .later: return String(localized: "Later")
        case .duplicate: return String(localized: "Is a duplicate")
        case .decline: return String(localized: "Decline")
        }
    }

    /// Was der Board-Chat tun soll.
    var instruction: String {
        switch self {
        case .accept: return String(localized: "accept")
        case .askBack: return String(localized: "ask back what is unclear")
        case .assign: return String(localized: "assign: ask me to whom")
        case .later: return String(localized: "later, bring it up again in two weeks")
        case .duplicate: return String(localized: "close as duplicate")
        case .decline: return String(localized: "decline with a short reason")
        }
    }
}

extension BoardChatText {
    /// `WM8` aus `WM8-112`.
    static func team(ofKey key: String) -> String {
        key.split(separator: "-").first.map(String.init) ?? key
    }

    static func triageHeader(team: String) -> String {
        String(localized: "Triage in \(team), please carry out:")
    }

    /// Eine Zeile je Entscheidung: Nummer, Titel, Adresse und was zu tun ist.
    /// Eine geänderte Entscheidung sagt, welche sie ersetzt.
    static func triageLine(_ ticket: BoardChatTicket, _ decision: TriageDecision, replacing old: TriageDecision?) -> String {
        var line = "- " + ticketLine(ticket) + ": " + decision.instruction
        if let old, old != decision { line += " " + String(localized: "(instead of: \(old.instruction))") }
        return line
    }

    /// Was ins Eingabefeld kommt. Die Überschrift nur am Anfang eines
    /// Sammelauftrags; steht schon eigener Text im Feld, auf neuer Zeile.
    static func triageInsert(_ ticket: BoardChatTicket, _ decision: TriageDecision, replacing old: TriageDecision?,
                             batchOpen: Bool, fieldHasText: Bool) -> String {
        let line = triageLine(ticket, decision, replacing: old)
        if batchOpen { return "\n" + line }
        return (fieldHasText ? "\n" : "") + triageHeader(team: team(ofKey: ticket.key)) + "\n" + line
    }
}

extension BoardChatInputs {
    func triageDecision(for key: String, in windowID: UUID) -> TriageDecision? {
        triageDecisions[windowID]?[key]
    }

    /// Hält eine Entscheidung zum Ticket der Triage fest und legt sie als Zeile
    /// ins Eingabefeld des Board-Chats, nie mit Enter. Ist das Feld seit dem
    /// letzten Sammeln leer (abgeschickt oder geleert), beginnt ein neuer
    /// Sammelauftrag mit Überschrift. Bei offener Frage oder Freigabe passiert
    /// nichts, auch keine Markierung.
    @discardableResult
    func decide(_ decision: TriageDecision, in windowID: UUID) -> Bool {
        guard let registration = registrations[windowID] else {
            refuse(.noBoardChat, in: windowID, name: "")
            return false
        }
        guard let ticket = shownTicket(windowID) else { return false }
        let sessionID = registration.sessionID
        if let refusal = BoardChatInputRules.refusal(state: chatState(sessionID), approvalPending: approvalPending(sessionID)) {
            refuse(refusal, in: windowID, name: registration.name)
            return false
        }
        let fieldHasText = hasUnsentInput(sessionID)
        if triageBatchOpen.contains(windowID), !fieldHasText {
            // Der letzte Sammelauftrag ist raus: neu anfangen.
            triageBatchOpen.remove(windowID)
            triageDecisions[windowID] = nil
        }
        let old = triageDecisions[windowID]?[ticket.key]
        let text = BoardChatText.triageInsert(ticket, decision, replacing: old,
                                               batchOpen: triageBatchOpen.contains(windowID), fieldHasText: fieldHasText)
        guard insert(text, sessionID) else {
            refuse(.notRunning, in: windowID, name: registration.name)
            return false
        }
        triageBatchOpen.insert(windowID)
        triageDecisions[windowID, default: [:]][ticket.key] = decision
        notices[windowID] = nil
        return true
    }
}
