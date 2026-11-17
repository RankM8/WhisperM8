import Foundation

/// Was der Store über das Ticket-Board als Ort weiß (WM8-91): das zuletzt
/// gezeigte Board je Fenster und ob die Ticket-Ansicht eingeschaltet ist.
/// Flüchtig und nicht beobachtet.
struct TicketPlaceMemory {
    /// Zuletzt gezeigtes Board je Fenster (Projekt), für „vorher“ im Reiter
    /// „Tickets“ der Insel.
    var lastProjectIDs: [UUID: UUID] = [:]
    /// Ist die Ticket-Ansicht eingeschaltet? Sonst ist das Board kein Ziel
    /// für L2. Tests ersetzen das.
    var isBoardEnabled: () -> Bool = { UserDefaults.standard.bool(forKey: PreferenceKeys.ticketBoardEnabled) }
}

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
        if active { closeScheduledTask(in: windowID) }
        // Nur schreiben, wenn sich etwas ändert: Sonst wertete jede
        // Navigation die Ansichten neu aus, die den Modus lesen.
        guard ticketsModeWindowIDs.contains(windowID) != active else { return }
        // Ein Ortswechsel für L2 (WM8-91): Board ↔ Chat bzw. Workspace dahinter.
        // Erst der Ort davor (stand nach einer Navigation ohne Änderung des
        // Zustands noch „kein Ort“), dann der neue.
        recordPlace(of: windowID)
        setTicketsModeFlag(active, in: windowID)
        recordPlace(of: windowID)
    }

    /// Eine Navigation will einen Chat oder Workspace zeigen.
    func leaveTicketsForNavigation(in windowID: UUID) {
        guard ticketsModeHoldDepth == 0 else { return }
        // Auch das Detail einer geplanten Aufgabe weicht dem Chat oder Workspace.
        closeScheduledTask(in: windowID)
        guard ticketsModeWindowIDs.contains(windowID) else { return }
        setTicketsModeFlag(false, in: windowID)
        // Der neue Ort kommt mit der Navigation; bis dahin bleibt das Board
        // das Rücksprungziel (nicht der Chat dahinter).
        recordLeavingTickets(in: windowID)
    }

    private func setTicketsModeFlag(_ active: Bool, in windowID: UUID) {
        if active {
            ticketsModeWindowIDs.insert(windowID)
        } else {
            ticketsModeWindowIDs.remove(windowID)
        }
    }

    /// Das Fenster ist geschlossen: Modus und Controller der Ticket-Ansicht
    /// (samt letztem Abzug) werden freigegeben.
    func forgetTickets(of windowID: UUID) {
        ticketsModeWindowIDs.remove(windowID)
        scheduledTaskDetailIDs[windowID] = nil
        ticketPlaces.lastProjectIDs[windowID] = nil
        TicketBoardControllers.shared.forget(windowID)
    }

    /// Führt eine Navigation aus, ohne dass ein Fenster die Tickets verlässt.
    func keepingTicketsMode<T>(_ navigation: () throws -> T) rethrows -> T {
        ticketsModeHoldDepth += 1
        defer { ticketsModeHoldDepth -= 1 }
        return try navigation()
    }
}
