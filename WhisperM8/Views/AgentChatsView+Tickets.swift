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
        // Tickets zu (L2, „Zu den Chats“, Maus): Auswahl im Kopf weg, damit sie
        // beim Zurückkommen nicht mit einem alten Knopf wieder dasteht (WM8-91).
        if !active, TicketBoardControllers.shared.hasController(for: windowID) {
            TicketBoardControllers.shared.controller(for: windowID).viewModel.leaveHeader()
        }
        syncActiveAgentChat()
        if active { refreshTicketTeams() }
        controllerLegendMayHaveChanged()
        guard !active, let sessionID = selectedSessionID else { return }
        if let session = workspaceModel.session(id: sessionID),
           selectedProjectID != session.projectID {
            selectedProjectID = session.projectID
        }
        windowStore.clearSubagentUnread(sessionID)
    }

    /// Tasten des Boards (Plan „Tastatur“, WM8-91 Paket 3c). Nur in diesem
    /// Fenster, nur bei offenen Tickets, und nie, wenn der Fokus in einem
    /// Textfeld oder Terminal liegt: Dort gehören die Tasten dem Text. Einzige
    /// Ausnahme ist das Terminal des Board-Chats mit ⌘←, ⌘⌥←/→, ⌘⇧←/→ und ⌘J.
    /// Was das Board nicht nimmt, geht weiter.
    func handleTicketBoardKey(_ event: NSEvent) -> NSEvent? {
        guard let hostWindow, event.window === hostWindow, isTicketsModeActive,
              TicketBoardControllers.shared.hasController(for: windowID) else { return event }
        // Menü-Karte per ⌘K offen: Pfeile, Return und Esc gehören ihr
        // (`KeyboardIslandMonitor`), nicht der Auswahl dahinter.
        let ui = ControllerUIModel.shared
        if ui.menuByKeyboard, ui.menu != nil { return event }
        let boardChatTerminal = BoardChatInputs.shared.boardChat(in: windowID)
            .flatMap { terminalRegistry.controller(for: $0.sessionID)?.terminal }
        return TicketBoardKeyRouting.route(
            event, firstResponder: hostWindow.firstResponder,
            isBoardChatTerminal: { boardChatTerminal != nil && $0 === boardChatTerminal }
        ) { performTicketKey($0) }
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
                onDisabled: { [windowStore, windowID] in windowStore.setTicketsMode(false, in: windowID) },
                back: ticketsBackLink
            )
            .equatable()
        } column: { available in
            boardChatColumn(available: available)
        }
    }
}

// MARK: - Zurück zu den Chats (WM8-124)

extension AgentChatsView {
    /// „← Chats · …“ im Kopf des Boards: dasselbe Ziel wie L2 (`backPlace()`),
    /// sonst was hinter den Tickets steht. Kosten je Auswertung: eine Abfrage
    /// des Ortsverlaufs und ein, zwei Nachschläge über den Index.
    var ticketsBackLink: TicketsBackLinkModel {
        let workspaceEntity = activeGridWorkspaceEntity
        let behind = ChatPlace.of(
            selectedSessionID: selectedSessionID, showsGrid: showsGrid, workspaceID: workspaceEntity?.id,
            isWorkspaceMember: { workspaceEntity?.slotIndex(of: $0) != nil })
        let destination = TicketsBackLink.destination(previous: backPlace(), behind: behind) { place in
            switch place {
            case .chat(let id): return workspaceModel.session(id: id)?.title
            case .workspace(let id): return windowStore.gridWorkspace(id: id)?.name
            case .tickets: return nil
            }
        }
        return TicketsBackLinkModel(destination: destination) { [windowStore, windowID] in
            // L2 prüft den vorigen Ort beim Klick neu; gibt es ihn nicht mehr,
            // schließen nur die Tickets, und es bleibt, was dahinter steht.
            if destination.route == .previousPlace, performCommand(.lastChat) { return }
            windowStore.setTicketsMode(false, in: windowID)
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
                      isBoardChatTerminal: (NSResponder?) -> Bool = { _ in false },
                      handle: (TicketBoardKey) -> Bool) -> NSEvent? {
        let flags = event.modifierFlags
        var modifiers: TicketBoardKey.ModifierSet = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let key = TicketBoardKey.resolve(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                         modifiers: modifiers, isRepeat: event.isARepeat)
        // Terminal des Board-Chats (Paket 3c): nur zurück, Ticket blättern und
        // → Jarvis; alles andere gehört dem Chat.
        if isBoardChatTerminal(responder) {
            guard let key, key.isBoardChatKey else { return event }
            return handle(key) ? nil : event
        }
        guard TabNavShortcut.shouldHandle(firstResponder: responder),
              !BoardChatFocusRule.isTerminal(responder), let key else { return event }
        // Gehaltenes Return öffnet nichts weiter (Auflage der Prüferin): sonst
        // ginge es nach „Zum Chat“ oder „← Chats“ als Wiederholung weiter.
        if key == .open, event.isARepeat { return nil }
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
