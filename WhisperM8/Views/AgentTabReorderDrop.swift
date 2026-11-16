import SwiftUI
import UniformTypeIdentifiers

/// Etappe-0 des Tab-Drag-Redesigns: echte Einfüge-Linie + Move-Semantik
/// (kein Copy-„+") für die obere Tab-Leiste — ohne AppKit, unter Beibehaltung
/// des System-Drags (damit Cross-Window-Move via `DraggableSession` erhalten
/// bleibt). Tear-off (Tab → neues Fenster) ist bewusst NICHT Teil davon.

// MARK: - Reine Geometrie (testbar, ohne SwiftUI-Laufzeit)

/// Berechnet Einfüge-Index und -Position aus gemessenen Tab-Frames. Die Frames
/// liegen im selben (gescrollten) Inhalts-Koordinatenraum wie die Drop-Location
/// → scroll-sicher, kein `.global`/`.local`-Mismatch.
enum TabReorderGeometry {
    /// Einfüge-Index = Anzahl Tabs, deren Mittelpunkt links der Cursor-X liegt.
    /// Reihenfolge-/lückentolerant (fehlende Frames zählen einfach nicht mit).
    static func insertionIndex(atX x: CGFloat, orderedIDs: [UUID], frames: [UUID: CGRect]) -> Int {
        orderedIDs.reduce(into: 0) { count, id in
            if let mid = frames[id]?.midX, mid < x { count += 1 }
        }
    }

    /// X-Position der Einfüge-Linie für `index` (0 … count). `nil`, wenn die
    /// nötigen Frames noch nicht gemessen sind.
    static func insertionX(forIndex index: Int, orderedIDs: [UUID], frames: [UUID: CGRect], spacing: CGFloat) -> CGFloat? {
        guard !orderedIDs.isEmpty else { return nil }
        let clamped = max(0, min(index, orderedIDs.count))
        if clamped == 0 {
            guard let first = frames[orderedIDs[0]] else { return nil }
            return first.minX - spacing / 2
        }
        if clamped == orderedIDs.count {
            guard let last = frames[orderedIDs[orderedIDs.count - 1]] else { return nil }
            return last.maxX + spacing / 2
        }
        guard let left = frames[orderedIDs[clamped - 1]], let right = frames[orderedIDs[clamped]] else { return nil }
        return (left.maxX + right.minX) / 2
    }
}

// MARK: - Gruppen-Reorder (Multi-Tab-Drag)

/// Reine, testbare Block-Reorder-Logik für einen oder mehrere Tabs: die
/// bewegten IDs werden als zusammenhängender Block vor `beforeID` einsortiert
/// (nil = ans Ende) und behalten ihre Relativ-Reihenfolge. Eingabe ist die
/// SICHTBARE Reihenfolge — sie wird dadurch zur neuen manuellen Reihenfolge.
enum TabOrderReorder {
    static func newOrder(_ order: [UUID], moving group: Set<UUID>, before beforeID: UUID?) -> [UUID] {
        let moved = order.filter { group.contains($0) }
        guard !moved.isEmpty else { return order }
        if let beforeID, group.contains(beforeID) { return order }
        let rest = order.filter { !group.contains($0) }
        guard let beforeID, let index = rest.firstIndex(of: beforeID) else {
            return rest + moved
        }
        var result = rest
        result.insert(contentsOf: moved, at: index)
        return result
    }
}

// MARK: - Frame-Messung pro Tab

/// Sammelt die Frames aller Tabs (Tab-ID → Rect im Inhalts-Space).
struct TabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { current, new in
            current.union(new)
        }
    }
}

// MARK: - Drop-Delegate (Move-Semantik + kontinuierliche Einfüge-Position)

