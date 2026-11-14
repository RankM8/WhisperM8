import Foundation

// MARK: - Format der Verknüpfung Chat ↔ Ticket

/// Eine Verknüpfung ist ein Anhang am Ticket. Dieses Format teilen sich die
/// App, die Kommandozeile und das Übergangs-Skript `~/.claude/skills/linear/ticket`,
/// damit alle dieselben Verknüpfungen lesen und schreiben:
///
/// - Adresse `whisperm8://chat/<Sitzungs-ID>` (eindeutig je Chat und Ticket)
/// - Titel `Chat: <Titel des Chats>`
/// - Untertitel beginnt mit „arbeitet“ (Chat sitzt am Ticket) oder „beendet“
/// - Metadaten: `source = whisperm8`, `chatId`, `shortId`, `project`, `active`
///
/// Der Untertitel entscheidet über „aktiv“, weil sich im Werkzeug danach
/// filtern lässt (Ansichten „Mit Agent“ und „Ohne Agent“).
enum TicketChatLinkFormat {
    static let source = "whisperm8"
    static let urlPrefix = "whisperm8://chat/"
    static let activePrefix = "arbeitet"
    static let endedPrefix = "beendet"

    static func url(for chatID: UUID) -> String {
        urlPrefix + chatID.uuidString
    }

    static func chatID(fromURL url: String) -> UUID? {
        guard url.hasPrefix(urlPrefix) else { return nil }
        return UUID(uuidString: String(url.dropFirst(urlPrefix.count)))
    }

    static func isActive(subtitle: String) -> Bool {
        subtitle.hasPrefix(activePrefix)
    }

    static func title(for chat: TicketChat) -> String {
        "Chat: " + String(chat.title.prefix(120))
    }

    static func activeSubtitle(for chat: TicketChat, at date: Date, calendar: Calendar = .current) -> String {
        var parts = ["\(activePrefix) seit \(stamp(date, calendar: calendar))", "WhisperM8"]
        if !chat.projectName.isEmpty { parts.append(chat.projectName) }
        return parts.joined(separator: " · ")
    }

    static func endedSubtitle(at date: Date, calendar: Calendar = .current) -> String {
        "\(endedPrefix) am \(stamp(date, calendar: calendar)) · WhisperM8"
    }

    static func metadata(for chat: TicketChat, active: Bool, at date: Date) -> [String: Any] {
        [
            "source": source,
            "chatId": chat.id.uuidString,
            "shortId": String(chat.id.uuidString.prefix(8)).lowercased(),
            "project": chat.projectName,
            "active": active,
            "since": ISO8601DateFormatter().string(from: date),
        ]
    }

    /// Liest `since` aus den Metadaten. Die App schreibt mit Zeitzone; das
    /// Übergangs-Skript schrieb Ortszeit ohne Zone (`2026-11-14T00:51:00`).
    static func date(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: raw)
    }

    /// `14.11. 00:51`, bewusst ohne Jahr und ohne Sprachabhängigkeit.
    static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        return String(format: "%02d.%02d. %02d:%02d", c.day ?? 0, c.month ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
