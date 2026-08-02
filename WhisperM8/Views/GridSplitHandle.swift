import AppKit
import SwiftUI

/// Drag-Griff auf einer Grid-Trennlinie: ~9 pt unsichtbare Hit-Zone über dem
/// 1-px-Divider, Hover zeigt den Resize-Cursor und eine dezente Linie
/// (Akzent während des Drags). Achsen-generische Variante des bewährten
/// `SidebarResizeHandle` — die Verhältnis-Logik lebt beim Aufrufer
/// (`GridSplitResolver`), dieses View meldet nur Gesten.
///
/// Cursor bewusst via `set()` statt `push()/pop()`: die Hover/Drag-Ereignisse
/// kommen nicht garantiert paarig (Drag endet außerhalb der Zone, Grid
/// verschwindet beim Maximize), ein Cursor-Stack würde dann leaken.
struct GridSplitHandle: View {
    enum SplitAxis {
        /// Vertikale Linie (trennt Spalten, Drag horizontal).
        case column
        /// Horizontale Linie (trennt Zeilen, Drag vertikal).
        case row
    }

    let axis: SplitAxis
    /// Translation entlang der Drag-Achse seit Drag-Beginn (kumulativ).
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    /// Doppelklick = Reset auf hälftig (NSSplitView-Konvention).
    var onDoubleClick: () -> Void
    /// Für den Aufrufer: Fenster-Drag/Pane-Klick-Routing während des
    /// Hovers aussetzen.
    var onHoverChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private static let hitSize: CGFloat = 9
    private static let lineSize: CGFloat = 2

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(isDragging ? AgentTheme.accent : AgentTheme.borderStrong)
            .frame(
                width: axis == .column ? Self.lineSize : nil,
                height: axis == .row ? Self.lineSize : nil
            )
            .opacity(isDragging || isHovering ? 1 : 0)
            .frame(
                width: axis == .column ? Self.hitSize : nil,
                height: axis == .row ? Self.hitSize : nil
            )
            .frame(
                maxWidth: axis == .row ? .infinity : nil,
                maxHeight: axis == .column ? .infinity : nil
            )
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
                        // Während des Drags verlässt die Maus die schmale
                        // Zone ständig — Cursor aktiv halten.
                        resizeCursor.set()
                        onDragChanged(axis == .column ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in
                        isDragging = false
                        updateCursor()
                        onDragEnded()
                    }
            )
            .onDisappear {
                // Grid verschwindet unterm Cursor (Maximize): Resize-Cursor
                // nicht hängenlassen.
                if isHovering || isDragging { NSCursor.arrow.set() }
            }
    }

    private var resizeCursor: NSCursor {
        axis == .column ? .resizeLeftRight : .resizeUpDown
    }

    private func updateCursor() {
        if isHovering || isDragging {
            resizeCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
