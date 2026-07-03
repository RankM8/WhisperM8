import AppKit
import SwiftUI

/// Drag-Handle am rechten Sidebar-Rand: ~9 pt unsichtbare Hit-Zone, die beim
/// Hover den Resize-Cursor zeigt und eine dezente Linie einblendet (Akzent
/// waehrend des Drags). Die Breiten-Logik lebt beim Aufrufer (AgentChatsView
/// + `SidebarWidthResolver`) — dieses View meldet nur Gesten.
///
/// Cursor bewusst via `set()` statt `push()/pop()`: die Hover/Drag-Ereignisse
/// kommen nicht garantiert paarig (Drag endet ausserhalb der Zone, View
/// verschwindet beim Sidebar-Toggle), ein Cursor-Stack wuerde dann leaken.
struct SidebarResizeHandle: View {
    /// Horizontale Translation seit Drag-Beginn (kumulativ, nicht Delta).
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    /// Doppelklick = Reset auf die Standardbreite (NSSplitView-Konvention).
    var onDoubleClick: () -> Void
    /// Fuer den Aufrufer: Fenster-Drag (`isMovable`) waehrend des Hovers
    /// abschalten — gleiche Mechanik wie beim Tab-Strip.
    var onHoverChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private static let hitWidth: CGFloat = 9
    private static let lineWidth: CGFloat = 2

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(isDragging ? AgentTheme.accent : AgentTheme.borderStrong)
            .frame(width: Self.lineWidth)
            .opacity(isDragging || isHovering ? 1 : 0)
            .frame(width: Self.hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                updateCursor()
                onHoverChanged(hovering)
            }
            .gesture(TapGesture(count: 2).onEnded { onDoubleClick() })
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        // Waehrend des Drags verlaesst die Maus die schmale
                        // Zone staendig — Cursor aktiv halten.
                        NSCursor.resizeLeftRight.set()
                        onDragChanged(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        updateCursor()
                        onDragEnded()
                    }
            )
            .onDisappear {
                // Sidebar-Toggle unterm Cursor: Resize-Cursor nicht
                // haengenlassen.
                if isHovering || isDragging { NSCursor.arrow.set() }
            }
    }

    private func updateCursor() {
        if isHovering || isDragging {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
