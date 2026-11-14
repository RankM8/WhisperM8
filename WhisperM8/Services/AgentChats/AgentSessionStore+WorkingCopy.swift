import Foundation

extension AgentSessionStore {
    /// Merkt sich, wo ein Chat zuletzt gearbeitet hat (WM8-60). Schreibt nur
    /// bei einer Änderung und ohne den Aktivitäts-Bump von `updateSession`:
    /// Ein Ordner- oder Branchwechsel darf die Sortierung nicht verschieben.
    func setWorkingCopy(_ copy: AgentWorkingCopy, for id: UUID) throws {
        try mutateWorkspaceIfChanged { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == id }),
                  workspace.sessions[index].workingCopy != copy else { return false }
            workspace.sessions[index].workingCopy = copy
            return true
        }
    }

    /// Merkt sich das Nutzungslimit eines Chats (WM8-69); `nil` hebt es auf.
    /// Nur bei Änderung, ohne Aktivitäts-Bump.
    func setUsageLimit(_ limit: AgentUsageLimit?, for id: UUID) throws {
        try mutateWorkspaceIfChanged { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == id }),
                  workspace.sessions[index].usageLimit != limit else { return false }
            workspace.sessions[index].usageLimit = limit
            return true
        }
    }
}
