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
        case .acceptSuggestion: return String(localized: "Accept suggestion")
        case .backspace: return String(localized: "Delete")
        case .newChat: return String(localized: "New chat")
        case .clipboard: return String(localized: "Clipboard")
        case .maximize: return String(localized: "Enlarge tile")
        case .menu: return String(localized: "Menu")
        case .lastChat: return String(localized: "Back to previous")
        case .pickAndDictate: return String(localized: "Switch and dictate")
        case .layersHold: return String(localized: "Hold: layers")
        case .deleteToLineStart: return String(localized: "Delete to line start")
        case .newline: return String(localized: "New line")
        case .continueWork: return String(localized: "Continue")
        case .cycleMode: return String(localized: "Switch mode")
        case .commands: return String(localized: "Commands")
        case .switchAccount: return String(localized: "Switch account")
        case .whereToHold: return String(localized: "Where to")
        case .nextWaiting: return String(localized: "Next waiting")
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
        case .clipboardWithL2: return String(localized: "Clipboard")
        case .closeView: return String(localized: "Close view")
        case .wordJump: return String(localized: "Word back / forward")
        case .lineMove: return String(localized: "Line up / down")
        case .pasteNewest: return String(localized: "Paste newest")
        case .escapeOnce: return String(localized: "Escape once")
        case .undo: return String(localized: "Undo")
        case .transcript: return String(localized: "Transcript")
        case .reopenClosed: return String(localized: "Reopen closed chat")
        case .limitsCard: return String(localized: "Limits")
        case .alertLevel: return String(localized: "Alerts")
        case .stayAwake: return String(localized: "Stay awake")
        case .clipboardWithR1: return String(localized: "Clipboard")
        }
    }

    /// Ausführlicher Text für die Belegungs-Übersicht in den Einstellungen,
    /// mit den Tastenzeichen der Familie.
    func explanation(_ family: ControllerFamily) -> String {
        let l1 = ControllerButton.l1.glyph(family), r1 = ControllerButton.r1.glyph(family)
        let l2 = ControllerButton.l2.glyph(family), r2 = ControllerButton.r2.glyph(family)
        let l3 = ControllerButton.l3.glyph(family)
        let cross = ControllerButton.cross.glyph(family), circle = ControllerButton.circle.glyph(family)
        let square = ControllerButton.square.glyph(family), triangle = ControllerButton.triangle.glyph(family)
        switch self {
        case .move: return String(localized: "Move: through the list, into the chat, from tile to tile; in a single chat, up and down mark another chat in the list")
        case .confirm: return String(localized: "Select, confirm, send; start a stopped chat")
        case .back: return String(localized: "Back, cancel")
        case .interruptHold: return String(localized: "Hold: interrupt a working chat")
        case .dictate: return String(localized: "Dictation on and off")
        case .space: return String(localized: "Type a space in the chat (Claude and Codex)")
        case .clearInputHold: return String(localized: "Hold: clear the whole input (Claude and Codex, not while the agent asks a question)")
        case .previousNextChat: return String(localized: "Tap: previous / next chat in the order of the list; in the list: Active / Recent / All. Hold: layer, see below")
        case .arrows: return String(localized: "D-pad: arrow keys in every running chat, also in subagent and workflow views; in the app you move with the left stick")
        case .scroll: return String(localized: "Scroll the conversation")
        case .acceptSuggestion: return String(localized: "Take Claude's grey suggestion into the input; \(cross) sends it")
        case .backspace: return String(localized: "Delete (hold: characters, after a second whole words; in a shell only characters)")
        case .closeHold: return String(localized: "In the list, hold: close the chat (like its − or ×)")
        case .newChat: return String(localized: "Pick a project for a new chat")
        case .clipboard: return String(localized: "Open and close the clipboard history")
        case .maximize: return String(localized: "Enlarge the tile, or go back to the grid")
        case .menu: return String(localized: "Menu: input for the chat, chat actions, controller")
        case .startChat: return String(localized: "Start a stopped chat")
        case .lastChat: return String(localized: "Tap: back to where you were before — the previous chat, or the previous workspace as a grid. Hold: layer, see below")
        case .pickAndDictate: return String(localized: "Hold \(l2), then \(r2): switch to the marked chat and dictate")
        case .deleteToLineStart: return String(localized: "Hold \(l1), then \(square): delete to the start of the line, held line by line (Claude and Codex)")
        case .newline: return String(localized: "Hold \(l1), then \(triangle): new line without sending (Claude and Codex)")
        case .continueWork: return String(localized: "Hold \(r1), then \(cross): send “Continue”")
        case .cycleMode: return String(localized: "Hold \(r1), then \(triangle): switch mode (not while the agent asks a question)")
        case .commands: return String(localized: "Hold \(r1), then \(square): open the commands in the menu")
        case .switchAccount: return String(localized: "Hold \(r1), then \(circle): open the accounts in the menu")
        case .whereToHold: return String(localized: "Hold \(l2): where to — the list starts on where you are, the previous place is one step away; up and down move, left and right switch between chats and workspaces & projects, release or \(cross) switches after a move, \(circle) cancels")
        case .nextWaiting: return String(localized: "Hold \(l2), then \(triangle): next chat that is waiting for you")
        case .pauseHold: return String(localized: "Hold both: pause and resume the controller")
        case .clipboardWithL2: return String(localized: "Hold \(l2), then press \(family.touchpadPhrase): open and close the clipboard history")
        case .closeView: return String(localized: "In Claude's views (tasks, workflows, transcript, rewind, footer selection) \(circle) closes the view, also while the chat works")
        case .wordJump: return String(localized: "Hold \(l1), then ◀ ▶: jump a word back or forward (Claude and Codex)")
        case .lineMove: return String(localized: "Hold \(l1), then ▲ ▼: line up or down in a draft with several lines, not from its first or last line")
        case .pasteNewest: return String(localized: "Hold \(l1), then \(cross): paste the newest clipboard entry; images arrive like ⌘V (images only in Claude and Codex)")
        case .escapeOnce: return String(localized: "Hold \(l1), then \(circle): send exactly one Escape — while the chat works it interrupts unless a view is open")
        case .undo: return String(localized: "Hold \(l1), then \(l3): undo (Claude)")
        case .transcript: return String(localized: "Hold \(r1), then \(l3): detailed transcript on and off (Claude)")
        case .reopenClosed: return String(localized: "Hold \(l2), then \(square): reopen the most recently closed chat; again for the one before")
        case .limitsCard: return String(localized: "Hold \(r1), then ▲: limits of all Claude and GPT accounts while \(r1) is held; \(cross) refreshes")
        case .alertLevel: return String(localized: "Hold \(r1), then ◀: sound and notifications one step further, like the bell")
        case .stayAwake: return String(localized: "Hold \(r1), then ▶: stay awake one step further, like the stay-awake button")
        case .clipboardWithR1: return String(localized: "Hold \(r1), then ▼: open and close the clipboard history")
        default: return title
        }
    }
}

