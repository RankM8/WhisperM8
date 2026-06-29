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

// MARK: - Frame-Messung pro Tab

/// Sammelt die Frames aller Tabs (Tab-ID → Rect im Inhalts-Space).
struct TabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
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
    /// `beforeID == nil` → ans Ende. Wird auf dem Main-Thread aufgerufen.
    let onMove: (DraggableSession, UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.agentChatSession])
    }

    func dropEntered(info: DropInfo) {
        insertionIndex = TabReorderGeometry.insertionIndex(atX: info.location.x, orderedIDs: orderedIDs, frames: frames)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionIndex = TabReorderGeometry.insertionIndex(atX: info.location.x, orderedIDs: orderedIDs, frames: frames)
        // .move → System zeigt kein grünes Copy-Plus mehr.
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertionIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = TabReorderGeometry.insertionIndex(atX: info.location.x, orderedIDs: orderedIDs, frames: frames)
        insertionIndex = nil
        guard let provider = info.itemProviders(for: [.agentChatSession]).first else { return false }
        let beforeID: UUID? = index < orderedIDs.count ? orderedIDs[index] : nil
        let move = onMove
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.agentChatSession.identifier) { data, _ in
            guard let data, let dropped = try? JSONDecoder().decode(DraggableSession.self, from: data) else { return }
            DispatchQueue.main.async {
                move(dropped, beforeID)
            }
        }
        return true
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
/// macOS). Bewusst nur der Titel, damit der Snapshot robust ist.
struct TabDragPreview: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AgentTheme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 200)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AgentTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}
