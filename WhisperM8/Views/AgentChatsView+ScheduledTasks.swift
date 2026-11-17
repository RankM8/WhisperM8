import SwiftUI

/// Abschnitt „Geplant“ in der Seitenleiste und Detail einer Aufgabe im
/// Inhaltsbereich (WM8-110, Paket 2). Beide nur bei eingeschaltetem
/// Labs-Schalter; der Abschnitt blendet sich selbst aus.
extension AgentChatsView {
    /// Aufgabe, deren Detail dieses Fenster zeigt.
    var scheduledTaskDetailID: UUID? {
        windowStore.scheduledTaskDetail(in: windowID)
    }

    /// Tickets oder Aufgaben-Detail verdecken den gewählten Chat.
    var hidesChatContent: Bool {
        windowStore.hidesChatContent(in: windowID)
    }

    /// Kosten je Auswertung des Fensters: eine Wörterbuch-Abfrage und die
    /// schon gerechnete Auswahl; der Abschnitt selbst rechnet nur neu, wenn
    /// sich eine der beiden Markierungen ändert (`.equatable()`).
    var scheduledTasksSidebarSection: some View {
        ScheduledTasksSidebarSection(
            selectedTaskID: scheduledTaskDetailID,
            selectedRunSessionID: selectedSession?.externalSessionID?.lowercased(),
            projects: { scheduledTaskEditorProjects },
            onSelectTask: { [windowStore, windowID] in windowStore.showScheduledTask($0, in: windowID) },
            onOpenRun: { openScheduledRunChat($0) }
        )
        .equatable()
    }

    func scheduledTaskDetail(_ taskID: UUID) -> some View {
        ScheduledTaskDetailView(
            taskID: taskID,
            projects: { scheduledTaskEditorProjects },
            onClose: { [windowStore, windowID] in windowStore.closeScheduledTask(in: windowID) },
            onOpenRun: { openScheduledRunChat($0) }
        )
        .equatable()
        // Meldung, „busy“ und Blatt gehören zu genau dieser Aufgabe.
        .id(taskID)
    }

    /// Projekte der Seitenleiste als Auswahl für den Projektordner, nach Namen.
    var scheduledTaskEditorProjects: [ScheduledTaskEditorProject] {
        workspace.projects
            .map { ScheduledTaskEditorProject(name: $0.name, path: $0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Öffnet den Chat eines Laufs wie ein Klick in der Chat-Liste. Den Chat
    /// findet die App erst, wenn der Indexer ihn eingelesen hat; vorher stößt
    /// der Klick einen Scan an und meldet `false`.
    func openScheduledRunChat(_ sessionID: UUID) -> Bool {
        let external = sessionID.uuidString.lowercased()
        guard let session = workspace.sessions.first(where: { $0.externalSessionID?.lowercased() == external }) else {
            AgentScanCoordinator.shared.requestScan(reason: .manual)
            return false
        }
        selectedProjectID = session.projectID
        expandedProjectIDs.insert(session.projectID)
        // Navigiert über den Store und schließt dabei das Detail (`leaveTicketsForNavigation`).
        selectedSessionID = session.id
        return true
    }
}
