import Foundation

/// Pure Slot-Operationen auf `AgentGridWorkspace` — die komplette
/// Kurations-Semantik (Add mit Auto-Wachsen, gezieltes Ersetzen/Tauschen,
/// Verschieben, Kapazitätswechsel mit bestätigter Eviction-Liste) als
/// testbare Wertfunktionen. Persistenz, Session-Validierung und
/// Fenster-Kopplung übernimmt der `AgentWindowStore`.
///
/// Grundsätze (Plan-Abschnitt 03): stabile Positionen (nil statt
/// Nachrücken), „ein Drop blockiert nie — bis 3×3", nie automatisches
/// Schrumpfen.
enum WorkspaceSlotOps {
    enum AddResult: Equatable {
        /// In einen freien Slot gelegt; `grewTo` = neue Kapazität, falls
        /// dafür gewachsen wurde.
        case added(slotIndex: Int, grewTo: Int?)
        /// Ohne Ziel-Slot und schon Mitglied: No-op.
        case alreadyMember(slotIndex: Int)
        /// Gezielte Platzierung hat den bisherigen Inhalt ersetzt (der
        /// ersetzte Chat bleibt Tab — Aufräumen ist Sache des Aufrufers).
        case replaced(slotIndex: Int, displaced: UUID)
        /// Gezielte Platzierung eines vorhandenen Mitglieds: Quell- und
        /// Zielinhalt wurden getauscht.
        case swapped(from: Int, to: Int)
        /// Volle Endstufe 3×3 ohne Ziel-Slot — Drop wird benannt abgelehnt
        /// (gezieltes Ersetzen bleibt möglich).
        case full
        /// Ungültiger Ziel-Slot.
        case rejected
    }

    enum CapacityResult: Equatable {
        case applied
        /// Verkleinern würde diese Sessions (in Slot-Reihenfolge) entfernen —
        /// erst mit exakt dieser Liste als `expectedEvictedSessionIDs`
        /// bestätigen. Verhindert, dass eine veraltete Bestätigung
        /// inzwischen neu platzierte Chats entfernt.
        case confirmationRequired([UUID])
        /// Unzulässige Stufe.
        case rejected
    }

    // MARK: - Hinzufügen / Platzieren

    /// Nimmt `sessionID` in den Workspace auf.
    ///
    /// Ohne `targetSlot`: vorhandene Mitgliedschaft ist No-op, sonst erster
    /// freier Slot; ist alles voll, Auto-Wachsen auf die nächste Stufe und
    /// Platzierung im ersten NEUEN Slot; volle Endstufe 9 → `.full` ohne
    /// State-Änderung.
    ///
    /// Mit `targetSlot`: ersetzt den bisherigen Inhalt; war die Session
    /// bereits in einem anderen Slot DESSELBEN Workspace, tauschen Quelle
    /// und Ziel (kein Duplikat).
    static func add(
        _ sessionID: UUID,
        to workspace: AgentGridWorkspace,
        at targetSlot: Int? = nil
    ) -> (workspace: AgentGridWorkspace, result: AddResult) {
        var copy = workspace

        guard let targetSlot else {
            if let existing = copy.slotIndex(of: sessionID) {
                return (workspace, .alreadyMember(slotIndex: existing))
            }
            if let free = copy.firstFreeSlotIndex {
                copy.slots[free] = sessionID
                return (copy, .added(slotIndex: free, grewTo: nil))
            }
            guard let next = AgentGridWorkspace.nextCapacity(after: copy.capacity) else {
                return (workspace, .full)
            }
            let firstNewSlot = copy.capacity
            copy.capacity = next
            copy.normalize() // polstert Slots, repariert Fraction-Achsen
            copy.slots[firstNewSlot] = sessionID
            return (copy, .added(slotIndex: firstNewSlot, grewTo: next))
        }

        guard copy.slots.indices.contains(targetSlot) else {
            return (workspace, .rejected)
        }
        let displaced = copy.slots[targetSlot]
        if displaced == sessionID {
            return (workspace, .alreadyMember(slotIndex: targetSlot))
        }
        if let source = copy.slotIndex(of: sessionID) {
            copy.slots[source] = displaced
            copy.slots[targetSlot] = sessionID
            return (copy, .swapped(from: source, to: targetSlot))
        }
        copy.slots[targetSlot] = sessionID
        if let displaced {
            return (copy, .replaced(slotIndex: targetSlot, displaced: displaced))
        }
        return (copy, .added(slotIndex: targetSlot, grewTo: nil))
    }

