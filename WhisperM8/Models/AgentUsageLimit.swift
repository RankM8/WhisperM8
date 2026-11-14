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
    /// Macht Claude zum Ende von selbst weiter („continuing automatically
    /// at …“)? Belegt in den Verläufen vom 11.–14.11.2026: Claude bietet es
    /// fast immer an, bricht es aber ab, sobald eine neue Nachricht kommt
    /// („Automatic continue cancelled“). Ungestört schreibt Claude zum Ende
    /// selbst „Your claude.ai usage limit has reset. Continue the task …“.
    /// `nil` = unbekannt.
    var autoContinues: Bool? = nil

    /// Gilt das Limit noch? Ohne bekanntes Ende: ja, bis der Verlauf
    /// weitergeht.
    func isActive(at now: Date = Date()) -> Bool {
        guard let resetsAt else { return true }
        return resetsAt > now
    }

    init(resetsAt: Date?, kind: String, since: Date?, autoContinues: Bool? = nil) {
        self.resetsAt = resetsAt
        self.kind = kind
        self.since = since
        self.autoContinues = autoContinues
    }

    /// Wie `init?(event:)`, dazu aus den System-Zeilen nach der Limit-Zeile,
    /// ob Claude von selbst weitermacht.
    init?(event: AgentTranscriptEvent?, tail: String) {
        self.init(event: event)
        autoContinues = Self.autoContinueState(inTail: tail)
    }

    static let autoContinueArmedMarker = "continuing automatically at"
    static let autoContinueCancelledMarker = "Automatic continue cancelled"

    /// Pur: die jüngste Aussage nach der letzten Limit-Zeile. Abgebrochen
    /// schlägt angeboten; keine Aussage → `nil`.
    static func autoContinueState(inTail tail: String) -> Bool? {
        for line in tail.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).reversed() {
            if line.contains("\"usage_limit_reached\"") || line.contains("\"model_requires_usage_credits\"") {
                return nil // bis zur Limit-Zeile keine Aussage
            }
            guard line.contains("\"system\"") else { continue }
            if line.contains(autoContinueCancelledMarker) { return false }
            if line.contains(autoContinueArmedMarker) { return true }
        }
        return nil
    }

    /// Aus dem letzten Ereignis des Verlaufs; `nil`, wenn es kein Limit ist.
    init?(event: AgentTranscriptEvent?) {
        guard case .usageLimit(let timestamp, let resetsAt, let kind) = event else { return nil }
        self.init(resetsAt: resetsAt, kind: kind, since: timestamp)
    }
}
