import Foundation

/// Detail einer geplanten Aufgabe im Inhaltsbereich (WM8-110, Paket 2). Wie die
/// Ticket-Ansicht flüchtig und je Fenster: Jede Navigation zu einem Chat oder
/// Workspace schließt es (`leaveTicketsForNavigation`), die Ticket-Ansicht auch.
extension AgentWindowStore {
    func scheduledTaskDetail(in windowID: UUID) -> UUID? {
        scheduledTaskDetailIDs[windowID]
    }

    /// Klick auf eine Aufgabe im Abschnitt „Geplant“.
    func showScheduledTask(_ taskID: UUID, in windowID: UUID) {
        setTicketsMode(false, in: windowID)
        // Nur schreiben, wenn sich etwas ändert: Das Fenster liest den Wert im Body.
        guard scheduledTaskDetailIDs[windowID] != taskID else { return }
        scheduledTaskDetailIDs[windowID] = taskID
    }

    /// Verdeckt etwas den gewählten Chat (Tickets oder Detail einer geplanten
    /// Aufgabe)? Dann dürfen ⌘W, Controller, Diktat und die Statuszeile ihn
    /// nicht ungesehen treffen (Prüfung WM8-110, M1/M2/K7).
    func hidesChatContent(in windowID: UUID) -> Bool {
        isTicketsMode(in: windowID) || scheduledTaskDetail(in: windowID) != nil
    }

    func closeScheduledTask(in windowID: UUID) {
        guard scheduledTaskDetailIDs[windowID] != nil else { return }
        scheduledTaskDetailIDs[windowID] = nil
    }
}