    // MARK: - Entfernen / Verschieben / Tauschen

    /// Setzt den Slot der Session auf `nil` — ohne zu kompaktieren oder zu
    /// schrumpfen. `false`, wenn die Session kein Mitglied ist.
    static func remove(
        _ sessionID: UUID,
        from workspace: AgentGridWorkspace
    ) -> (workspace: AgentGridWorkspace, removed: Bool) {
        guard let index = workspace.slotIndex(of: sessionID) else {
            return (workspace, false)
        }
        var copy = workspace
        copy.slots[index] = nil
        return (copy, true)
    }

    /// Verschieben: nur belegte Quelle in LEERES Ziel (Quelle wird nil).
    /// Belegte Ziele werden bewusst abgewiesen — dafür gibt es `swapSlots`.
    static func moveSlot(
        in workspace: AgentGridWorkspace,
        from source: Int,
        to target: Int
    ) -> (workspace: AgentGridWorkspace, moved: Bool) {
        guard workspace.slots.indices.contains(source),
              workspace.slots.indices.contains(target),
              source != target,
              let session = workspace.slots[source],
              workspace.slots[target] == nil else {
            return (workspace, false)
        }
        var copy = workspace
        copy.slots[source] = nil
        copy.slots[target] = session
        return (copy, true)
    }

    /// Tauscht zwei gültige Indizes — einschließlich `nil` (belegt↔leer
    /// verhält sich wie ein stabiler Move). Gleicher/ungültiger Index = No-op.
    static func swapSlots(
        in workspace: AgentGridWorkspace,
        _ first: Int,
        _ second: Int
    ) -> (workspace: AgentGridWorkspace, swapped: Bool) {
        guard workspace.slots.indices.contains(first),
              workspace.slots.indices.contains(second),
              first != second else {
            return (workspace, false)
        }
        var copy = workspace
        copy.slots.swapAt(first, second)
        return (copy, true)
    }

    // MARK: - Kapazität

    /// Welche Sessions würde ein Wechsel auf `capacity` entfernen (geordnet,
    /// nur Tail-Slots — Grow liefert immer `[]`).
    static func previewCapacityChange(
        of workspace: AgentGridWorkspace,
        to capacity: Int
    ) -> [UUID] {
        guard AgentGridWorkspace.allowedCapacities.contains(capacity),
              capacity < workspace.capacity else { return [] }
        return workspace.slots.suffix(from: capacity).compactMap { $0 }
    }

    /// Kapazität setzen. Grow polstert mit `nil` (bestehende Indizes bleiben
    /// exakt); Shrink schneidet ausschließlich Tail-Slots ab und verlangt
    /// die bestätigte Eviction-Liste. Eine Achse behält ihre Fractions,
    /// wenn ihre Elementzahl gleich bleibt (`normalize`), sonst wird nur
    /// diese Achse gleichverteilt.
    static func setCapacity(
        of workspace: AgentGridWorkspace,
        to capacity: Int,
        expectedEvictedSessionIDs: [UUID] = []
    ) -> (workspace: AgentGridWorkspace, result: CapacityResult) {
        guard AgentGridWorkspace.allowedCapacities.contains(capacity) else {
            return (workspace, .rejected)
        }
        guard capacity != workspace.capacity else {
            return (workspace, .applied)
        }

        var copy = workspace
        if capacity > workspace.capacity {
            copy.capacity = capacity
            copy.normalize()
            return (copy, .applied)
        }

        let evicted = previewCapacityChange(of: workspace, to: capacity)
        guard evicted == expectedEvictedSessionIDs else {
            return (workspace, .confirmationRequired(evicted))
        }
        copy.slots.removeSubrange(capacity...)
        copy.capacity = capacity
        copy.normalize()
        return (copy, .applied)
    }
}
