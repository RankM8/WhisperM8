import AppKit
import SwiftUI

/// Nicht aktivierendes Fenster der Notch-Anzeige: stiehlt keinen Fokus, liegt
/// über der Menüleiste, erscheint auf allen Spaces. Key-Status gibt es nur,
/// damit Esc ankommt, solange die Liste offen ist.
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

    override var canBecomeKey: Bool { true }
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
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
