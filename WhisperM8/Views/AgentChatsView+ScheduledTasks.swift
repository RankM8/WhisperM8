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

    /// Fest unten in der Seitenleiste, über der Fußzeile (Entscheidung 17.11.2026).
    /// Kosten je Auswertung des Fensters: eine Wörterbuch-Abfrage und die
    /// schon gerechnete Auswahl; der Abschnitt selbst rechnet nur neu, wenn
    /// sich eine der Markierungen oder die Höhe der Seitenleiste ändert (`.equatable()`).
    var scheduledTasksSidebarSection: some View {
        ScheduledTasksSidebarSection(
            selectedTaskID: scheduledTaskDetailID,
            selectedRunSessionID: selectedSession?.externalSessionID?.lowercased(),
            maxListHeight: ScheduledTasksSidebarSection.maxListHeight(sidebarHeight: sidebarHeight),
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
        // Detail auf oder zu (Prüfung WM8-110, K-A): Diktat-Ziel und Leiste
        // des Controllers nachziehen. Das Detail steht genau dann im Fenster,
        // wenn `scheduledTaskDetailID` gesetzt ist; mit `.id` feuert der
        // Wechsel zwischen zwei Aufgaben beide Seiten.
        .onAppear { scheduledTaskDetailVisibilityChanged() }
        .onDisappear { scheduledTaskDetailVisibilityChanged() }
    }

    func scheduledTaskDetailVisibilityChanged() {
        syncActiveAgentChat()
        controllerLegendMayHaveChanged()
    }

    /// Etwas verdeckt den Chat. Hinter den Tickets zählt der sichtbare
    /// Board-Chat; das Detail einer geplanten Aufgabe zeigt keinen Chat, also
    /// gibt es kein Diktat-Ziel — sonst landete Diktat im verdeckten Chat.
    func syncHiddenChatAsActiveChat() {
        if isTicketsModeActive { return syncBoardChatAsActiveChat() }
        if AppState.shared.activeAgentChat != nil {
            AppState.shared.activeAgentChat = nil
        }
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
