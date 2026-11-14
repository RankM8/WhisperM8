import Foundation

/// Ticket-Ansicht je Fenster: Chats oder Tickets. Flüchtig, nur für diesen
/// App-Start; nach einem Neustart zeigt jedes Fenster wieder seine Chats.
///
/// Der Zustand liegt im Store, nicht in der View: Jede Navigation zu einem
/// Chat (Seitenleiste, Tab, Tastatur, Controller, CLI, „Zum Chat“ am Ticket)
/// läuft über `navigateToSession` und führt so von selbst zu den Chats zurück.
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
