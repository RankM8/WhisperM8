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
            IslandKeycap(text: display.model.keyboard?.cheatSheet == true ? "?" : "⇥", palette: palette)
        }
        .accessibilityLabel(Text("Option-Tab"))
    }

    // MARK: Tastenzeile (Paket 2)

    /// Unter der Liste: links die Befehle für den aktuellen Chat (der steht
    /// dabei, damit man ihn nicht mit der Markierung verwechselt), darunter
    /// die App-Befehle. Jeder Buchstabe steht sichtbar am Eintrag.
    func keyboardCommandRow(_ commands: ControllerKeyboardCommands) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                keyRowLabel(chatLabel(commands))
                IslandFlow(spacing: 12, lineSpacing: 5) {
                    ForEach(KeyboardIslandCommand.chatCommands, id: \.self) { keyRowItem($0, commands) }
                }
                keyRowLabel(String(localized: "App")).padding(.top, 7)
                IslandFlow(spacing: 12, lineSpacing: 5) {
                    ForEach(KeyboardIslandCommand.appCommands, id: \.self) { keyRowItem($0, commands) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.slot, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            // Nach N oder A: was jetzt gilt und was der nächste Druck bringt.
            if let confirmation = commands.slots.confirmation {
                let key: KeyboardIslandCommand = confirmation.slot == .alerts ? .alerts : .stayAwake
                self.confirmation(confirmation, app: commands.slots.app, keyGlyph: commands.letter(key))
            }
        }
    }

    private func chatLabel(_ commands: ControllerKeyboardCommands) -> String {
        let title = commands.chatTitle ?? String(localized: "Chat")
        if commands.dictating { return String(localized: "for \(title) · off while dictation runs") }
        if commands.slots.note == .question { return String(localized: "for \(title) · question open") }
        return String(localized: "for \(title)")
    }

    private func keyRowLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.bottom, 5)
    }

    private func keyRowItem(_ command: KeyboardIslandCommand, _ commands: ControllerKeyboardCommands) -> some View {
        let hit = commands.isHit(command)
        return HStack(spacing: 5) {
            IslandKeycap(text: commands.letter(command), held: hit, palette: palette)
            Text(verbatim: command.keyRowTitle(commands))
                .font(.system(size: 12))
                .foregroundStyle(hit ? Color.white : palette.hint)
        }
        .fixedSize()
        .opacity(commands.isEnabled(command) || hit ? 1 : 0.36)
    }

    // MARK: Spickzettel (?)

    /// Schreib-Tasten: L1 braucht auf der Tastatur keine Ebene, jede Funktion
    /// hat schon eine Taste. Hier stehen sie an einer Stelle.
    var keyboardCheatSheet: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(KeyboardIslandCheatSheet.rows, id: \.label) { row in
                    GridRow {
                        HStack(spacing: 3) {
                            ForEach(row.keys, id: \.self) { IslandKeycap(text: $0, palette: palette) }
                        }
                        .gridColumnAlignment(.trailing)
                        Text(verbatim: row.label)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.hint)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
            IslandFlow(spacing: 12, lineSpacing: 5) {
                keyItem(["⌥"], String(localized: "release: close"), on: true)
                Text(verbatim: String(localized: "the keys also work without the island"))
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .center)
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
    }

    /// Fußzeile der Limits-Karte per Tastatur.
    func keyboardLimitsFooter(_ card: ControllerLimitsCard) -> some View {
        IslandFlow(spacing: 12, lineSpacing: 5) {
            if card.canScroll { keyItem(["↑", "↓"], String(localized: "scroll"), on: true) }
            if card.canRefresh {
                keyItem(["↩"], card.isLoading ? String(localized: "refreshing …") : String(localized: "refresh"), on: true)
            }
            keyItem(["L"], String(localized: "back to the list"), on: true)
            keyItem(["⌥"], String(localized: "release: close"), on: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    /// Fußzeile: was die Tasten jetzt tun. Im Reiter „Workspaces & Projekte“
    /// gibt es nur eine Richtung zurück zu den Chats, und W/R wirken dort
    /// nicht sichtbar mit; während eines Diktats heißt Leertaste „stopp“ und Esc
    /// schließt nur die Insel.
    func keyboardFooter(_ state: ControllerWhereToState, dictating: Bool, releaseSwitches: Bool = true) -> some View {
        IslandFlow(spacing: 12, lineSpacing: 5) {
            ForEach(Array(KeyboardIslandFooter.items(tab: state.tab, dictating: dictating,
                                                     canReopen: state.reopenTitle != nil,
                                                     releaseSwitches: releaseSwitches).enumerated()),
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

    func keyItem(_ keys: [String], _ label: String, on: Bool) -> some View {
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

    static func items(tab: ControllerIslandTab, dictating: Bool, canReopen: Bool, releaseSwitches: Bool = true) -> [Item] {
        // Nach einem Schalter (N, A) wechselt das Loslassen nicht, bis sich die
        // Markierung bewegt — genau das steht dann da (Entwurf, Zustand 4).
        guard releaseSwitches else {
            return [Item(keys: ["⌥"], label: String(localized: "release: nothing switches (marker unmoved)"))]
        }
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

/// Spickzettel der Schreib-Tasten (?), pur.
enum KeyboardIslandCheatSheet {
    struct Row: Equatable {
        var keys: [String]
        var label: String
    }

    static var rows: [Row] {
        [
            Row(keys: ["⌘", "⌫"], label: String(localized: "delete to line start")),
            Row(keys: ["⇧", "↩"], label: String(localized: "new line without sending")),
            Row(keys: ["⌥", "←", "→"], label: String(localized: "word back / forward")),
            Row(keys: ["↑", "↓"], label: String(localized: "line up / down in the draft")),
            Row(keys: ["⌘", "V"], label: String(localized: "paste")),
            Row(keys: ["esc"], label: String(localized: "Escape to Claude")),
            Row(keys: ["⌃", "_"], label: String(localized: "undo (Claude)")),
        ]
    }
}

extension KeyboardIslandCommand {
    /// Kurzer Name in der Tastenzeile (Entwurf: „Jetzt senden“, „Modus“ …).
    func keyRowTitle(_ commands: ControllerKeyboardCommands) -> String {
        switch self {
        case .sendNow: return commands.slots.crossTitle
        case .cycleMode: return String(localized: "Mode")
        case .transcript: return String(localized: "Transcript")
        case .commands: return String(localized: "Commands ›")
        case .account: return String(localized: "Account ›")
        case .limits: return String(localized: "Limits")
        case .alerts: return String(localized: "Alerts")
        case .stayAwake: return String(localized: "Stay awake")
        case .clipboard: return String(localized: "Clipboard")
        }
    }
}
