import SwiftUI

// Sichtbare Texte und Tasten-Symbole der Controller-Steuerung. Der Kern
// (`Services/Controller/Core`) kennt nur fachliche Bezeichnungen; hier werden
// daraus Texte für Legende und Einstellungsseite.

extension ControllerLegendLabel {
    /// Kurzer Text für die Legende.
    var title: String {
        switch self {
        case .send: return String(localized: "Send")
        case .confirm: return String(localized: "Confirm")
        case .back: return String(localized: "Back")
        case .reject: return String(localized: "Decline")
        case .cancel: return String(localized: "Cancel")
        case .interruptHold: return String(localized: "Hold: interrupt")
        case .start: return String(localized: "Start")
        case .dictate: return String(localized: "Dictate")
        case .stopDictation: return String(localized: "Done")
        case .stopAndSend: return String(localized: "Done and send")
        case .discard: return String(localized: "Discard")
        case .outputMode: return String(localized: "Mode")
        case .space: return String(localized: "Space")
        case .clearInputHold: return String(localized: "Hold: clear input")
        case .previousNextChat: return String(localized: "Previous / next chat")
        case .filter: return String(localized: "Active / Recent / All")
        case .move: return String(localized: "Move around")
        case .arrows: return String(localized: "Arrow keys")
        case .scroll: return String(localized: "Scroll")
        case .backspace: return String(localized: "Delete")
        case .newChat: return String(localized: "New chat")
        case .clipboard: return String(localized: "Clipboard")
        case .maximize: return String(localized: "Enlarge tile")
        case .menu: return String(localized: "Menu")
        case .lastChat: return String(localized: "Last chat")
        case .pickChatHold: return String(localized: "Hold: pick a chat")
        case .pickAndDictate: return String(localized: "Switch and dictate")
        case .switchOnRelease: return String(localized: "Release: switch")
        case .switchWorkspaceHold: return String(localized: "Hold: switch workspace")
        case .open: return String(localized: "Open")
        case .select: return String(localized: "Select")
        case .paste: return String(localized: "Paste")
        case .pin: return String(localized: "Pin")
        case .deleteHold: return String(localized: "Hold: delete")
        case .close: return String(localized: "Close")
        case .closeHold: return String(localized: "Hold: close")
        case .startChat: return String(localized: "Start chat")
        case .correctAndPaste: return String(localized: "Correct and paste")
        case .clipboardFilter: return String(localized: "All / Dictations")
        case .zoomImage: return String(localized: "Large image")
        case .clearHistory: return String(localized: "Clear History")
        case .resume: return String(localized: "Hold: resume")
        case .pauseHold: return String(localized: "Hold: pause")
        case .bringToFront: return String(localized: "Open WhisperM8")
        }
    }

    /// Ausführlicher Text für die Belegungs-Übersicht in den Einstellungen.
    var explanation: String {
        switch self {
        case .move: return String(localized: "Move: through the list, into the chat, from tile to tile; in a single chat, up and down mark another chat in the list")
        case .confirm: return String(localized: "Select, confirm, send; start a stopped chat")
        case .back: return String(localized: "Back, cancel")
        case .interruptHold: return String(localized: "Hold: interrupt a working chat")
        case .dictate: return String(localized: "Dictation on and off")
        case .space: return String(localized: "Type a space in the chat")
        case .clearInputHold: return String(localized: "Hold: clear the whole input (not while the agent asks a question)")
        case .previousNextChat: return String(localized: "Previous / next chat in the order of the list; in the list: Active / Recent / All")
        case .arrows: return String(localized: "D-pad: arrow keys only while the agent asks a question; otherwise it moves like the left stick")
        case .scroll: return String(localized: "Scroll the conversation")
        case .backspace: return String(localized: "Delete (hold: characters, after a second whole words)")
        case .closeHold: return String(localized: "In the list, hold: close the chat (like its − or ×)")
        case .newChat: return String(localized: "Pick a project for a new chat")
        case .clipboard: return String(localized: "Open and close the clipboard history")
        case .maximize: return String(localized: "Enlarge the tile, or go back to the grid")
        case .menu: return String(localized: "Menu: input for the chat, chat actions, controller")
        case .startChat: return String(localized: "Start a stopped chat")
        case .lastChat: return String(localized: "Tap: back to the previous chat")
        case .pickChatHold: return String(localized: "Hold: pick a chat, release to switch")
        case .switchWorkspaceHold: return String(localized: "In the grid, hold: pick a workspace, release to switch")
        case .pickAndDictate: return String(localized: "Hold L2, then R2: switch to that chat and dictate")
        case .pauseHold: return String(localized: "Hold both: pause and resume the controller")
        default: return title
        }
    }
}

