import AppKit
import SwiftUI

/// Sammelt die Griffflächen des Titelbands (siehe `WindowMovability`).
struct WindowDragAreasKey: PreferenceKey {
    static let defaultValue: [WindowDragArea] = []

    static func reduce(value: inout [WindowDragArea], nextValue: () -> [WindowDragArea]) {
        value.append(contentsOf: nextValue())
    }
}

/// Gemessene Griffflächen. Wie `GridPaneFrameCache` eine Klasse in einem nicht
/// beobachteten `@State`: Layout-Messungen dürfen keinen View-Neuaufbau auslösen.
final class WindowDragAreaCache {
    var areas: [WindowDragArea] = []
}

extension View {
    /// Weist die Fläche als Griff zum Fenster-Verschieben aus. `depth` ist ihre
    /// Unterkante ab Fensteroberkante. Nur für freie Flächen im Titelband —
    /// alles andere dort ist bewusst nicht verschiebbar, damit Klicks ankommen.
    func windowDragArea(depth: CGFloat) -> some View {
        background(
            GeometryReader { geo in
                let frame = geo.frame(in: .named(AgentChatsView.windowCoordinateSpaceName))
                Color.clear.preference(
                    key: WindowDragAreasKey.self,
                    value: frame.width > 0
                        ? [WindowDragArea(xRange: frame.minX...frame.maxX, depth: depth)]
                        : []
                )
            }
        )
    }
}

/// Meldet die Zeigerposition, solange die Maus im Titelband liegt.
///
/// `window.isMovable` muss stimmen, BEVOR geklickt wird: macOS entscheidet beim
/// Mausdruck anhand des vorher gemeldeten Zustands, ob es das Fenster zieht —
/// ein Umschalten erst im `leftMouseDown`-Monitor kommt zu spät (siehe
/// `multiwindow-architecture.md`, Abschnitt 7). SwiftUI-`onHover` taugt dafür
/// nur bedingt, weil es `onHover(false)` verlieren kann. Eine AppKit-
/// Tracking-Area liefert dagegen jede Bewegung, und jede Bewegung entscheidet
/// frisch — hängen bleiben kann nichts.
///
/// Die View nimmt nie einen Klick an (`hitTest` → `nil`) und verfolgt nur das
/// schmale Band, nicht das ganze Fenster.
struct TitleBandPointerTracker: NSViewRepresentable {
    var bandHeight: CGFloat
    /// Zeiger im Band, Position in AppKit-Fensterkoordinaten.
    var onPointerMoved: (CGPoint) -> Void
    var onPointerExited: () -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: TrackerView) {
        view.onPointerMoved = onPointerMoved
        view.onPointerExited = onPointerExited
        if view.bandHeight != bandHeight {
            view.bandHeight = bandHeight
            view.updateTrackingAreas()
        }
    }

    final class TrackerView: NSView {
        var bandHeight: CGFloat = 0
        var onPointerMoved: (CGPoint) -> Void = { _ in }
        var onPointerExited: () -> Void = {}
        private var bandArea: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let bandArea { removeTrackingArea(bandArea) }
            let height = min(bandHeight, bounds.height)
            let originY = isFlipped ? bounds.minY : bounds.maxY - height
            let area = NSTrackingArea(
                rect: NSRect(x: bounds.minX, y: originY, width: bounds.width, height: height),
                // `.activeAlways`: auch der erste Klick in ein Hintergrundfenster
                // soll einen Knopf treffen und nicht das Fenster ziehen.
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                owner: self
            )
            addTrackingArea(area)
            bandArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onPointerMoved(event.locationInWindow)
        }

        override func mouseMoved(with event: NSEvent) {
            onPointerMoved(event.locationInWindow)
        }

        override func mouseExited(with event: NSEvent) {
            onPointerExited()
        }
    }
}
