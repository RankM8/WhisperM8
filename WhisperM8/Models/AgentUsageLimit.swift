import Foundation

/// Ein Chat am Nutzungslimit seines Kontos (WM8-69): bis wann und welches
/// Limit. Abgeleitet aus der Limit-Zeile im Verlauf, am Chat gespeichert,
/// solange sie die letzte Antwort ist.
struct AgentUsageLimit: Codable, Equatable, Hashable {
    /// Ende laut Claude; `nil`, wenn die Zeile keins nennt.
    var resetsAt: Date?
    /// `five_hour`, `seven_day`, `model_requires_usage_credits`, …
    var kind: String
    /// Zeitstempel der Limit-Zeile (macht die Angabe eindeutig, ohne bei
    /// jedem Poll eine neue zu erzeugen).
    var since: Date?

    /// Gilt das Limit noch? Ohne bekanntes Ende: ja, bis der Verlauf
    /// weitergeht.
    func isActive(at now: Date = Date()) -> Bool {
        guard let resetsAt else { return true }
        return resetsAt > now
    }

    init(resetsAt: Date?, kind: String, since: Date?) {
        self.resetsAt = resetsAt
        self.kind = kind
        self.since = since
    }

    /// Aus dem letzten Ereignis des Verlaufs; `nil`, wenn es kein Limit ist.
    init?(event: AgentTranscriptEvent?) {
        guard case .usageLimit(let timestamp, let resetsAt, let kind) = event else { return nil }
        self.init(resetsAt: resetsAt, kind: kind, since: timestamp)
    }
}
