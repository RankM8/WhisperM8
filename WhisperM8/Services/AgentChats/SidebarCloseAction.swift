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

    var icon: String {
        switch self {
        case .closeTerminal, .archive: return "xmark"
        // Minus statt X: „aus der Liste nehmen", nicht „wegwerfen".
        case .endSession: return "minus"
        }
    }

    var help: String {
        switch self {
        case .closeTerminal: return "Terminal schließen"
        case .endSession: return "Tab schließen und Chat beenden"
        case .archive: return "Archivieren"
        }
    }

    /// Terminals verhalten sich in JEDEM Scope gleich (schließen) — sonst
    /// entscheidet der Scope.
    static func resolve(scope: SidebarScope, session: AgentChatSession) -> SidebarCloseAction {
        if session.isTerminal { return .closeTerminal }
        return scope == .active ? .endSession : .archive
    }
}
