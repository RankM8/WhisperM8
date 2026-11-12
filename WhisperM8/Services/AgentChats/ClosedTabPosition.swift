import Foundation

/// Wo ein geschlossener Tab in der Tab-Leiste seines Fensters stand — damit
/// ⇧⌘T und `chats reopen` ihn an dieselbe Stelle zurücksetzen statt ans Ende
/// (E2E-Befund 12.11.2026). Pure, getestet in `ClosedTabPositionTests`.
///
/// Anker ist der LINKE Nachbar, der offen bleibt: Beim Sammel-Schließen
/// mehrerer benachbarter Tabs und Wiederöffnen in umgekehrter Reihenfolge
/// (LIFO) ergibt das wieder die alte Reihenfolge — mit dem rechten Nachbarn
/// als Anker kämen die Tabs vertauscht zurück.
struct ClosedTabPosition: Equatable {
    /// Index in der Tab-Liste vor dem Schließen (Rückfall, wenn der Anker weg ist).
    var index: Int
    /// Nächster Tab links davon, der beim Schließen offen blieb; `nil` = ganz vorn.
    var previousTabID: UUID?

    /// Positionen der entfernten Tabs, gemessen an der Liste VOR dem Schließen.
    static func positions(of removed: [UUID], in before: [UUID]) -> [UUID: ClosedTabPosition] {
        let removedSet = Set(removed)
        var result: [UUID: ClosedTabPosition] = [:]
        var lastStaying: UUID?
        for (index, id) in before.enumerated() {
            if removedSet.contains(id) {
                result[id] = ClosedTabPosition(index: index, previousTabID: lastStaying)
            } else {
                lastStaying = id
            }
        }
        return result
    }

    /// Einfügestelle in `openTabIDs`: direkt hinter dem alten linken Nachbarn,
    /// ganz vorn, wenn es keinen gab; ist der Nachbar inzwischen zu, der alte
    /// Index (geklemmt).
    func insertionIndex(in openTabIDs: [UUID]) -> Int {
        guard let previousTabID else { return 0 }
        if let anchor = openTabIDs.firstIndex(of: previousTabID) { return anchor + 1 }
        return min(max(index, 0), openTabIDs.count)
    }
}
