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
