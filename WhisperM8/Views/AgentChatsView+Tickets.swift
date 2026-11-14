import SwiftUI

/// Einstieg in die Ticket-Ansicht: ein Knopf in der Titelzone schaltet den
/// Bereich unter der Tab-Leiste zwischen Chats und Tickets um. Seitenleiste
/// und Tabs bleiben stehen; wer dort einen Chat wählt, ist wieder bei den Chats.
extension AgentChatsView {
    var isTicketsModeActive: Bool {
        windowStore.isTicketsMode(in: windowID)
    }

    /// Der Modus hat gewechselt. Beim Verlassen wird nachgeholt, was eine
    /// Auswahl hinter den Tickets ausgelassen hat (der Steuerkanal kann dort
    /// einen Chat aus einem anderen Projekt wählen): Das Projekt folgt dem
    /// gewählten Chat, und sein Subagent-Ergebnis gilt als gelesen.
    func ticketsModeChanged(_ active: Bool) {
        syncActiveAgentChat()
        guard !active, let sessionID = selectedSessionID else { return }
        if let session = workspace.sessions.first(where: { $0.id == sessionID }),
           selectedProjectID != session.projectID {
            selectedProjectID = session.projectID
        }
        windowStore.clearSubagentUnread(sessionID)
    }

    /// Tickets des Projekts, das in diesem Fenster gewählt ist.
    ///
    /// `.equatable()`: Das Fenster wertet seinen Body bei jedem Statuswechsel
    /// aus. Ohne den Vergleich zöge das die Ticket-Ansicht samt Karten mit.
    var ticketsWorkspace: some View {
        TicketBoardScreen(
            projectPath: selectedProject?.path,
            projectName: selectedProject?.name ?? "",
            controller: TicketBoardControllers.shared.controller(for: windowID),
            onDisabled: { [windowStore, windowID] in windowStore.setTicketsMode(false, in: windowID) }
        )
        .equatable()
    }
}

/// Umschalter Chats/Tickets in der Titelzone. Steht nur da, wenn die
/// Ticket-Ansicht eingeschaltet ist; sichtbar auch bei verborgener Seitenleiste.
struct TicketsModeButton: View {
    let windowStore: AgentWindowStore
    let windowID: UUID
    @AppStorage(PreferenceKeys.ticketBoardEnabled) private var enabled = false

    var body: some View {
        if enabled {
            let active = windowStore.isTicketsMode(in: windowID)
            TitlebarIconButton(
                systemImage: "ticket",
                help: active ? String(localized: "Back to chats") : String(localized: "Show tickets"),
                isActive: active
            ) {
                windowStore.setTicketsMode(!active, in: windowID)
            }
            .accessibilityLabel(Text("Tickets"))
        }
    }
}
