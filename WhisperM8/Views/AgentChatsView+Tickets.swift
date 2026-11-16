import AppKit
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
        if active { refreshTicketTeams() }
        guard !active, let sessionID = selectedSessionID else { return }
        if let session = workspaceModel.session(id: sessionID),
           selectedProjectID != session.projectID {
            selectedProjectID = session.projectID
        }
        windowStore.clearSubagentUnread(sessionID)
    }

    /// J/K, ↑↓ und Esc in der Triage. Nur in diesem Fenster, nur bei offenen
    /// Tickets, und nie, wenn der Fokus in einem Textfeld oder Terminal liegt:
    /// Dort gehören die Tasten dem Text. Ohne offene Triage geht die Taste weiter.
    func handleTicketBoardKey(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow, isTicketsModeActive,
              TicketBoardControllers.shared.hasController(for: windowID) else { return event }
        return TicketBoardKeyRouting.route(event, firstResponder: hostWindow.firstResponder) {
            TicketBoardControllers.shared.controller(for: windowID).viewModel.handle($0)
        }
    }

    /// Tickets des Projekts, das in diesem Fenster gewählt ist.
    ///
    /// `.equatable()`: Das Fenster wertet seinen Body bei jedem Statuswechsel
    /// aus. Ohne den Vergleich zöge das die Ticket-Ansicht samt Karten mit.
    ///
    /// Rechts daneben der Board-Chat (WM8-113, `AgentChatsView+BoardChat`).
    var ticketsWorkspace: some View {
        BoardChatSplit {
            TicketBoardScreen(
                projectPath: selectedProject?.path,
                projectName: selectedProject?.name ?? "",
                controller: TicketBoardControllers.shared.controller(for: windowID),
                onDisabled: { [windowStore, windowID] in windowStore.setTicketsMode(false, in: windowID) }
            )
            .equatable()
        } column: { available in
            boardChatColumn(available: available)
        }
    }
}

/// Wem gehört eine Taste im Ticket-Modus: dem Board oder dem Fokus? Getrennt
/// von der Ansicht, damit Tests es mit echtem Fenster und Ereignis prüfen.
enum TicketBoardKeyRouting {
    /// `nil` = vom Board genommen. Ein Terminal mit Fokus (der Board-Chat in der
    /// Spalte) und bearbeitbare Textfelder behalten alle Tasten, auch ⌘C: Dort
    /// kopiert ⌘C die Markierung, nicht den Link. Vorher prüfte die Stelle den
    /// Typnamen des Optionals („Optional<NSResponder>“) und erkannte das
    /// Terminal nie; J, K, ↑, ↓ und Esc blätterten dann in der Triage, statt
    /// im Board-Chat anzukommen (WM8-113).
    @MainActor
    static func route(_ event: NSEvent, firstResponder responder: NSResponder?,
                      handle: (TicketBoardKey) -> Bool) -> NSEvent? {
        guard TabNavShortcut.shouldHandle(firstResponder: responder),
              !BoardChatFocusRule.isTerminal(responder) else { return event }
        let flags = event.modifierFlags
        var modifiers: TicketBoardKey.ModifierSet = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard let key = TicketBoardKey.resolve(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                               modifiers: modifiers) else { return event }
        // ⌘C mit markiertem Text (etwa in der Beschreibung) kopiert den Text.
        if key == .copyLink, let text = responder as? NSTextView, text.selectedRange().length > 0 { return event }
        return handle(key) ? nil : event
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
            // Einstellungen der Board-Chat-Spalte schon vor dem ersten Klick lesen.
            .task { BoardChatPreferencesStore.shared.preload() }
        }
    }
}
