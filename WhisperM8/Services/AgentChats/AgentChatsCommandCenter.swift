import Foundation

/// Fachliche Befehle an ein Agent-Chats-Fenster — ohne Tastatur-Ereignis
/// aufrufbar. Tastaturkürzel und Controller lösen damit dieselben Wege aus.
///
/// Bewusst klein gehalten: nur, was heute schon als Kürzel oder Klick
/// existiert. Die Ausführung liegt in `AgentChatsView+Commands.swift`.
enum AgentChatsCommand: Equatable {
    /// Benachbarter Tab in der sichtbaren Reihenfolge, mit Umlauf (wie ⌘⌥←/→).
    case previousTab
    case nextTab
    /// Chat, der am längsten auf Eingabe wartet (wie ⌃⌥Tab).
    case nextWaitingChat
    /// Zurück zum zuvor ausgewählten Chat.
    case lastChat
    /// Kachel-Fokus im sichtbaren Raster (wie ⌃⌘-Pfeile).
    case gridFocus(GridFocusDirection)
    /// Kachel groß bzw. zurück zum Raster.
    case toggleMaximize
    /// Zeile der Liste schließen wie ihr „−“/„×“. Chat-Zeilen folgen dem
    /// Filter (im Filter „Aktiv“ Tab zu und Chat beenden, sonst archivieren),
    /// Workspace-Zeilen beenden und nehmen den Chat aus dem Workspace. Läuft
    /// ein Terminal, fragt der Dialog der Seitenleiste nach. Für den
    /// ausgewählten Chat: `.chat(id)`.
    case closeListRow(SidebarNavigationRow)
    /// Aktionen am Chat (Options-Menü des Controllers) — dieselben Wege wie
    /// das Kontextmenü eines Chats.
    case togglePin(UUID)
    /// Umbenennen-Sheet öffnen.
    case renameChat(UUID)
    case forkChat(UUID)
    /// „GPT-Konto“: gilt ab dem nächsten Start des Chats.
    case setGPTAccount(UUID, profileName: String)
    /// Archivieren, mit der Rückfrage der Seitenleiste bei laufendem Terminal.
    case archiveChat(UUID)
    /// „Zu Account verschieben“: öffnet das Umzugs-Sheet mit Vorschau.
    case moveChatToAccount(UUID, profileName: String)
    /// Neuer Chat im aktuellen Kontext-Projekt, mit dem Standard-Agenten.
    case newChatInCurrentProject
    /// Neuer Chat in einem bestimmten Projekt.
    case newChat(projectID: UUID)
    /// Projekt-Auswahl „Neuer Chat“ öffnen (wie ⌘N). Blendet die Seitenleiste
    /// ein (die Auswahl hängt an ihrem Knopf); `preferredProjectID` ist
    /// vorausgewählt, ohne Angabe das aktuelle Projekt.
    case showNewChatPicker(preferredProjectID: UUID?)
    /// Gestoppten Chat wieder starten — derselbe Weg wie der Knopf „Starten“
    /// im Kopf. Nicht für archivierte und laufende Chats. Ist er nicht
    /// ausgewählt, wird er zuerst ausgewählt.
    case startChat(UUID)
    /// Chat auswählen — derselbe Weg wie ein Klick in der Seitenleiste.
    case selectSession(UUID)
    /// Chat-Zeile im WORKSPACES-Abschnitt öffnen — derselbe Weg wie ihr
    /// Klick: im sichtbaren Workspace Pane-Fokus, sonst wechselt das Fenster
    /// in diesen Workspace mit dem Chat als Pane-Fokus.
    case selectWorkspaceChat(UUID, workspaceID: UUID)
    /// Workspace als Raster öffnen.
    case activateWorkspace(UUID)
    /// Projekt als Workspace seiner aktiven Chats öffnen.
    case openProjectAsWorkspace(UUID, activeSessionIDs: Set<UUID>)
    case setSidebarVisible(Bool)
    /// Filter der Seitenleiste (Aktiv / Zuletzt / Alle) um einen Schritt weiter.
    case sidebarFilter(step: Int)
    /// Umschalter öffnen, Markierung auf dem aktuellen Chat.
    case switcherBegin
    case switcherMove(GridFocusDirection)
    case switcherCommit
    case switcherCancel
    case clearMultiSelection
}

/// Was ein Fenster über sich sagt, wenn eine Eingabe eintrifft. Wird im
/// Ereignis-Pfad gezogen, nie aus einem Body heraus.
struct AgentChatsWindowSnapshot: Equatable {
    var windowID: UUID
    var isKeyWindow: Bool
    var selectedSessionID: UUID?
    /// Raster sichtbar.
    var isGridActive: Bool
    /// Einzelansicht mit Rücksprung in einen Workspace.
    var canReturnToWorkspace: Bool
    var isSwitcherOpen: Bool
    /// Sheet am Fenster — Eingaben gehören dann dem Sheet.
    var hasSheet: Bool
    var isSidebarVisible: Bool
    var hasMultiSelection: Bool
    var isArchiveMode: Bool
    /// Projekt-Auswahl „Neuer Chat“ offen (Popover an der Seitenleiste).
    /// Eingaben gehören dann ihr, wie bei einem Sheet.
    var isNewChatPickerOpen: Bool = false
    /// Rückfrage „Chat beenden?“ bzw. „Chat archivieren?“ offen.
    var isConfirmationOpen: Bool = false

    /// Etwas Eigenes des Fensters hat die Eingaben (Popover oder Rückfrage)
    /// und ist womöglich selbst Key geworden.
    var ownsKeyOverlay: Bool { isNewChatPickerOpen || isConfirmationOpen }
}