extension ControllerButton {
    /// Name der Taste für den Tasten-Test.
    var displayName: String {
        switch self {
        case .cross: return String(localized: "Cross")
        case .circle: return String(localized: "Circle")
        case .square: return String(localized: "Square")
        case .triangle: return String(localized: "Triangle")
        case .dpadUp: return String(localized: "D-pad up")
        case .dpadDown: return String(localized: "D-pad down")
        case .dpadLeft: return String(localized: "D-pad left")
        case .dpadRight: return String(localized: "D-pad right")
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return String(localized: "Left stick click")
        case .r3: return String(localized: "Right stick click")
        case .create: return "Create"
        case .options: return "Options"
        case .touchpad: return "Touchpad"
        }
    }

    /// Zeichen auf dem Tasten-Symbol. Bewusst feste PlayStation-Zeichen statt
    /// SF Symbols: Sie sehen in jeder macOS-Version gleich aus.
    var glyph: String {
        switch self {
        case .cross: return "✕"
        case .circle: return "○"
        case .square: return "□"
        case .triangle: return "△"
        case .dpadUp: return "▲"
        case .dpadDown: return "▼"
        case .dpadLeft: return "◀"
        case .dpadRight: return "▶"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3"
        case .r3: return "R3"
        case .create: return "Create"
        case .options: return "Options"
        case .touchpad: return "Touchpad"
        }
    }

    /// Runde Tasten (Symbole, Steuerkreuz) gegen eckige (Schultertasten, Text).
    var isRoundGlyph: Bool {
        switch self {
        case .cross, .circle, .square, .triangle, .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return true
        default: return false
        }
    }
}

extension ControllerLegendInput {
    /// Die Symbole, mit denen diese Eingabe gezeigt wird.
    var glyphs: [(text: String, round: Bool)] {
        switch self {
        case let .button(button): return [(button.glyph, button.isRoundGlyph)]
        case .leftStick: return [("L", true)]
        case .rightStick: return [("R", true)]
        case .dpad: return [("✛", true)]
        case .bumpers: return [("L1", false), ("R1", false)]
        }
    }
}

/// Ein Tasten-Symbol: kleines Schild mit dem Zeichen der Taste.
struct ControllerGlyphView: View {
    let text: String
    let round: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, round ? 0 : 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: round ? 9 : 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: round ? 9 : 4, style: .continuous)
                    .strokeBorder(AppTheme.borderStrong, lineWidth: 1)
            )
            .accessibilityLabel(Text(verbatim: text))
    }
}

/// Alle Symbole einer Eingabe nebeneinander, bei Kombinationen mit Plus.
struct ControllerInputGlyphs: View {
    let inputs: [ControllerLegendInput]
    var isCombination = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(inputs.enumerated()), id: \.offset) { index, input in
                if isCombination, index > 0 {
                    Text(verbatim: "+")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                ForEach(Array(input.glyphs.enumerated()), id: \.offset) { _, glyph in
                    ControllerGlyphView(text: glyph.text, round: glyph.round)
                }
            }
        }
    }
}
