import Foundation

extension AgentSessionStore {
    /// Merkt sich, wo ein Chat zuletzt gearbeitet hat (WM8-60). Schreibt nur
    /// bei einer Änderung und ohne den Aktivitäts-Bump von `updateSession`:
    /// Ein Ordner- oder Branchwechsel darf die Sortierung nicht verschieben.
    ///
    /// Alle Chats im selben Ordner teilen sich den Branch-Stand (WM8-73):
    /// Liest einer den Branch neu, ziehen die anderen mit, auch wenn sie
    /// ruhen und deshalb selbst nichts lesen.
    func setWorkingCopy(_ copy: AgentWorkingCopy, for id: UUID) throws {
        try mutateWorkspaceIfChanged { workspace in
            Self.applyWorkingCopy(copy, for: id, to: &workspace)
        }
    }

    /// Pur und testbar; `true`, wenn sich etwas geändert hat.
    static func applyWorkingCopy(_ copy: AgentWorkingCopy, for id: UUID, to workspace: inout AgentWorkspace) -> Bool {
        guard let index = workspace.sessions.firstIndex(where: { $0.id == id }) else { return false }
        var changed = false
        if workspace.sessions[index].workingCopy != copy {
            workspace.sessions[index].workingCopy = copy
            changed = true
        }
        // Nur einen an der Wurzel des Ordners gelesenen Branch teilen; der
        // Branch eines inneren Repos (Submodul) gilt nur für diesen Chat.
        guard copy.branchFromNestedRepo != true else { return changed }
        for other in workspace.sessions.indices where other != index {
            guard var shared = workspace.sessions[other].workingCopy, shared.path == copy.path,
                  shared.branch != copy.branch || shared.detachedHead != copy.detachedHead else { continue }
            shared.branch = copy.branch
            shared.detachedHead = copy.detachedHead
            workspace.sessions[other].workingCopy = shared
            changed = true
        }
        return changed
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
