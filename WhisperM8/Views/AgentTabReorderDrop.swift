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

/// Reine, testbare Block-Reorder-Logik für einen oder mehrere Tabs. Die
/// aktuelle Anzeige-Reihenfolge wird dabei zur neuen manuellen Reihenfolge.
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

/// Reine, testbare Reorder-Logik für einen Multi-Select-Drag: die `group`
/// wird als zusammenhängender Block vor `beforeID` (nil = ans Ende) einsortiert
/// und behält ihre aktuelle Relativ-Reihenfolge. Cross-Window-Gruppen sind
/// bewusst NICHT hier (Caller fällt für die auf Einzel-`moveTab` zurück).
enum TabGroupReorder {
    static func newOrder(_ order: [UUID], moving group: Set<UUID>, before beforeID: UUID?) -> [UUID] {
        guard order.filter({ group.contains($0) }).count > 1 else { return order }
        return TabOrderReorder.newOrder(order, moving: group, before: beforeID)
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
struct TabReorderDropDelegate: DropDelegate {
    let orderedIDs: [UUID]
    let frames: [UUID: CGRect]
    @Binding var insertionIndex: Int?
    /// Semantisches Ziel unabhängig von einer während des Drags wechselnden
    /// sichtbaren Reihenfolge (`nil` bedeutet bei aktivem Drag: ans Ende).
    @Binding var insertionBeforeID: UUID?
    @Binding var droppedSession: DraggableSession?
    /// Passt ein geometrisches Ziel an strukturelle Gruppen-Grenzen an.
    let normalizeBeforeID: (DraggableSession, UUID?) -> UUID?
    /// `beforeID == nil` → ans Ende. Wird auf dem Main-Thread aufgerufen.
    let onMove: (DraggableSession, UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.agentChatSession])
    }

    func dropEntered(info: DropInfo) {
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
                // Ein später Callback nach dropExited/performDrop darf keinen
                // bereits beendeten Drag wieder sichtbar machen.
                guard insertionIndex != nil else { return }
                let currentBeforeID = insertionBeforeID
                droppedSession = dropped
                setInsertion(
                    before: normalizeBeforeID(dropped, currentBeforeID)
                )
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInsertion(atX: info.location.x)
        // .move → System zeigt kein grünes Copy-Plus mehr.
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertionIndex = nil
        insertionBeforeID = nil
        droppedSession = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let rawBeforeID = beforeID(atX: info.location.x)
        insertionIndex = nil
        insertionBeforeID = nil

        if let droppedSession {
            let beforeID = normalizeBeforeID(droppedSession, rawBeforeID)
            self.droppedSession = nil
            onMove(droppedSession, beforeID)
            return true
        }

        guard let provider = info.itemProviders(for: [.agentChatSession]).first else {
            return false
        }
        let move = onMove
        let normalize = normalizeBeforeID
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.agentChatSession.identifier
        ) { data, _ in
            guard let data,
                  let dropped = try? JSONDecoder().decode(
                    DraggableSession.self,
                    from: data
                  ) else { return }
            DispatchQueue.main.async {
                move(dropped, normalize(dropped, rawBeforeID))
            }
        }
        return true
    }

    private func updateInsertion(atX x: CGFloat) {
        let rawBeforeID = beforeID(atX: x)
        if let droppedSession {
            setInsertion(
                before: normalizeBeforeID(droppedSession, rawBeforeID)
            )
        } else {
            setInsertion(before: rawBeforeID)
        }
    }

    private func setInsertion(before beforeID: UUID?) {
        insertionBeforeID = beforeID
        insertionIndex = index(before: beforeID)
    }

    private func beforeID(atX x: CGFloat) -> UUID? {
        let rawIndex = TabReorderGeometry.insertionIndex(
            atX: x,
            orderedIDs: orderedIDs,
            frames: frames
        )
        return rawIndex < orderedIDs.count ? orderedIDs[rawIndex] : nil
    }

    private func index(before beforeID: UUID?) -> Int {
        beforeID.flatMap(orderedIDs.firstIndex(of:)) ?? orderedIDs.count
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
