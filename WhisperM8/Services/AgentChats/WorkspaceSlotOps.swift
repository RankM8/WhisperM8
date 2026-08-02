import Foundation

/// Pure Slot-Operationen auf `AgentGridWorkspace` — die komplette
/// Kurations-Semantik (Add mit Auto-Wachsen, gezieltes Ersetzen/Tauschen,
/// Verschieben, Kapazitätswechsel mit bestätigter Eviction-Liste) als
/// testbare Wertfunktionen. Persistenz, Session-Validierung und
/// Fenster-Kopplung übernimmt der `AgentWindowStore`.
///
/// Grundsätze (Plan-Abschnitt 03): stabile Positionen (nil statt
/// Nachrücken), „ein Drop blockiert nie — bis 3×3", nie automatisches
/// Schrumpfen. Einzige Ausnahme von der Positionsstabilität ist das
/// ausdrücklich angeforderte Verkleinern (`planCapacityChange`): dort rücken
/// die Belegten nach vorn, damit Löcher keine Chats kosten.
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
        /// Unzulässige Stufe oder ungültige Behalten-Liste.
        case rejected
    }

    /// Ergebnis der Slot-Planung für eine Ziel-Kapazität.
    ///
    /// `retained`/`evicted` stehen IMMER in der aktuellen Slot-Reihenfolge:
    /// die Auswahl im Grid ist eine MENGE, die Reihenfolge kommt aus dem
    /// Layout — nie aus der Klick-Reihenfolge des Users.
    struct CapacityPlan: Equatable {
        let retained: [UUID]
        let evicted: [UUID]
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

    /// Setzt den Slot der Session auf `nil`. Mit `compacting` ruecken die
    /// uebrigen Chats nach und die Stufe faellt auf die kleinste passende.
    ///
    /// **Warum Verdichten der Normalfall ist:** Ohne das bleibt genau da ein
    /// Loch, wo eben noch ein Chat war, und die Flaeche behaelt eine Stufe,
    /// die sie nicht mehr braucht — aufraeumen muss dann der Nutzer von Hand.
    /// Das war der haeufigste Aerger am Grid. Wer die feste Position doch
    /// will, schaltet es ab:
    /// `defaults write com.whisperm8.app gridAutoCompactEnabled -bool NO`.
    static func remove(
        _ sessionID: UUID,
        from workspace: AgentGridWorkspace,
        compacting: Bool = true
    ) -> (workspace: AgentGridWorkspace, removed: Bool) {
        guard let index = workspace.slotIndex(of: sessionID) else {
            return (workspace, false)
        }
        var copy = workspace
        copy.slots[index] = nil
        return (compacting ? compacted(copy) : copy, true)
    }

    /// Schiebt alle belegten Slots nach vorn und senkt die Stufe auf die
    /// kleinste, die sie fasst.
    ///
    /// Die REIHENFOLGE bleibt erhalten — es wird nur zusammengeschoben, nie
    /// umsortiert. Sonst waere jedes Entfernen eine Ueberraschung: Der Blick
    /// sucht die Chats dort, wo sie vorher relativ zueinander standen.
    ///
    /// Ein leerer Workspace behaelt die kleinste Stufe, statt auf null zu
    /// fallen — sonst gaebe es keine Drop-Ziele mehr, um ihn wieder zu
    /// fuellen.
    static func compacted(_ workspace: AgentGridWorkspace) -> AgentGridWorkspace {
        let belegt = workspace.slots.compactMap { $0 }
        let stufe = AgentGridWorkspace.smallestCapacity(fitting: max(belegt.count, 1))
        guard stufe != workspace.capacity || belegt.count != workspace.slots.count else {
            // Nichts zu tun: volle Flaeche in passender Stufe.
            return workspace
        }
        var copy = workspace
        copy.capacity = stufe
        copy.slots = belegt + Array(repeating: nil, count: max(stufe - belegt.count, 0))
        // Die Gewichte passen nach einem Stufenwechsel nicht mehr zur
        // Spalten-/Zeilenzahl; die Entity repariert das achsenweise.
        copy.normalize()
        return copy
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

    /// Plant den Wechsel auf `capacity`: wer bleibt, wer verlässt den
    /// Workspace.
    ///
    /// Verkleinern KOMPAKTIERT: die belegten Slots rücken unter Beibehaltung
    /// ihrer relativen Reihenfolge nach vorn, erst danach wird gekappt.
    /// Dadurch kostet ein Verkleinern nur noch dann Chats, wenn wirklich mehr
    /// belegt sind als Slots übrig bleiben — Löcher aus vorherigem Entfernen
    /// (`remove` setzt auf `nil`, ohne nachzurücken) evakuieren nichts mehr.
    /// Das ist die einzige Stelle, die die Positionsstabilität aufgibt, und
    /// zwar genau dann, wenn der User das Layout ohnehin absichtlich umbaut.
    ///
    /// `keeping == nil` = Auto-Politik (die vorderen `capacity` Belegten
    /// bleiben). Mit expliziter Liste entscheidet der User im Grid, wer bleibt.
    ///
    /// `nil` = ungültige Eingabe: unerlaubte Stufe, oder eine Behalten-Liste
    /// mit Duplikaten, Fremd-IDs bzw. mehr Einträgen als Slots.
    static func planCapacityChange(
        of workspace: AgentGridWorkspace,
        to capacity: Int,
        keeping retainedSessionIDs: [UUID]? = nil
    ) -> CapacityPlan? {
        guard AgentGridWorkspace.allowedCapacities.contains(capacity) else { return nil }
        let occupied = workspace.occupiedSessionIDs

        // Grow (und die Nulländerung) fasst Indizes NIE an — eine mitgegebene
        // Behalten-Liste ist hier gegenstandslos, nicht ungültig.
        guard capacity < workspace.capacity else {
            return CapacityPlan(retained: occupied, evicted: [])
        }

        guard let retainedSessionIDs else {
            return CapacityPlan(
                retained: Array(occupied.prefix(capacity)),
                evicted: Array(occupied.dropFirst(capacity))
            )
        }

        let requested = Set(retainedSessionIDs)
        guard requested.count == retainedSessionIDs.count,
              retainedSessionIDs.count <= capacity,
              requested.isSubset(of: Set(occupied)) else { return nil }
        // In Slot-Reihenfolge materialisieren, nicht in der Reihenfolge des
        // übergebenen Arrays — sonst springen die Panes beim Verkleinern.
        return CapacityPlan(
            retained: occupied.filter(requested.contains),
            evicted: occupied.filter { !requested.contains($0) }
        )
    }

    /// Welche Sessions würde ein Wechsel auf `capacity` entfernen (in
    /// Slot-Reihenfolge)? Grow und ungültige Eingaben liefern `[]`.
    static func previewCapacityChange(
        of workspace: AgentGridWorkspace,
        to capacity: Int,
        keeping retainedSessionIDs: [UUID]? = nil
    ) -> [UUID] {
        planCapacityChange(
            of: workspace, to: capacity, keeping: retainedSessionIDs
        )?.evicted ?? []
    }

    /// Kapazität setzen. Grow polstert mit `nil` (bestehende Indizes bleiben
    /// exakt); Shrink kompaktiert die Belegung nach vorn (siehe
    /// `planCapacityChange`) und verlangt die bestätigte Eviction-Liste.
    /// Eine Achse behält ihre Fractions, wenn ihre Elementzahl gleich bleibt
    /// (`normalize`), sonst wird nur diese Achse gleichverteilt.
    ///
    /// Passt die Belegung nach dem Kompaktieren in die Zielstufe, ist die
    /// Eviction-Liste leer und deckt sich mit dem Default — der Wechsel geht
    /// dann ohne jede Bestätigung durch.
    static func setCapacity(
        of workspace: AgentGridWorkspace,
        to capacity: Int,
        keeping retainedSessionIDs: [UUID]? = nil,
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

        // Eine kaputte Behalten-Liste ist `.rejected`, NICHT
        // `.confirmationRequired` — sonst liefe ein Eingabefehler in eine
        // Bestätigungsschleife, die der User nie gewinnen kann.
        guard let plan = planCapacityChange(
            of: workspace, to: capacity, keeping: retainedSessionIDs
        ) else {
            return (workspace, .rejected)
        }
        guard plan.evicted == expectedEvictedSessionIDs else {
            return (workspace, .confirmationRequired(plan.evicted))
        }
        copy.slots = plan.retained.map { Optional($0) }
            + Array(repeating: nil, count: capacity - plan.retained.count)
        copy.capacity = capacity
        copy.normalize()
        return (copy, .applied)
    }
}
