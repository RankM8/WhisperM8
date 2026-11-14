import SwiftUI

/// Einstieg in die Ticket-Ansicht: ein Knopf in der Titelzone schaltet den
/// Bereich unter der Tab-Leiste zwischen Chats und Tickets um. Seitenleiste
/// und Tabs bleiben stehen; wer dort einen Chat wählt, ist wieder bei den Chats.
extension AgentChatsView {
    var isTicketsModeActive: Bool {
        windowStore.isTicketsMode(in: windowID)
    }

    /// Tickets des Projekts, das in diesem Fenster gewählt ist.
    var ticketsWorkspace: some View {
        TicketBoardScreen(
            projectPath: selectedProject?.path,
            projectName: selectedProject?.name ?? "",
            onDisabled: { windowStore.setTicketsMode(false, in: windowID) }
        )
        // Auch eine Auswahl, die nicht über `navigateToSession` kam (neuer
        // Chat, wiederhergestellter Tab), soll den Chat zeigen.
        .onChange(of: selectedSessionID) { _, selected in
            if selected != nil { windowStore.setTicketsMode(false, in: windowID) }
        }
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