extension ControllerLegendEntry {
    /// Text in der Legende; bei L2 mit dem Namen des Ziels („Zurück: Workspace
    /// Marketing“). Lange Namen werden gekürzt, damit die Leiste nicht schon
    /// wegen eines Titels Tasten weglässt.
    var title: String {
        guard let backTarget else { return label.title }
        let name = backTarget.title.count > 28 ? String(backTarget.title.prefix(27)) + "…" : backTarget.title
        switch backTarget.kind {
        case .chat: return String(localized: "Back: chat \(name)")
        case .workspace: return String(localized: "Back: workspace \(name)")
        }
    }
}

extension ControllerLegendInput {
    /// Die Symbole, mit denen diese Eingabe gezeigt wird.
    func glyphs(_ family: ControllerFamily) -> [(text: String, round: Bool)] {
        switch self {
        case let .button(button): return [(button.glyph(family), button.isRoundGlyph)]
        case .leftStick: return [("L", true)]
        case .rightStick: return [("R", true)]
        case .dpad: return [("✛", true)]
        case .bumpers: return [(ControllerButton.l1.glyph(family), false), (ControllerButton.r1.glyph(family), false)]
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
    @Environment(\.controllerFamily) private var family

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(inputs.enumerated()), id: \.offset) { index, input in
                if isCombination, index > 0 {
                    Text(verbatim: "+")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                ForEach(Array(input.glyphs(family).enumerated()), id: \.offset) { _, glyph in
                    ControllerGlyphView(text: glyph.text, round: glyph.round)
                }
            }
        }
    }
}
