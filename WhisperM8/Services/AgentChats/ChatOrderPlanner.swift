import Foundation

// MARK: - Reihenfolge der Chats eines Projekts (`whisperm8 chats order`)

/// Pure Ordnungslogik für `chats order`: welche Folge die Seitenleiste eines
/// Projekts nach dem Befehl hat. Die App schreibt sie danach per
/// `AgentSessionStore.reorderSessions(in:orderedIDs:)`, die Projekt-Ansicht
/// folgt über `WorkspaceSlotOps.reorderedSlots(_:order:)`.
enum ChatOrderPlanner {
    /// - `current`: heutige Folge der Seitenleiste (alle nicht archivierten
    ///   Chats des Projekts, sortiert wie `AgentSessionStore.sortedSessions`).
    /// - `first`: diese Chats kommen in genau dieser Folge nach vorn.
    /// - `last`: diese Chats kommen in genau dieser Folge ans Ende.
    /// Alle übrigen behalten ihre relative Folge dazwischen. Unbekannte IDs
    /// und doppelte Nennungen fallen still weg (die Prüfung macht der Aufrufer).
    static func plannedOrder(current: [UUID], first: [UUID], last: [UUID]) -> [UUID] {
        let known = Set(current)
        var seen = Set<UUID>()
        func unique(_ ids: [UUID]) -> [UUID] {
            ids.filter { known.contains($0) && seen.insert($0).inserted }
        }
        let head = unique(first)
        let tail = unique(last)
        let middle = current.filter { !seen.contains($0) }
        return head + middle + tail
    }

    /// Tab-Folge eines Fensters nach `chats order --tabs`: Die Tabs von
    /// `block` (die Tabs EINES Projekts in ihrer neuen Folge) rücken als Block
    /// an die Stelle des ersten von ihnen; Tabs anderer Projekte behalten
    /// ihre Folge davor und dahinter.
    static func tabBlockOrder(window: [UUID], block: [UUID]) -> [UUID] {
        let members = Set(block)
        guard let start = window.firstIndex(where: members.contains) else { return window }
        let others = window.filter { !members.contains($0) }
        let insertAt = window[..<start].filter { !members.contains($0) }.count
        return Array(others[..<insertAt]) + block.filter { window.contains($0) } + Array(others[insertAt...])
    }
}

extension WorkspaceSlotOps {
    /// Bringt die belegten Plätze einer Projekt-Ansicht in die Folge `order`
    /// (Seitenleiste nach `chats order`). Leere Plätze bleiben, wo sie sind;
    /// Chats, die `order` nicht kennt, behalten ihre relative Folge hinter den
    /// bekannten. Pure, damit die Plätze sonst positionsstabil bleiben dürfen
    /// (`syncedProjectSlots`) und nur dieser Befehl sie bewusst umsetzt.
    static func reorderedSlots(_ current: [UUID?], order: [UUID]) -> [UUID?] {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let occupied = current.compactMap { $0 }
        let sorted = occupied.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element] ?? Int.max
            let right = rank[rhs.element] ?? Int.max
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        var iterator = sorted.makeIterator()
        return current.map { slot in slot == nil ? nil : iterator.next() }
    }
}
