import Foundation
import Observation

/// Sichtbarer Hinweis am Chat, wenn Meldungen aus der Warteschlange warten,
/// weil Text im Eingabefeld steht oder eine Ansicht von Claude offen ist
/// (WM8-123). Sonst stand eine Schlange still, ohne dass es jemand merkte.
///
/// Nur Speicher, kein I/O. Gesetzt und gelöscht von der Warteschlange
/// (`AgentPromptQueueDelivery`); gelesen nur von `QueueHoldStrip` über dem
/// Terminal des Chats. Die Seitenleiste liest es nicht, die Status-Punkte
/// bleiben unberührt.
@MainActor
@Observable
final class QueueHoldNotices {
    static let shared = QueueHoldNotices()

    enum Reason: Equatable {
        /// Getippter oder eingefügter, nicht abgeschickter Text im Feld.
        case textInField
        /// Transkript, `/tasks`, Agent-Liste, `/config` und Ähnliches.
        case viewOpen
    }

    struct Notice: Equatable {
        var count: Int
        var reason: Reason
    }

    private(set) var notices: [UUID: Notice] = [:]

    func set(_ notice: Notice?, for sessionID: UUID) {
        let value = notice.flatMap { $0.count > 0 ? $0 : nil }
        // Nur bei echter Änderung schreiben: Jede Zuweisung weckt die Leiste.
        guard notices[sessionID] != value else { return }
        notices[sessionID] = value
    }

    func clear(_ sessionID: UUID) {
        set(nil, for: sessionID)
    }

    /// Text der Leiste, z. B. „1 Meldung wartet: Text im Eingabefeld“.
    nonisolated static func text(for notice: Notice) -> String {
        switch (notice.reason, notice.count == 1) {
        case (.textInField, true):
            return String(localized: "1 message waiting: text in input field")
        case (.textInField, false):
            return String(localized: "\(notice.count) messages waiting: text in input field")
        case (.viewOpen, true):
            return String(localized: "1 message waiting: a Claude view is open")
        case (.viewOpen, false):
            return String(localized: "\(notice.count) messages waiting: a Claude view is open")
        }
    }

    /// Zweite Zeile: was die Meldung frei macht.
    nonisolated static func hint(for reason: Reason) -> String {
        switch reason {
        case .textInField:
            return String(localized: "Sent once the text is submitted or cleared and the terminal is scrolled to the bottom.")
        case .viewOpen:
            return String(localized: "Sent once the view is closed.")
        }
    }
}
