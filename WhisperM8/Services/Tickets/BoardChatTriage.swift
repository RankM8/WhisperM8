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

/// Sammelauftrag der Triage: an welchen Chat, ob die Überschrift schon im
/// Feld steht, und was je Ticket gesammelt ist.
struct TriageBatch: Equatable {
    var sessionID: UUID
    var decisions: [String: TriageDecision] = [:]
    /// Stand von `fieldResets` beim Beginn des Auftrags; `nil` ohne Terminal.
    var fieldResetsAtStart: Int? = nil
}

/// Was der Bildschirm über das Eingabefeld sagt.
enum BoardChatFieldVisibility: Equatable {
    case empty
    case hasText
    /// Hochgescrollt, eingeklappter Paste, Codex: nicht ablesbar.
    case unknown
}

enum TriageBatchRules {
    /// Ist der letzte Sammelauftrag raus? Sichtbar leeres Feld: ja. Sichtbarer
    /// Text: nein. Sonst die Schätzung der Tasten (wie die Warteschlange).
    static func batchEnded(field: BoardChatFieldVisibility, hasUnsentInput: Bool,
                           resetsAtStart: Int? = nil, resetsNow: Int? = nil) -> Bool {
        // Seit Beginn abgeschickt oder geleert: raus, auch wenn schon wieder
        // neuer Text im Feld steht (der gehört dann nicht zum Auftrag).
        if let resetsAtStart, let resetsNow, resetsNow != resetsAtStart { return true }
        switch field {
        case .empty: return true
        case .hasText: return false
        case .unknown: return !hasUnsentInput
        }
    }

    /// Nach einem Klick springt die Triage weiter; ein zweiter Klick so kurz
    /// danach entschiede ein Ticket, das Giuliano noch nicht gesehen hat.
    static let doubleClickPause: TimeInterval = 0.5
}

extension BoardChatInputs {
    func triageDecision(for key: String, in windowID: UUID) -> TriageDecision? {
        guard let batch = triageBatches[windowID], batch.sessionID == registrations[windowID]?.sessionID else { return nil }
        return batch.decisions[key]
    }

    /// Hält eine Entscheidung zum Ticket der Triage fest und legt sie als Zeile
    /// ins Eingabefeld des Board-Chats, nie mit Enter. Ist der letzte
    /// Sammelauftrag raus oder steht ein anderer Chat in der Spalte, beginnt ein
    /// neuer mit Überschrift. Bei offener Frage oder Freigabe passiert nichts,
    /// auch keine Markierung.
    @discardableResult
    func decide(_ decision: TriageDecision, in windowID: UUID) -> Bool {
        guard let registration = registrations[windowID] else {
            refuse(.noBoardChat, in: windowID, name: "")
            return false
        }
        // Doppelklick: der zweite Klick träfe das nächste, ungesehene Ticket.
        if let last = lastDecisionAt[windowID], now().timeIntervalSince(last) < TriageBatchRules.doubleClickPause { return false }
        guard let ticket = shownTicket(windowID) else { return false }
        let sessionID = registration.sessionID
        if let refusal = BoardChatInputRules.refusal(state: chatState(sessionID), approvalPending: approvalPending(sessionID)) {
            refuse(refusal, in: windowID, name: registration.name)
            return false
        }
        let field = fieldVisibility(sessionID)
        let unsent = hasUnsentInput(sessionID)
        let resets = fieldResets(sessionID)
        if let batch = triageBatches[windowID],
           batch.sessionID != sessionID
            || TriageBatchRules.batchEnded(field: field, hasUnsentInput: unsent,
                                           resetsAtStart: batch.fieldResetsAtStart, resetsNow: resets) {
            // Anderer Chat oder der letzte Auftrag ist raus: neu anfangen, alte Marken weg.
            triageBatches[windowID] = nil
        }
        let batch = triageBatches[windowID]
        let fieldHasText = field == .hasText || (field == .unknown && unsent)
        let text = BoardChatText.triageInsert(ticket, decision, replacing: batch?.decisions[ticket.key],
                                               batchOpen: batch != nil, fieldHasText: fieldHasText)
        guard insert(text, sessionID) else {
            refuse(.notRunning, in: windowID, name: registration.name)
            return false
        }
        var updated = batch ?? TriageBatch(sessionID: sessionID, fieldResetsAtStart: resets)
        updated.decisions[ticket.key] = decision
        triageBatches[windowID] = updated
        lastDecisionAt[windowID] = now()
        notices[windowID] = nil
        return true
    }
}
