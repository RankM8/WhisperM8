import Foundation

/// Visuelle Herkunft einer Tab-Gruppe. Eine Workspace-Zugehörigkeit gewinnt
/// immer vor dem Projekt — dieselbe Semantik wie im Design-Mockup.
enum AgentTabGroupingKey: Hashable {
    case workspace(UUID)
    case project(UUID)
}

struct AgentTabGroupingEntry: Equatable {
    let sessionID: UUID
    let projectID: UUID
}

enum AgentTabGroupingItem: Equatable {
    case single(UUID)
    case group(key: AgentTabGroupingKey, sessionIDs: [UUID])
}

/// Eine Drop-EINHEIT der Tab-Leiste. Die Leiste besteht beim Ziehen nicht aus
/// Tabs, sondern aus Slots — nur so hat eine eingeklappte Gruppe eine eigene
/// Einfügeposition, obwohl ihre Mitglieder unsichtbar sind:
///
/// - Einzeltab und sichtbares Gruppenmitglied → je ein Slot
/// - eingeklappte Gruppe → GENAU ein Slot (unteilbarer Block)
enum AgentTabStripSlot: Equatable {
    case tab(id: UUID, groupKey: AgentTabGroupingKey?)
    case collapsedGroup(key: AgentTabGroupingKey, memberIDs: [UUID])

    /// ID, unter der die Geometrie den Frame dieses Slots führt.
    var leadingID: UUID {
        switch self {
        case .tab(let id, _): id
        case .collapsedGroup(_, let ids): ids.first ?? UUID()
        }
    }

    var memberIDs: [UUID] {
        switch self {
        case .tab(let id, _): [id]
        case .collapsedGroup(_, let ids): ids
        }
    }

    /// Herkunftsgruppe — bei eingeklappten Gruppen `nil`, weil der Slot als
    /// Ganzes bereits die Gruppe IST und keine inneren Grenzen hat.
    var expandedGroupKey: AgentTabGroupingKey? {
        switch self {
        case .tab(_, let key): key
        case .collapsedGroup: nil
        }
    }

    var containsCollapsedGroup: Bool {
        if case .collapsedGroup = self { return true }
        return false
    }
}

/// Reine Gruppierungslogik für den Chrome-artigen Tab-Strip.
///
/// - Gruppen entstehen erst ab zwei sichtbaren Tabs derselben Herkunft.
/// - Die Gruppenposition entspricht dem ersten Mitglied in der manuellen
///   Tab-Reihenfolge; innerhalb bleibt diese Reihenfolge unverändert.
/// - Deaktivierte Gruppierung liefert exakt die manuelle Reihenfolge zurück.
enum AgentTabGrouping {
    static func key(
        for entry: AgentTabGroupingEntry,
        workspaceBySession: [UUID: UUID]
    ) -> AgentTabGroupingKey {
        if let workspaceID = workspaceBySession[entry.sessionID] {
            return .workspace(workspaceID)
        }
        return .project(entry.projectID)
    }

    static func items(
        entries: [AgentTabGroupingEntry],
        workspaceBySession: [UUID: UUID],
        enabled: Bool
    ) -> [AgentTabGroupingItem] {
        guard enabled else { return entries.map { .single($0.sessionID) } }

        func groupingKey(for entry: AgentTabGroupingEntry) -> AgentTabGroupingKey {
            key(for: entry, workspaceBySession: workspaceBySession)
        }

        let counts = Dictionary(grouping: entries, by: groupingKey(for:)).mapValues(\.count)
        var emitted: Set<AgentTabGroupingKey> = []
        var result: [AgentTabGroupingItem] = []

        for entry in entries {
            let groupKey = groupingKey(for: entry)
            guard counts[groupKey, default: 0] >= 2 else {
                result.append(.single(entry.sessionID))
                continue
            }
            guard emitted.insert(groupKey).inserted else { continue }

            result.append(.group(
                key: groupKey,
                sessionIDs: entries
                    .filter { groupingKey(for: $0) == groupKey }
                    .map(\.sessionID)
            ))
        }

        return result
    }

