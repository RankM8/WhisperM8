import Foundation

/// Was die Hover-/Selektions-Aktion rechts in einer Sidebar-Chat-Zeile tut.
/// Hängt am Sidebar-Scope: „Aktiv" ist das Arbeitsset (laufende Sessions ∪
/// offene Tabs) — dort räumt man auf (Tab zu, Chat beenden), statt in ein
/// Archiv zu verschieben, aus dem man den Chat später wieder herausholen
/// müsste. In allen anderen Scopes bleibt es beim Archivieren.
///
/// Pur + wertbasiert, damit die Zuordnung testbar ist und die Rows sie über
/// `closeIcon`/`closeHelp` (Equatable-Vergleich) mitnehmen können.
enum SidebarCloseAction: Equatable {
    /// Terminal-Session: Shell beenden und Session löschen. Ein Terminal hat
    /// kein Transcript — weder Resume noch Archiv-Eintrag ergäben Sinn.
    case closeTerminal
    /// Tab entfernen, laufendes PTY beenden, Status auf `.closed`. Der Chat
    /// bleibt eine normale, resumebare Session und ist über „Zuletzt"/„Alle"
    /// wieder erreichbar — er wandert NICHT ins Archiv.
    case endSession
    /// Chat archivieren (Verhalten außerhalb von „Aktiv").
    case archive
    /// Workspace-Row: wie `endSession`, zusätzlich verliert der Chat die
    /// Mitgliedschaft im geklickten Workspace. Bei Mehrfach-Mitgliedschaft
    /// bleibt er in den ANDEREN Workspaces stehen (als beendeter Chat) —
    /// dieselbe Semantik wie der Kontextmenü-Eintrag „Aus Workspace
    /// entfernen".
    case endAndRemoveFromWorkspace

    var icon: String {
        switch self {
        case .closeTerminal, .archive: return "xmark"
        // Minus statt X: „aus der Liste nehmen", nicht „wegwerfen".
        case .endSession, .endAndRemoveFromWorkspace: return "minus"
        }
    }

    var help: String {
        switch self {
        case .closeTerminal: return String(localized: "Close terminal")
        case .endSession: return String(localized: "Close tab and end chat")
        case .archive: return String(localized: "Archive")
        case .endAndRemoveFromWorkspace: return String(localized: "Close tab, end chat and remove from workspace")
        }
    }

    /// Terminals verhalten sich in JEDEM Scope gleich (schließen) — sonst
    /// entscheidet der Scope.
    static func resolve(scope: SidebarScope, session: AgentChatSession) -> SidebarCloseAction {
        if session.isTerminal { return .closeTerminal }
        return scope == .active ? .endSession : .archive
    }

    /// Workspace-Rows sind scope-unabhängig: ein Workspace ist — wie der
    /// Scope „Aktiv" — ein Arbeitsset, dort räumt man auf statt zu
    /// archivieren. Bewusst NICHT status-abhängig (Icon würde sonst live
    /// unter dem Cursor wechseln); bei nicht laufenden Chats ist das
    /// Beenden ein No-op und das Minus wirkt als reines Entfernen.
    static func resolveForWorkspaceRow(session: AgentChatSession) -> SidebarCloseAction {
        session.isTerminal ? .closeTerminal : .endAndRemoveFromWorkspace
    }
}
