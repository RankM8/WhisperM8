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
    /// Konto, an dem das Limit hing (`claudeProfileName`, `nil` = main als
    /// `"main"`). Der Koordinator stempelt es beim ersten Erkennen; nach einem
    /// Kontowechsel gilt das Limit für den Chat nicht mehr (Review H3).
    var account: String? = nil
    /// Sperrt das Limit das ganze Konto (5 Stunden, Woche)? Das Guthaben-Limit
    /// für ein Modell (`kind` = `model_requires_usage_credits`) nicht: ein
    /// anderes Modell kann weiterlaufen.
    var isAccountWide: Bool { kind != "model_requires_usage_credits" }

    /// Gilt das Limit noch? Ohne bekanntes Ende: ja, bis der Verlauf
    /// weitergeht.
    func isActive(at now: Date = Date()) -> Bool {
        guard let resetsAt else { return true }
        return resetsAt > now
    }

    init(resetsAt: Date?, kind: String, since: Date?, autoContinues: Bool? = nil, account: String? = nil) {
        self.resetsAt = resetsAt
        self.kind = kind
        self.since = since
        self.autoContinues = autoContinues
        self.account = account
    }

    /// Wie `init?(event:)`, dazu aus den System-Zeilen nach der Limit-Zeile,
    /// ob Claude von selbst weitermacht.
    init?(event: AgentTranscriptEvent?, tail: String) {
        self.init(event: event)
        autoContinues = Self.autoContinueState(inTail: tail)
    }

    /// Pur: das Limit nach einem Tail-Read. Nur eine Antwort von Claude
    /// (ohne Fehler), ein Abbruch oder ein offener Aufruf beendet es. Zeilen
    /// vom Typ `user` (Teammate-Nachrichten, Task-Meldungen, eine Nachricht an
    /// den Chat) nicht: Claude antwortet darauf gleich mit der nächsten
    /// Limit-Zeile, das Limit würde sonst flattern (Review M2).
    static func after(event: AgentTranscriptEvent?, tail: String, cached: AgentUsageLimit?) -> AgentUsageLimit? {
        guard let event else { return cached }
        if let fresh = AgentUsageLimit(event: event, tail: tail) { return fresh }
        switch event {
        case .userMessage, .toolResult, .sessionMeta, .meta, .other:
            return cached
        case .assistantMessageStopped, .assistantMessageOngoing, .turnInterrupted, .toolCallPending, .usageLimit:
            return nil
        }
    }

    static func accountKey(_ profileName: String?) -> String { profileName ?? "main" }

    /// Pur: das jüngste noch laufende Limit eines Kontos, gesehen an irgendeinem
    /// seiner Chats (Konto-Stempel). So erfährt auch ein Chat, der ruhte, als
    /// sein Konto ans Limit kam, davon (Vorfall 14.11.2026, Dex).
    static func onAccount(_ account: String, in sessions: [AgentChatSession], now: Date = Date()) -> AgentUsageLimit? {
        sessions.compactMap(\.usageLimit)
            .filter { $0.account == account && $0.isActive(at: now) }
            .max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    /// Ist der Prompt ein Slash-Befehl (`/login`, `/model opus`,
    /// `/rate-limit-options`)? Ein Pfad wie `/Users/…` ist keiner (Review C).
    static func isSlashCommand(_ prompt: String) -> Bool {
        let first = prompt.drop(while: \.isWhitespace).prefix { !$0.isWhitespace }
        guard first.count > 1, first.first == "/" else { return false }
        let word = first.dropFirst()
        guard let lead = word.first, lead.isLetter else { return false }
        return word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
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

extension AgentChatSession {
    /// Das Limit, das für diesen Chat jetzt gilt: noch nicht abgelaufen und
    /// am aktuellen Konto (nach einem Kontowechsel nicht mehr).
    func activeUsageLimit(at now: Date = Date()) -> AgentUsageLimit? {
        guard let limit = usageLimit, limit.isActive(at: now) else { return nil }
        if let account = limit.account, account != AgentUsageLimit.accountKey(claudeProfileName) { return nil }
        return limit
    }

    /// Was einen Prompt an diesen Chat jetzt aufhält: das eigene Limit, sonst
    /// ein kontoweites Limit, gesehen an einem anderen Chat desselben Kontos
    /// (5 Stunden, Woche). Das Guthaben-Limit eines anderen Chats gilt nur für
    /// dessen Modell und hält hier nicht auf (siehe `usageLimitWarning`).
    func blockingUsageLimit(in sessions: [AgentChatSession], now: Date = Date()) -> AgentUsageLimit? {
        if let own = activeUsageLimit(at: now) { return own }
        guard provider == .claude,
              let shared = AgentUsageLimit.onAccount(AgentUsageLimit.accountKey(claudeProfileName), in: sessions, now: now),
              shared.isAccountWide else { return nil }
        return shared
    }

    /// Ein Guthaben-Limit an einem anderen Chat desselben Kontos: nur warnen,
    /// es gilt vielleicht nicht für das Modell dieses Chats.
    func usageLimitWarning(in sessions: [AgentChatSession], now: Date = Date()) -> AgentUsageLimit? {
        guard provider == .claude, activeUsageLimit(at: now) == nil,
              let shared = AgentUsageLimit.onAccount(AgentUsageLimit.accountKey(claudeProfileName), in: sessions, now: now),
              !shared.isAccountWide else { return nil }
        return shared
    }
}
