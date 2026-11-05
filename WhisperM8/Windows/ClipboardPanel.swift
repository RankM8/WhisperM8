import AppKit
import SwiftUI

/// Panel des Verlaufs: nimmt Tastatur an (Suchfeld), ohne die App nach vorn
/// zu holen. Die vorherige App bleibt aktiv, Einfügen geht also dorthin zurück.
final class ClipboardPanel: NSPanel {
    var onCommand: ((ClipboardKeyCommand) -> Bool)?
    /// Große Bildansicht offen: Tasten gehen nicht ans Suchfeld.
    var isImageZoomed: () -> Bool = { false }
    var onResignKey: (() -> Void)?

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: ClipboardHistoryView.size),
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
        // In der großen Ansicht darf Tippen die Suche nicht ändern: sonst
        // springt die Auswahl und Enter fügt etwas anderes ein, als zu sehen ist.
        if event.type == .keyDown, isImageZoomed() {
            if let command = ClipboardKeyCommand.resolveWhileZoomed(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers?.lowercased(),
                modifiers: event.modifierFlags
            ) {
                _ = onCommand?(command)
            }
            return
        }
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

    /// Fokus ins Suchfeld, auch wenn `@FocusState` beim ersten Zeigen zu früh
    /// kam (das Panel war da noch nicht Key-Fenster).
    func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = Self.firstEditableTextField(in: self.contentView) else { return }
            if let editor = self.firstResponder as? NSTextView, editor.delegate === field { return }
            self.makeFirstResponder(field)
        }
    }

    private static func firstEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstEditableTextField(in: subview) { return field }
        }
        return nil
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onCommand?(.close)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
