import Foundation

/// Merkt sich die aktuelle und die vorige Chat-Auswahl eines Fensters, für
/// „zurück zum letzten Chat“ (wie ein kurzes Alt-Tab).
///
/// Pur: Ob ein gemerkter Chat noch existiert, entscheidet der Aufrufer beim
/// Abfragen — sonst würde ein inzwischen geschlossener oder archivierter Chat
/// wieder geöffnet.
struct ChatSelectionHistory: Equatable {
    private(set) var current: UUID?
    private(set) var previous: UUID?

    /// Neue Auswahl festhalten. Dieselbe Auswahl noch einmal ändert nichts;
    /// eine leere Auswahl behält den vorigen Chat als Rücksprungziel.
    mutating func record(_ selection: UUID?) {
        guard selection != current else { return }
        if let current { previous = current }
        current = selection
    }

    /// Ziel für „letzter Chat“, oder `nil`, wenn es keins (mehr) gibt.
    func lastChat(isAvailable: (UUID) -> Bool) -> UUID? {
        guard let previous, previous != current, isAvailable(previous) else { return nil }
        return previous
    }
}

/// Veränderlicher Zustand eines Fensters rund um Befehle, als Klasse im
/// `@State` der View: ein Eintrag in der großen Datei, und Änderungen lösen
/// keinen Neuaufbau aus (bewusst nicht beobachtet).
@MainActor
final class AgentChatsCommandState {
    var token: AgentChatsCommandCenter.Token?
    var history = ChatSelectionHistory()
    /// Der laufende Umschalter wurde ohne Ctrl geöffnet (Controller). Das
    /// Loslassen von Ctrl darf ihn dann nicht bestätigen.
    var switcherOpenedWithoutModifier = false
}