/// Eine Zeile der Liste links, so wie die Navigation sie braucht.
struct AgentChatsListRow: Equatable {
    var row: SidebarNavigationRow
    /// Projekt, in dem „Neuer Chat“ von dieser Zeile aus landet.
    var projectID: UUID?
    /// Nur für Projekt-Zeilen: die aktiven Chats, die „als Workspace öffnen“ zeigt.
    var activeSessionIDs: Set<UUID> = []
}

/// Verteilt Befehle an das Agent-Chats-Fenster, das gerade aktiv ist.
///
/// Jedes Fenster meldet beim Erscheinen einen Handler an und bekommt ein
/// Token. Abgemeldet wird nur mit passendem Token: Baut SwiftUI eine View neu
/// auf, läuft das `onDisappear` der alten Instanz manchmal NACH dem
/// `onAppear` der neuen — ohne Token würde es den frischen Handler entfernen.
@MainActor
final class AgentChatsCommandCenter {
    static let shared = AgentChatsCommandCenter(
        keyWindowID: { AgentWindowStore.shared.keyAgentChatWindowID }
    )

    struct Handler {
        let perform: (AgentChatsCommand) -> Bool
        let snapshot: () -> AgentChatsWindowSnapshot
        /// Sichtbare Zeilen der Liste links in Anzeige-Reihenfolge, für die
        /// Navigation ohne Maus. Im Ereignis-Pfad berechnet, nie im Body.
        var listRows: () -> [AgentChatsListRow] = { [] }
        /// Angaben für das Menü „Aktionen am Chat“; `nil`, wenn es den Chat
        /// nicht gibt.
        var chatActionInfo: (UUID) -> ControllerChatActionInfo? = { _ in nil }
        /// Angelegte Workspaces für die Workspace-Auswahl des Controllers, in
        /// der Reihenfolge der Seitenleiste. Im Ereignis-Pfad berechnet.
        var workspaceChoices: () -> [ControllerWorkspaceChoice] = { [] }
    }

    struct Token: Equatable {
        let windowID: UUID
        fileprivate let serial: Int
    }

    private var handlers: [UUID: (serial: Int, handler: Handler)] = [:]
    private var nextSerial = 0
    private let keyWindowID: () -> UUID?

    init(keyWindowID: @escaping () -> UUID?) {
        self.keyWindowID = keyWindowID
    }

    func register(windowID: UUID, handler: Handler) -> Token {
        nextSerial += 1
        handlers[windowID] = (nextSerial, handler)
        return Token(windowID: windowID, serial: nextSerial)
    }

    /// Entfernt den Handler nur, wenn er noch der aus `token` ist.
    func unregister(_ token: Token) {
        guard handlers[token.windowID]?.serial == token.serial else { return }
        handlers[token.windowID] = nil
    }

    /// Das Fenster, an das Befehle ohne ausdrückliches Ziel gehen: das
    /// Key-Fenster, sofern es angemeldet ist. Bewusst NICHT das Diktat-Fenster
    /// — das bleibt auch dann gesetzt, wenn die App im Hintergrund ist oder
    /// die Einstellungen vorne liegen, und Navigation dort wäre unsichtbar.
    ///
    /// Ausnahme: Die Projekt-Auswahl „Neuer Chat“ (Popover mit Suchfeld) und
    /// die Rückfragen zum Beenden oder Archivieren werden womöglich selbst
    /// Key; das Fenster meldet dann `resignKey`. Es bleibt trotzdem Ziel,
    /// sonst landete der Controller im Zusammenhang „anderes Fenster“.
    var activeWindowID: UUID? {
        if let id = keyWindowID(), handlers[id] != nil { return id }
        return handlers.first { $0.value.handler.snapshot().ownsKeyOverlay }?.key
    }

    /// Schnappschuss eines Fensters; ohne `windowID` der des aktiven Fensters.
    func snapshot(of windowID: UUID? = nil) -> AgentChatsWindowSnapshot? {
        guard let id = windowID ?? activeWindowID else { return nil }
        return handlers[id]?.handler.snapshot()
    }

    /// Zeilen der Liste links eines Fensters; ohne `windowID` die des aktiven.
    func listRows(of windowID: UUID? = nil) -> [AgentChatsListRow] {
        guard let id = windowID ?? activeWindowID else { return [] }
        return handlers[id]?.handler.listRows() ?? []
    }

    /// Angaben für „Aktionen am Chat“; ohne `windowID` aus dem aktiven Fenster.
    func chatActionInfo(_ sessionID: UUID, in windowID: UUID? = nil) -> ControllerChatActionInfo? {
        guard let id = windowID ?? activeWindowID else { return nil }
        return handlers[id]?.handler.chatActionInfo(sessionID)
    }

    /// Workspaces für die Workspace-Auswahl; ohne `windowID` aus dem aktiven Fenster.
    func workspaceChoices(of windowID: UUID? = nil) -> [ControllerWorkspaceChoice] {
        guard let id = windowID ?? activeWindowID else { return [] }
        return handlers[id]?.handler.workspaceChoices() ?? []
    }

    /// Führt einen Befehl aus. Ohne `windowID` nur im aktiven Fenster, und nur
    /// wenn es sich selbst als Key meldet. Mit `windowID` gezielt (Tests und
    /// der Debug-Kanal der Test-Instanz, die nie ein Key-Fenster hat).
    /// - Returns: `true`, wenn der Befehl etwas bewirkt hat.
    @discardableResult
    func perform(_ command: AgentChatsCommand, in windowID: UUID? = nil) -> Bool {
        if let windowID {
            return handlers[windowID]?.handler.perform(command) ?? false
        }
        guard let id = activeWindowID, let handler = handlers[id]?.handler,
              handler.snapshot().isKeyWindow else { return false }
        return handler.perform(command)
    }
}
