import Foundation

/// Ein angelegter Workspace, wie die Workspace-Auswahl (L2 halten im Raster)
/// ihn zeigt. Wird im Ereignis-Pfad gebaut, wenn die Auswahl aufgeht — nie in
/// einem Body.
struct ControllerWorkspaceChoice: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var colorHex: String
    /// Belegte Slots.
    var chatCount: Int
    /// Dort wartet ein Chat auf den Nutzer — derselbe Status
    /// (`awaitingInput`), den der Punkt in Seitenleiste und Tab zeigt.
    var hasWaitingChat: Bool
    /// Das Raster dieses Fensters zeigt ihn gerade.
    var isCurrent: Bool
}

/// Workspace-Auswahl des Controllers (Runde 3): Liste der angelegten
/// Workspaces in der Reihenfolge der Seitenleiste, Markierung startet beim
/// aktuellen. Kein Umlauf — am Rand bleibt die Markierung stehen, wie in der
/// Liste links.
struct ControllerWorkspacePickerModel: Equatable, Sendable {
    private(set) var choices: [ControllerWorkspaceChoice]
    private(set) var selectedID: UUID?

    init(choices: [ControllerWorkspaceChoice]) {
        self.choices = choices
        selectedID = (choices.first(where: \.isCurrent) ?? choices.first)?.id
    }

    var selected: ControllerWorkspaceChoice? {
        choices.first { $0.id == selectedID }
    }

    mutating func move(_ step: Int) {
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex { $0.id == selectedID } ?? 0
        selectedID = choices[min(max(index + step, 0), choices.count - 1)].id
    }
}
