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
        /// Liest die App das Feld dieses Chats am Bildschirm ab? Nur bei
        /// Claude. Bei Codex (und Shell-Tabs) gibt allein Enter, Ctrl+C oder
        /// ein Absenden frei; ein von Hand gelöschtes Feld sieht die App dort
        /// nicht, deshalb ein eigener zweiter Satz.
        var fieldReadable: Bool = true
    }

    private(set) var notices: [UUID: Notice] = [:]

    func set(_ notice: Notice?, for sessionID: UUID) {
        let value = notice.flatMap { $0.count > 0 ? $0 : nil }
        // Nur bei echter Änderung schreiben: Jede Zuweisung weckt die Pille.
        guard notices[sessionID] != value else { return }
        notices[sessionID] = value
    }

    func clear(_ sessionID: UUID) {
        set(nil, for: sessionID)
    }

    /// Pur: Hinweis, nachdem sich die Zahl offener Meldungen geändert hat
    /// (etwa per `chats dequeue`). Nichts mehr offen heißt: keine Pille.
    /// Ohne bisherigen Hinweis bleibt es dabei; ob neu gewartet wird,
    /// entscheidet erst der nächste Zustellversuch.
    nonisolated static func notice(_ current: Notice?, afterOpenCount openCount: Int) -> Notice? {
        guard var current, openCount > 0 else { return nil }
        current.count = openCount
        return current
    }

    /// Text der Pille, z. B. „1 Meldung wartet: Text im Eingabefeld“.
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
    nonisolated static func hint(for notice: Notice) -> String {
        switch (notice.reason, notice.fieldReadable) {
        case (.textInField, true):
            return String(localized: "Sent once the text is submitted or cleared and the terminal is scrolled to the bottom.")
        case (.textInField, false):
            return String(localized: "Sent once you press Enter or Ctrl+C in the terminal. The input field can't be read here, so deleting the text by hand doesn't count.")
        case (.viewOpen, _):
            return String(localized: "Sent once the view is closed.")
        }
    }
}
