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
}
