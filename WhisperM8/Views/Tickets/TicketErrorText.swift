import Foundation

// MARK: - Fehler des Ticket-Systems als Text für die Oberfläche

extension TicketSourceError {
    /// Übersetzter Satz für Einstellungen und Ticket-Ansicht. Die Meldungen der
    /// Kommandozeile (`message`) nennen Befehle und sind deutsch; hier steht,
    /// was der Nutzer in der App tun kann. Nie mit Schlüsseln.
    var userText: String {
        switch self {
        case .notConfigured:
            return String(localized: "No Linear key saved for this workspace.")
        case .unauthorized:
            return String(localized: "Linear rejected the key. It may have been deleted in Linear.")
        case .rateLimited:
            return String(localized: "Linear's request limit is reached. Try again later.")
        case .network:
            return String(localized: "Linear is not reachable. Check the connection.")
        case .notFound(let what):
            return String(localized: "\(what) does not exist in Linear.")
        case .rejected(let detail):
            return String(localized: "Linear declined the request: \(detail)")
        case .invalidResponse:
            return String(localized: "Linear sent an answer WhisperM8 could not read.")
        case .ambiguous(let detail):
            return detail
        }
    }
}