    /// Zerlegt die Anzeige in Drop-Slots. Eine eingeklappte Gruppe wird zu
    /// EINEM Slot — dadurch behält sie beim Ziehen eine Einfügeposition,
    /// ohne dass man sie aufklappen (und den User damit überrumpeln) muss.
    static func slots(
        items: [AgentTabGroupingItem],
        collapsedKeys: Set<AgentTabGroupingKey>
    ) -> [AgentTabStripSlot] {
        items.flatMap { item -> [AgentTabStripSlot] in
            switch item {
            case .single(let id):
                return [.tab(id: id, groupKey: nil)]
            case .group(let key, let sessionIDs):
                guard !collapsedKeys.contains(key) else {
                    return [.collapsedGroup(key: key, memberIDs: sessionIDs)]
                }
                return sessionIDs.map { .tab(id: $0, groupKey: key) }
            }
        }
    }

    /// Verschiebt eine rohe, aus der Cursor-Position gewonnene Einfügeposition
    /// auf die nächste ERLAUBTE Slot-Grenze. Die Einfügelinie zeigt damit nie
    /// eine Position, die der Drop anschließend nicht einhalten kann:
    ///
    /// - Ein Teil einer Gruppe bleibt innerhalb des eigenen Clusters. Die
    ///   Zugehörigkeit folgt aus Workspace/Projekt; „herausziehen" wäre
    ///   visuell folgenlos, würde die gespeicherte Reihenfolge aber
    ///   auseinanderlaufen lassen.
    /// - Alles andere (fremder Tab, ganze Gruppe) landet nie ZWISCHEN zwei
    ///   Mitglieder desselben Clusters — Gruppen bleiben zusammenhängend.
    static func snappedInsertionIndex(
        requested: Int,
        slots: [AgentTabStripSlot],
        movingIDs: Set<UUID>,
        movingOrigin: AgentTabGroupingKey?,
        originOfSession: (UUID) -> AgentTabGroupingKey?,
        groupingEnabled: Bool
    ) -> Int {
        let clamped = min(max(requested, 0), slots.count)
        guard groupingEnabled, !movingIDs.isEmpty else { return clamped }

        // Nach dem Drop zieht die Anzeige die bewegten Tabs zwangsläufig zu
        // allen ZURÜCKBLEIBENDEN Tabs derselben Herkunft. Nur innerhalb deren
        // Spanne kann die Einfügelinie halten, was sie verspricht.
        //
        // Die Herkunft kommt bewusst von der Session selbst, NICHT aus den
        // Ziel-Slots: sonst gilt die Regel weder für eingeklappte Gruppen
        // (Mitglieder sind keine eigenen Slots) noch für Chats, die aus einem
        // anderen Fenster oder aus der Sidebar hereinkommen.
        if let origin = movingOrigin {
            let anchors = slots.indices.filter { index in
                slots[index].memberIDs.contains { id in
                    !movingIDs.contains(id) && originOfSession(id) == origin
                }
            }
            if let first = anchors.first, let last = anchors.last {
                return min(max(clamped, first), last + 1)
            }
        }

        // Sonst nur die Grundregel: nie ZWISCHEN zwei Mitglieder desselben
        // aufgeklappten Clusters — Gruppen bleiben zusammenhängend.
        guard clamped > 0, clamped < slots.count,
              let key = slots[clamped - 1].expandedGroupKey,
              slots[clamped].expandedGroupKey == key,
              let range = slotRange(ofGroup: key, in: slots) else { return clamped }

        let middle = (range.lowerBound + range.upperBound + 1) / 2
        return clamped <= middle ? range.lowerBound : range.upperBound + 1
    }

    /// Löst eine Slot-Grenze in die Session auf, VOR der eingefügt wird
    /// (`nil` = ans Ende).
    ///
    /// Überspringt dabei alles, was selbst mitwandert: Zeigt die Grenze auf
    /// einen bewegten Tab, wäre das Ziel Teil der eigenen Auswahl und der
    /// Reorder würde stillschweigend nichts tun. Das passiert bei einer nicht
    /// zusammenhängenden Mehrfach-Auswahl innerhalb einer Gruppe (A und C von
    /// [A,B,C]), deren erlaubte Grenze zwangsläufig an C liegt.
    static func dropTargetID(
        atSlotIndex index: Int,
        in slots: [AgentTabStripSlot],
        movingIDs: Set<UUID>
    ) -> UUID? {
        guard index >= 0 else { return nil }
        for slot in slots.dropFirst(index) {
            if let stationary = slot.memberIDs.first(where: { !movingIDs.contains($0) }) {
                return stationary
            }
        }
        return nil
    }

    private static func slotRange(
        ofGroup key: AgentTabGroupingKey,
        in slots: [AgentTabStripSlot]
    ) -> ClosedRange<Int>? {
        let indices = slots.indices.filter { slots[$0].expandedGroupKey == key }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }
}
