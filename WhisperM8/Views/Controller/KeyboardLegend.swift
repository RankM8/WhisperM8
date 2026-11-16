import KeyboardShortcuts
import SwiftUI

/// Legende unten im Fenster per Tastatur (WM8-104, Paket 3). Entscheidung
/// Giuliano 15.11.2026: Sie folgt dem zuletzt benutzten Gerät, aber nur mit
/// eingeschalteter Controller-Steuerung. Ist die Steuerung aus, gibt es wie
/// bisher keine Leiste; die Kürzel stehen dann in der Insel selbst.
enum KeyboardLegend {
    enum Mode: Equatable {
        case none, controller, keyboard
    }

    /// - Parameters:
    ///   - lastInput: Womit zuletzt bedient wurde (⌥Tab bzw. eine Controller-Eingabe).
    ///   - keyboardIslandEnabled: Ohne ⌥Tab nennt die Leiste keine Tastatur-Kürzel.
    static func mode(
        legendEnabled: Bool, controllerRunning: Bool, deviceConnected: Bool,
        lastInput: ControllerIslandInput, keyboardIslandEnabled: Bool
    ) -> Mode {
        guard legendEnabled, controllerRunning else { return .none }
        if deviceConnected, lastInput == .controller || !keyboardIslandEnabled { return .controller }
        return keyboardIslandEnabled ? .keyboard : .none
    }

    /// „⌥⇥ Wohin · ⌥␣ Diktieren · ⌃⇥ Raster“. Das Diktat nennt den
    /// eingestellten Hotkey; ohne Hotkey fehlt der Eintrag.
    static func items(dictationKeys: [String]?) -> [KeyboardIslandFooter.Item] {
        var items = [KeyboardIslandFooter.Item(keys: ["⌥", "⇥"], label: String(localized: "Where to"))]
        if let dictationKeys {
            items.append(KeyboardIslandFooter.Item(keys: dictationKeys, label: String(localized: "Dictate")))
        }
        items.append(KeyboardIslandFooter.Item(keys: ["⌃", "⇥"], label: String(localized: "Grid")))
        return items
    }

    /// Tasten des Ticket-Boards in der Leiste unten: in der Triage die, die
    /// früher abgeschnitten im Ticket-Kopf standen (WM8-124), auf dem Board und
    /// auf der Chat-Zeile die aus dem Plan „Tastatur“ (WM8-91 Paket 3c).
    static func ticketItems(for context: ControllerContext?) -> [KeyboardIslandFooter.Item] {
        guard case .tickets(let state)? = context, state.area == .content else { return [] }
        typealias Item = KeyboardIslandFooter.Item
        // ⌘J nur mit sichtbarem Board-Chat (WM8-91 Paket 3c), mit seinem Rufnamen.
        let jarvis: [Item] = state.place.boardChatID == nil ? [] : [
            Item(keys: ["⌘", "J"], label: "→ " + (state.place.boardChatName ?? String(localized: "Board chat"))),
        ]
        switch state.place.view {
        case .empty:
            return []
        case .board, .list:
            // Plan „Die Leiste unten“, Zustand Board (Paket 3c). Auf dem Kopf
            // einer Gruppe klappt Return auf und zu (WM8-125).
            return [
                Item(keys: ["↑", "↓", "←", "→"], label: String(localized: "Selection")),
                Item(keys: ["↩"], label: state.place.onGroup
                    ? String(localized: "Collapse or expand") : String(localized: "Open")),
                Item(keys: ["⌘", "C"], label: String(localized: "Copy link")),
                Item(keys: ["⌘", "⌥", "←", "→"], label: String(localized: "Ticket")),
            ] + jarvis + [
                Item(keys: ["⌘", "O"], label: String(localized: "Linear")),
                Item(keys: ["⌘", "R"], label: String(localized: "Refresh")),
                Item(keys: ["⌘", "K"], label: String(localized: "Menu")),
            ]
        case .triage:
            return [
                Item(keys: ["J", "K"], label: String(localized: "Ticket")),
                Item(keys: ["⌘", "C"], label: String(localized: "Copy link")),
                Item(keys: ["esc"], label: String(localized: "Board")),
            ] + jarvis
        case .chatLine:
            return [
                Item(keys: ["↩"], label: String(localized: "Go to chat")),
                Item(keys: ["esc"], label: String(localized: "List")),
                Item(keys: ["J", "K"], label: String(localized: "Ticket")),
            ]
        // Kopf und Filter (Paket 3d): Pfeile wählen, Return schaltet, Esc zurück.
        // Ebenso der Kopf der Board-Chat-Spalte (WM8-126).
        case .header, .boardChatHead:
            return [
                Item(keys: ["↑", "↓", "←", "→"], label: String(localized: "Selection")),
                Item(keys: ["↩"], label: String(localized: "Select")),
                Item(keys: ["esc"], label: String(localized: "Back")),
            ]
        case .headerPicker, .boardChatHeadPicker:
            return [
                Item(keys: ["↑", "↓"], label: String(localized: "Selection")),
                Item(keys: ["↩"], label: String(localized: "Select")),
                Item(keys: ["esc"], label: String(localized: "Close")),
            ]
        }
    }

    /// Tastenkappen des Diktat-Hotkeys: ab Werk ⌥Leertaste als „⌥ ␣“, sonst
    /// so, wie KeyboardShortcuts ihn beschreibt.
    @MainActor
    static func dictationKeys() -> [String]? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) else { return nil }
        if shortcut.key == .space, shortcut.modifiers == [.option] { return ["⌥", "␣"] }
        return [shortcut.description]
    }
}

/// Tastenkappe in der Legende: in den Farben des Fensters (hell und dunkel),
/// anders als die immer dunkle Insel.
struct LegendKeycap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(AppTheme.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(AppTheme.borderStrong, lineWidth: 1))
            .fixedSize()
    }
}
