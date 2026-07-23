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

    /// Ein fremder Tab darf eine sichtbare Herkunftsgruppe nicht in zwei
    /// Blöcke teilen. Zeigt der Drop auf ein inneres Gruppenmitglied, wird er
    /// deshalb vor den gesamten Cluster gezogen. Reorder innerhalb derselben
    /// Gruppe behält dagegen die genaue Zielposition.
    static func adjustedDropTarget(
        before requestedID: UUID?,
        movingIDs: Set<UUID>,
        movingKeys: Set<AgentTabGroupingKey>,
        items: [AgentTabGroupingItem]
    ) -> UUID? {
        guard let requestedID else { return nil }

        for (index, item) in items.enumerated() {
            guard case .group(let targetKey, let sessionIDs) = item,
                  sessionIDs.contains(requestedID) else { continue }

            if movingKeys == [targetKey] {
                return requestedID
            }

            if let firstStationaryID = sessionIDs.first(where: { !movingIDs.contains($0) }) {
                return firstStationaryID
            }

            return items.dropFirst(index + 1)
                .flatMap(\.sessionIDs)
                .first(where: { !movingIDs.contains($0) })
        }

        return requestedID
    }
}

private extension AgentTabGroupingItem {
    var sessionIDs: [UUID] {
        switch self {
        case .single(let id): [id]
        case .group(_, let ids): ids
        }
    }
}
