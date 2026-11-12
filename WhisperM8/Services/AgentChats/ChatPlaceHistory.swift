import Foundation

/// Ein Ort im Fenster, zu dem L2 am Controller zurückführt: ein einzelner
/// Chat oder ein Workspace in der Rasteransicht.
enum ChatPlace: Hashable {
    case chat(UUID)
    case workspace(UUID)

    /// Ort eines Fensters aus seinem Zustand.
    ///
    /// Raster sichtbar: der Workspace — ein Fokuswechsel zwischen Kacheln ist
    /// kein Ortswechsel. Einzelansicht eines Chats, der zum gemerkten Workspace
    /// gehört (Kachel groß per L3, Mini-Map), zählt ebenfalls als dieser
    /// Workspace: L3 führt von dort zurück ins Raster. Jeder andere Chat in der
    /// Einzelansicht ist ein eigener Ort; ohne Auswahl gibt es keinen.
    /// - Parameter workspaceID: Workspace, den das Fenster referenziert
    ///   (Raster oder Rücksprungziel der Einzelansicht), sofern es ihn gibt.
    static func of(
        selectedSessionID: UUID?,
        showsGrid: Bool,
        workspaceID: UUID?,
        isWorkspaceMember: (UUID) -> Bool
    ) -> ChatPlace? {
        if let workspaceID {
            if showsGrid { return .workspace(workspaceID) }
            if let selectedSessionID, isWorkspaceMember(selectedSessionID) { return .workspace(workspaceID) }
        }
        return selectedSessionID.map(ChatPlace.chat)
    }
}

/// Merkt sich den aktuellen und den vorigen Ort eines Fensters, für
/// „zurück dorthin, wo ich vorher war“ (wie ein kurzes Alt-Tab).
///
/// Pur: Ob ein Ort noch existiert, entscheidet der Aufrufer — beim Festhalten
/// und beim Abfragen.
struct ChatPlaceHistory: Equatable {
    private(set) var current: ChatPlace?
    private(set) var previous: ChatPlace?

    /// Neuen Ort festhalten. Derselbe Ort noch einmal ändert nichts; ohne Ort
    /// (keine Auswahl) bleibt der vorige als Rücksprungziel.
    ///
    /// Gibt es den bisherigen Ort nicht mehr (Chat geschlossen, Workspace
    /// gelöscht), wird er nicht zum Rücksprungziel: Nach dem Schließen führt
    /// L2 dorthin, wo man davor war, statt ins Leere.
    mutating func record(_ place: ChatPlace?, isAvailable: (ChatPlace) -> Bool) {
        guard place != current else { return }
        if let current, isAvailable(current) { previous = current }
        current = place
    }

    /// Ziel für „zurück“, oder `nil`, wenn es keins (mehr) gibt.
    func target(isAvailable: (ChatPlace) -> Bool) -> ChatPlace? {
        guard let previous, previous != current, isAvailable(previous) else { return nil }
        return previous
    }
}

/// Veränderlicher Zustand eines Fensters rund um Befehle, als Klasse im
/// `@State` der View: ein Eintrag in der großen Datei, und Änderungen lösen
/// keinen Neuaufbau aus (bewusst nicht beobachtet). Den Verlauf der Orte
/// führt der `AgentWindowStore` je Fenster.
@MainActor
final class AgentChatsCommandState {
    var token: AgentChatsCommandCenter.Token?
    /// Projekt, das die Projekt-Auswahl „Neuer Chat“ beim nächsten Öffnen
    /// vorauswählt (Controller: Create). Wird beim Öffnen verbraucht, damit
    /// ⌘N danach wieder beim ersten Projekt beginnt.
    var preferredNewChatProjectID: UUID?

    func takePreferredNewChatProjectID() -> UUID? {
        defer { preferredNewChatProjectID = nil }
        return preferredNewChatProjectID
    }
}
