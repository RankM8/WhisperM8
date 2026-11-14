import Foundation

/// Ticket-Ansicht je Fenster: Chats oder Tickets. Flüchtig, nur für diesen
/// App-Start; nach einem Neustart zeigt jedes Fenster wieder seine Chats.
///
/// Der Zustand liegt im Store, nicht in der View: Alles, was einen Chat oder
/// einen Workspace zeigen soll, führt von selbst zu den Chats zurück
/// (`navigateToSession`, `showSingleSession…`, `openTab(select:)`,
/// `setSelectedSession`, `activateGridWorkspace`). Eine Auswahl, die nur
/// nachrückt (Tab geschlossen, Chat archiviert), lässt die Tickets stehen.
///
/// Eine Auswahl aus dem Steuerkanal (`whisperm8 chats …`) lässt die Tickets
/// ebenfalls stehen (`keepingTicketsMode`): Wer das Board liest, soll nicht
/// herausfliegen, weil ein Supervisor einen Chat öffnet. Ausnahme ist ein
/// Chat, der erst starten muss: Er startet nur, wenn seine Ansicht im Fenster
/// steht, also zeigt das Fenster ihn.
extension AgentWindowStore {
    func isTicketsMode(in windowID: UUID) -> Bool {
        ticketsModeWindowIDs.contains(windowID)
    }

    /// Der Nutzer schaltet um (Knopf, ⌘W), oder der Schalter ging aus.
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

    /// Eine Navigation will einen Chat oder Workspace zeigen.
    func leaveTicketsForNavigation(in windowID: UUID) {
        guard ticketsModeHoldDepth == 0 else { return }
        setTicketsMode(false, in: windowID)
    }

    /// Das Fenster ist geschlossen: Modus und Controller der Ticket-Ansicht
    /// (samt letztem Abzug) werden freigegeben.
    func forgetTickets(of windowID: UUID) {
        ticketsModeWindowIDs.remove(windowID)
        TicketBoardControllers.shared.forget(windowID)
    }

    /// Führt eine Navigation aus, ohne dass ein Fenster die Tickets verlässt.
    func keepingTicketsMode<T>(_ navigation: () throws -> T) rethrows -> T {
        ticketsModeHoldDepth += 1
        defer { ticketsModeHoldDepth -= 1 }
        return try navigation()
    }
}
