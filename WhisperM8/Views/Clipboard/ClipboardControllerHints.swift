import SwiftUI

/// Hinweise der Fußzeile im Verlauf: Ist die Controller-Steuerung aktiv und
/// ein Controller verbunden, stehen dort seine Tasten statt der Tastenkürzel —
/// aus derselben Tabelle wie die Legende (`ControllerLegend`), damit Belegung
/// und Anzeige nicht auseinanderlaufen. Eigene kleine View: Nur sie
/// beobachtet den `ControllerStatus`.
struct ClipboardControllerHints<Keyboard: View>: View {
    let state: ControllerClipboardState
    @State private var status: ControllerStatus
    private let keyboard: () -> Keyboard

    init(
        state: ControllerClipboardState,
        status: ControllerStatus? = nil,
        @ViewBuilder keyboard: @escaping () -> Keyboard
    ) {
        self.state = state
        _status = State(initialValue: status ?? ControllerManager.shared.status)
        self.keyboard = keyboard
    }

    var body: some View {
        if status.isRunning, status.device != nil {
            HStack(spacing: 12) {
                ForEach(Array(ControllerLegend.entries(for: .clipboardPanel(state)).enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 5) {
                        ControllerInputGlyphs(inputs: entry.inputs, isCombination: entry.isCombination)
                        Text(verbatim: entry.label.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .fixedSize()
                }
            }
        } else {
            keyboard()
        }
    }
}

extension ClipboardControllerMenuItem {
    func title(selected: ClipboardEntry?) -> String {
        switch self {
        case .pin: return selected?.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin")
        case .pastePlain: return String(localized: "Paste as plain text")
        case .correctSelection: return String(localized: "Correct Selection")
        case .clearHistory: return String(localized: "Clear History…")
        case .settings: return String(localized: "Settings…")
        }
    }
}

extension ClipboardHistoryViewModel {
    /// Zeilen des Controller-Menüs für das gemeinsame Panel.
    func controllerMenuRows(for menu: ControllerListMenu<ClipboardControllerMenuItem>) -> [ControllerMenuRow] {
        menu.entries.map { entry in
            ControllerMenuRow(
                id: entry.id.rawValue, title: entry.id.title(selected: selectedEntry),
                enabled: entry.enabled, startsGroup: entry.id == .clearHistory)
        }
    }
}
