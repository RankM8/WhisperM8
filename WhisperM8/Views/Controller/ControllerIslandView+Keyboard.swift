import SwiftUI

// Insel per Tastatur (⌥Tab, WM8-104): dieselbe Insel, aber Tastenkappen statt
// Controller-Zeichen in Kopf und Fußzeile (Entwurf insel-tastatur.html,
// Zustände 2, 3 und 5). Alles steht als Text da, nichts erscheint nur beim
// Überfahren mit der Maus.

extension ControllerIslandView {
    /// Kopf: „⌥ + ⇥“, ⌥ als gehaltene Taste hervorgehoben.
    var keyboardHeaderKeys: some View {
        HStack(spacing: 3) {
            IslandKeycap(text: "⌥", held: true, palette: palette)
            Text(verbatim: "+")
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiary)
            IslandKeycap(text: "⇥", palette: palette)
        }
        .accessibilityLabel(Text("Option-Tab"))
    }

    /// Fußzeile: was die Tasten jetzt tun. Im Reiter „Workspaces & Projekte“
    /// gibt es nur eine Richtung zurück zu den Chats, und W/R wirken dort
    /// nicht sichtbar mit; während eines Diktats heißt Leertaste „stopp“ und Esc
    /// schließt nur die Insel.
    func keyboardFooter(_ state: ControllerWhereToState, dictating: Bool) -> some View {
        IslandFlow(spacing: 12, lineSpacing: 5) {
            ForEach(Array(KeyboardIslandFooter.items(tab: state.tab, dictating: dictating,
                                                     canReopen: state.reopenTitle != nil).enumerated()),
                    id: \.offset) { _, item in
                keyItem(item.keys, item.label, on: item.isOn)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private func keyItem(_ keys: [String], _ label: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { IslandKeycap(text: $0, palette: palette) }
            }
            Text(verbatim: label)
        }
        .fixedSize()
        .opacity(on ? 1 : 0.38)
    }
}

/// Einträge der Fußzeile per Tastatur, pur (Snapshots, Tests).
enum KeyboardIslandFooter {
    struct Item: Equatable {
        var keys: [String]
        var label: String
        var isOn = true
    }

    static func items(tab: ControllerIslandTab, dictating: Bool, canReopen: Bool) -> [Item] {
        let release = Item(keys: ["⌥"], label: String(localized: "release: switch"))
        if dictating {
            return [
                Item(keys: ["␣"], label: String(localized: "stop")),
                Item(keys: ["⇥"], label: String(localized: "next")),
                Item(keys: ["esc"], label: String(localized: "close island only, recording continues")),
                release,
            ]
        }
        switch tab {
        case .chats:
            return [
                Item(keys: ["⇥", "⇧⇥"], label: String(localized: "next/back")),
                Item(keys: ["←", "→"], label: String(localized: "tabs")),
                Item(keys: ["␣"], label: String(localized: "go + dictate")),
                Item(keys: ["W"], label: String(localized: "waiting")),
                Item(keys: ["R"], label: canReopen ? String(localized: "reopen") : String(localized: "nothing closed"),
                     isOn: canReopen),
                Item(keys: ["esc"], label: String(localized: "cancel")),
                release,
            ]
        case .workspaces:
            return [
                Item(keys: ["⇥"], label: String(localized: "next")),
                Item(keys: ["←"], label: String(localized: "Chats")),
                Item(keys: ["␣"], label: String(localized: "dictate here")),
                Item(keys: ["esc"], label: String(localized: "cancel")),
                release,
            ]
        }
    }
}

/// Tastenkappe wie im Entwurf: abgerundet, unten etwas kräftiger. `held`: die
/// gerade gehaltene Taste (⌥), hervorgehoben.
struct IslandKeycap: View {
    let text: String
    var held = false
    let palette: IslandPalette

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(held ? Color.white : palette.text)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(held ? palette.markBorder.opacity(0.85) : palette.key,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(held ? palette.markBorder : Color.white.opacity(0.18), lineWidth: 1))
            .overlay(alignment: .bottom) {
                // Die etwas kräftigere Unterkante macht aus dem Kästchen eine Taste.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .frame(height: 1)
                    .padding(.horizontal, 3)
            }
            .fixedSize()
    }
}
