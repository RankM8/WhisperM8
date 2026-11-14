import Foundation

/// Ticket-Ansicht je Fenster: Chats oder Tickets. Flüchtig, nur für diesen
/// App-Start; nach einem Neustart zeigt jedes Fenster wieder seine Chats.
///
/// Der Zustand liegt im Store, nicht in der View: Alles, was einen Chat oder
/// einen Workspace zeigen soll, führt von selbst zu den Chats zurück
/// (`navigateToSession`, `showSingleSession…`, `openTab(select:)`,
/// `setSelectedSession`, `activateGridWorkspace`). Das gilt auch für einen
/// Chat, den die CLI im Hintergrund startet oder fortsetzt: Er startet erst,
/// wenn seine Ansicht im Fenster steht. Eine Auswahl, die nur nachrückt (Tab
/// geschlossen, Chat archiviert), lässt die Tickets stehen.
extension AgentWindowStore {
    func isTicketsMode(in windowID: UUID) -> Bool {
        ticketsModeWindowIDs.contains(windowID)
    }

    func setTicketsMode(_ active: Bool, in windowID: UUID) {
        // Nur schreiben, wenn sich etwas ändert: Sonst wertete jede
        // Navigation die Ansichten neu aus, die den Modus lesen.
        guard ticketsModeWindowIDs.contains(windowID) != active else { return }
        if active {
            ticketsModeWindowIDs.insert(windowID)
        } else {
            ticketsModeWindowIDs.remove(windowID)
        }
    }
}
