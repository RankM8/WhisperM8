import AppKit
import SwiftUI

/// Erzwingt Overlay-Scroller (schmal, auto-hide, ohne hellen Track) auf der
/// NSScrollView hinter einer SwiftUI-`ScrollView`.
///
/// Hintergrund: `AppleShowScrollBars = Automatic` bedeutet „Overlay bei
/// Trackpad, **Legacy bei angeschlossener Maus**". Mit Maus bekommt jede
/// nackte `ScrollView { }` einen 15 pt breiten Legacy-Scroller mit hellem
/// Track — in der dunklen Sidebar die auffälligste Fläche im Bild.
/// `.scrollIndicators(.never)` wäre keine Lösung (bei 180+ Chats ginge die
/// Positionsanzeige verloren); stattdessen stellen wir die native AppKit-
/// Eigenschaft `scrollerStyle` auf `.overlay` um.
///
/// Mechanik: ein 0×0-`NSViewRepresentable` als `.background` des Scroll-
/// INHALTS (muss innerhalb der ScrollView hängen, sonst findet
/// `enclosingScrollView` nichts). AppKit setzt den Stil auf die System-
/// präferenz zurück, sobald sie sich ändert (z. B. Maus an-/abgesteckt) —
/// der Observer auf `preferredScrollerStyleDidChangeNotification` wendet
/// ihn dann erneut an.
private struct OverlayScrollersApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollViewFinder {
        ScrollViewFinder(frame: .zero)
    }

    func updateNSView(_ nsView: ScrollViewFinder, context: Context) {
        nsView.applyOverlayStyle()
    }

    final class ScrollViewFinder: NSView {
        private var styleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Beim Einhängen ist die ScrollView-Hierarchie u. U. noch nicht
            // komplett — im nächsten Runloop-Tick erneut anwenden.
            applyOverlayStyle()
            DispatchQueue.main.async { [weak self] in self?.applyOverlayStyle() }

            guard styleObserver == nil else { return }
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyOverlayStyle()
            }
        }

        deinit {
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
            }
        }

        func applyOverlayStyle() {
            guard let scrollView = enclosingScrollView else { return }
            guard scrollView.scrollerStyle != .overlay || !scrollView.autohidesScrollers else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
    }
}

extension View {
    /// macOS-Overlay-Scroller für die umgebende `ScrollView` erzwingen —
    /// an den INHALT der ScrollView hängen, nicht an die ScrollView selbst.
    func overlayScrollers() -> some View {
        background(OverlayScrollersApplier().frame(width: 0, height: 0))
    }
}
