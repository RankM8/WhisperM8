import AppKit
import SwiftUI

/// Nicht aktivierendes Fenster der Notch-Anzeige: stiehlt keinen Fokus, liegt
/// über der Menüleiste, erscheint auf allen Spaces. Key-Status gibt es nur,
/// damit Esc ankommt, solange die Liste offen ist (`allowsKey`).
final class NotchPanel: NSPanel {
    /// Esc im aufgeklappten Zustand.
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Über der Menüleiste, aber unter Systemdialogen.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        titleVisibility = .hidden
    }

    /// Key nur, solange die Liste per Klick offen ist (für Esc). Sonst bleibt
    /// die Tastatur bei der App, in der man gerade arbeitet.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Borderless-Fenster werden sonst unter die Menüleiste geschoben, die
    /// Notch-Verlängerung muss aber bündig an der Oberkante liegen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Hosting-View, die den ersten Klick annimmt: ein nicht aktivierendes Fenster
/// ist beim ersten Klick noch nicht Key, der Klick soll trotzdem ankommen.
///
/// Pille ohne Notch: Hier (am Event-Einstieg für SwiftUI, wie bei
/// `PillHitTestHostingView` der Diktat-Pille) wird zwischen Klick, Ziehen und
/// Doppelklick unterschieden. Ab 4 pt Bewegung zieht die Pille, darunter ist
/// es ein Klick; SwiftUI sieht diese Ereignisse dann nicht.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Gesetzt nur für die Pille ohne Notch.
    var pillMouse: NotchPillMouse?
    /// Liste offen: `pillMouse` gilt nur für den Kopf (Pillenhöhe), die
    /// Zeilen bleiben Knöpfe.
    var pillHeaderOnly = false
    /// Liste wächst nach oben: Der Kopf liegt unten.
    var pillHeaderAtBottom = false

    private var pressStart: CGPoint?
    private var pressMoved = false

    /// Kopfbereich aus den Maßen im Moment des Klicks, nicht aus einem
    /// vorab gemeldeten Rahmen: Während der Größen-Animation stimmt nur das.
    private func handlesPill(_ event: NSEvent) -> Bool {
        guard pillMouse != nil else { return false }
        guard pillHeaderOnly else { return true }
        return NotchPillPlacement.isInHeader(
            y: event.locationInWindow.y, panelHeight: bounds.height, headerAtBottom: pillHeaderAtBottom)
    }

    override func mouseDown(with event: NSEvent) {
        guard let pillMouse, handlesPill(event) else { return super.mouseDown(with: event) }
        if event.clickCount >= 2 {
            pressStart = nil
            return pillMouse.doubleClick()
        }
        pressStart = NSEvent.mouseLocation
        pressMoved = false
        pillMouse.began()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pillMouse, let start = pressStart else { return super.mouseDragged(with: event) }
        let now = NSEvent.mouseLocation
        let offset = CGVector(dx: now.x - start.x, dy: now.y - start.y)
        if !pressMoved, hypot(offset.dx, offset.dy) < NotchPillPlacement.dragThreshold { return }
        pressMoved = true
        pillMouse.dragged(offset)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pillMouse, pressStart != nil else { return super.mouseUp(with: event) }
        pressStart = nil
        pillMouse.ended(pressMoved)
    }
}
