import SwiftUI

/// Gezieltes Slot-Drop-Ziel im Grid: legt beim Hovern eines Session-Drags
/// ein benanntes Feedback-Overlay über die Pane bzw. den leeren Slot
/// („X ersetzen / tauschen" · „In Slot N einfügen") — Drop-Feedback benennt
/// die Aktion (Plan F7). Eigener View-Typ, damit der Targeted-Zustand pro
/// Slot lokal lebt (kein Fenster-Body-Re-Render pro Drag-Bewegung).
struct GridSlotDropArea<Content: View>: View {
    let slotIndex: Int
    /// Titel des aktuellen Slot-Inhalts (`nil` = leerer Slot).
    let occupiedTitle: String?
    let onDrop: (DraggableSession) -> Bool
    @ViewBuilder let content: () -> Content

    @State private var isTargeted = false

    var body: some View {
        content()
            .overlay {
                if isTargeted {
                    ZStack {
                        Rectangle()
                            .fill(AgentTheme.accent.opacity(0.16))
                        Text(dropLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AgentTheme.header, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .allowsHitTesting(false)
                }
            }
            .dropDestination(for: DraggableSession.self) { items, _ in
                guard let dropped = items.first else { return false }
                return onDrop(dropped)
            } isTargeted: { isTargeted = $0 }
    }

    private var dropLabel: String {
        if let occupiedTitle {
            return "„\(occupiedTitle)“ ersetzen / tauschen"
        }
        return "In Slot \(slotIndex + 1) einfügen"
    }
}

/// Erweitern-Zone am unteren Grid-Rand („voll + Drop = wächst", Plan F8) —
/// erscheint nur während eines Drags über dem vollen Grid unterhalb der
/// Endstufe. Trennlinien bleiben KEINE Drop-Ziele (Resize-Griffe).
struct GridGrowDropZone: View {
    let label: String
    let onDrop: (DraggableSession) -> Bool

    @State private var isTargeted = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AgentTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                AgentTheme.accent.opacity(isTargeted ? 0.28 : 0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        AgentTheme.accent,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
            }
            .dropDestination(for: DraggableSession.self) { items, _ in
                guard let dropped = items.first else { return false }
                return onDrop(dropped)
            } isTargeted: { isTargeted = $0 }
    }
}
