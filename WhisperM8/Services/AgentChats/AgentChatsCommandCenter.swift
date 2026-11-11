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
    /// Tab des ausgewählten Chats schließen (wie ⌘W).
    case closeSelectedTab
    /// Neuer Chat im aktuellen Kontext-Projekt, mit dem Standard-Agenten.
    case newChatInCurrentProject
    /// Neuer Chat in einem bestimmten Projekt.
    case newChat(projectID: UUID)
    /// Chat auswählen — derselbe Weg wie ein Klick in der Seitenleiste.
    case selectSession(UUID)
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
    var activeWindowID: UUID? {
        guard let id = keyWindowID(), handlers[id] != nil else { return nil }
        return id
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
