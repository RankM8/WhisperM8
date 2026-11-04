import AppKit
import SwiftUI

/// Panel des Verlaufs: nimmt Tastatur an (Suchfeld), ohne die App nach vorn
/// zu holen. Die vorherige App bleibt aktiv, Einfügen geht also dorthin zurück.
final class ClipboardPanel: NSPanel {
    var onCommand: ((ClipboardKeyCommand) -> Bool)?
    var onResignKey: (() -> Void)?

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.contentView = contentView
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           let command = ClipboardKeyCommand.resolve(
               keyCode: event.keyCode,
               characters: event.charactersIgnoringModifiers?.lowercased(),
               modifiers: event.modifierFlags
           ),
           onCommand?(command) == true {
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onCommand?(.close)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
