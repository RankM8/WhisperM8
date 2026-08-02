import Foundation

/// Pure Auflösung eines Slot-Drops (Plan F7, Drag-&-Drop-Matrix):
///
/// - Pane-Header → belegte Pane: **tauschen** · → leerer Slot: **verschieben**
///   (nur bei passender Workspace-Herkunft — ein Slot-Index ohne
///   Workspace-Kontext ist bei globalen Entities mehrdeutig)
/// - Tab/Sidebar-Chat → belegte Pane: **ersetzen** · → leerer Slot:
///   **einfügen** (beides `.place`; die Ersetzen/Tauschen-Semantik liegt in
///   `WorkspaceSlotOps.add`)
///
/// Unit-getestet in `GridDropZoneResolverTests`.
enum GridDropZoneResolver {
    enum Action: Equatable {
        /// Same-Workspace-Drag in einen leeren Slot.
        case moveSlot(from: Int, to: Int)
        /// Same-Workspace-Drag auf eine belegte Pane.
        case swapSlots(Int, Int)
        /// Externe Quelle (Tab, Sidebar, anderer Workspace): gezielt
        /// platzieren (ersetzen/einfügen/tauschen via `WorkspaceSlotOps.add`).
        case place
        /// Nichts zu tun (Drop auf den eigenen Slot, ungültiges Ziel).
        case none
    }

    static func action(
        sessionID: UUID,
        sourceWorkspaceID: UUID?,
        sourceSlotIndex: Int?,
        targetSlot: Int,
        workspace: AgentGridWorkspace
    ) -> Action {
        guard workspace.slots.indices.contains(targetSlot) else { return .none }

        // Slot-Herkunft zählt nur, wenn sie zum ZIEL-Workspace gehört UND
        // noch stimmt (der Drag kann älter sein als die letzte Mutation).
        if sourceWorkspaceID == workspace.id,
           let sourceSlot = sourceSlotIndex,
           workspace.slots.indices.contains(sourceSlot),
           workspace.slots[sourceSlot] == sessionID {
            if sourceSlot == targetSlot { return .none }
            return workspace.slots[targetSlot] == nil
                ? .moveSlot(from: sourceSlot, to: targetSlot)
                : .swapSlots(sourceSlot, targetSlot)
        }

        if workspace.slots[targetSlot] == sessionID { return .none }
        return .place
    }
}
