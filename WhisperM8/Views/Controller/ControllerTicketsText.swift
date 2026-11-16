import Foundation

/// Texte rund um das Ticket-Board am Controller (WM8-91).
enum ControllerTicketsText {
    /// Ort in Leiste und Inselkopf: „Tickets · WM8“, ohne bekanntes Team nur „Tickets“.
    static func placeTitle(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return String(localized: "Tickets") }
        return String(localized: "Tickets · \(label)")
    }
}
