import Foundation

// Einträge der Ebene „Schreiben“ (L1) in der Insel: Taste, Zeichen und Text.
// Runde 5 ergänzt Wortsprung, Zeilen, Einfügen, Escape und Rückgängig; die
// Insel zeichnet sie in derselben Zeile wie bisher.

extension ControllerWritingSlots.Hint {
    var button: ControllerButton {
        switch self {
        case .deleteLine: return .square
        case .newline: return .triangle
        case .wordJump: return .dpadLeft
        case .lineMove: return .dpadUp
        case .paste: return .cross
        case .escape: return .circle
        case .undo: return .l3
        }
    }

    /// Eigenes Zeichen statt des Tastensymbols (zwei Richtungen).
    var glyph: String? {
        switch self {
        case .wordJump: return "◀▶"
        case .lineMove: return "▲▼"
        default: return nil
        }
    }

    func label(_ slots: ControllerWritingSlots) -> String {
        switch self {
        case .deleteLine: return String(localized: "Delete to line start")
        case .newline: return String(localized: "New line")
        case .wordJump: return String(localized: "Word back / forward")
        case .lineMove: return String(localized: "Line up / down")
        case .escape: return String(localized: "Escape once")
        case .undo: return String(localized: "Undo")
        case .paste:
            guard let clip = slots.clip else { return String(localized: "Nothing to paste") }
            switch clip.kind {
            case .image:
                if let width = clip.imageWidth, let height = clip.imageHeight {
                    return String(localized: "Paste image · \(width) × \(height)")
                }
                return String(localized: "Paste image")
            case .text:
                let preview = clip.preview.count > 28 ? String(clip.preview.prefix(27)) + "…" : clip.preview
                return String(localized: "Paste “\(preview)”")
            }
        }
    }
}

extension ControllerQuickDrawSlots {
    /// Beschriftung von Kreuz in der R1-Raute: „Weiter“, „Senden“ oder
    /// „Jetzt senden“ (Runde 5, R1).
    var crossTitle: String {
        switch cross {
        case .send?: return String(localized: "Send")
        case .sendNow?: return String(localized: "Send now")
        case .continueWork?, nil: return ControllerMenuItem.continueWork.islandTitle
        }
    }
}