/// `DropDelegate` für die Tab-Leiste. Liefert über `dropUpdated` kontinuierlich
/// die Einfüge-Position (→ Linie) und ein `DropProposal(.move)` (→ kein „+").
/// Der eigentliche Move bleibt in der View (`onMove`) und nutzt weiterhin
/// `windowStore.moveTab` inkl. Cross-Window + Sidebar-Open.
/// `DropDelegate` der Tab-Leiste. Arbeitet auf SLOT-Indizes statt auf
/// Tab-IDs: `orderedIDs` sind die Leading-IDs der Slots, eine eingeklappte
/// Gruppe erscheint darin genau einmal. Dadurch hat sie eine eigene
/// Einfügeposition, ohne aufgeklappt werden zu müssen.
struct TabReorderDropDelegate: DropDelegate {
    let orderedIDs: [UUID]
    let frames: [UUID: CGRect]
    @Binding var insertionIndex: Int?
    @Binding var droppedSession: DraggableSession?
    /// Zählt jeden Strip-Eintritt hoch. Das Dekodieren des Payloads ist
    /// asynchron; ohne dieses Token könnte ein spät zurückkommender Callback
    /// eines ABGEBROCHENEN Drags den Payload des aktuellen überschreiben —
    /// der Drop verschöbe dann den falschen Tab.
    @Binding var dragGeneration: Int
    /// Verschiebt einen rohen geometrischen Index auf die nächste ERLAUBTE
    /// Slot-Grenze (Gruppen bleiben unteilbar, Mitglieder in ihrem Cluster).
    let snapIndex: (DraggableSession, Int) -> Int
    /// Slot-Index, vor dem eingefügt wird (`slots.count` = ans Ende). Wird auf
    /// dem Main-Thread aufgerufen.
    let onMove: (DraggableSession, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.agentChatSession])
    }

    func dropEntered(info: DropInfo) {
        dragGeneration &+= 1
        let generation = dragGeneration
        updateInsertion(atX: info.location.x)
        guard droppedSession == nil,
              let provider = info.itemProviders(for: [.agentChatSession]).first else {
            return
        }
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.agentChatSession.identifier
        ) { data, _ in
            guard let data,
                  let dropped = try? JSONDecoder().decode(
                    DraggableSession.self,
                    from: data
                  ) else { return }
            DispatchQueue.main.async {
                // Nur der Callback des LAUFENDEN Drags zählt: ein beendeter
                // (dropExited/performDrop) oder überholter Drag darf den
                // Payload nicht mehr setzen.
                guard generation == dragGeneration, let current = insertionIndex else { return }
                droppedSession = dropped
                insertionIndex = snapIndex(dropped, current)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertion(atX: info.location.x)
        // .move → System zeigt kein grünes Copy-Plus mehr.
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Generation hochzählen: ein noch laufender Decode gehört ab jetzt zu
        // einem beendeten Drag und wird verworfen.
        dragGeneration &+= 1
        insertionIndex = nil
        droppedSession = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let rawIndex = rawInsertionIndex(atX: info.location.x)
        dragGeneration &+= 1
        insertionIndex = nil

        if let droppedSession {
            self.droppedSession = nil
            onMove(droppedSession, snapIndex(droppedSession, rawIndex))
            return true
        }

        guard let provider = info.itemProviders(for: [.agentChatSession]).first else {
            return false
        }
        let move = onMove
        let snap = snapIndex
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.agentChatSession.identifier
        ) { data, _ in
            guard let data,
                  let dropped = try? JSONDecoder().decode(
                    DraggableSession.self,
                    from: data
                  ) else { return }
            DispatchQueue.main.async {
                move(dropped, snap(dropped, rawIndex))
            }
        }
        return true
    }

    private func updateInsertion(atX x: CGFloat) {
        let raw = rawInsertionIndex(atX: x)
        insertionIndex = droppedSession.map { snapIndex($0, raw) } ?? raw
    }

    private func rawInsertionIndex(atX x: CGFloat) -> Int {
        TabReorderGeometry.insertionIndex(atX: x, orderedIDs: orderedIDs, frames: frames)
    }
}

// MARK: - Sichtbare Hilfs-Views

/// 2,5pt-Einfüge-Linie zwischen zwei Tabs (Akzentfarbe).
struct TabInsertionIndicator: View {
    var body: some View {
        Capsule()
            .fill(AgentTheme.accent)
            .frame(width: 2.5, height: 20)
            .transition(.opacity)
    }
}

/// Schlanke, opake Drag-Vorschau (kein Material → kein Schwarz-Render-Bug auf
/// macOS). Bei Multi-Drag zeigt ein „+N"-Badge die Gruppengröße.
struct TabDragPreview: View {
    let title: String
    var extraCount: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(AgentTheme.accent, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 220)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AgentTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}
