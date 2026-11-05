import KeyboardShortcuts
import SwiftUI

struct SettingsKeyRecorderRow: View {
    let title: String
    let subtitle: String?
    let name: KeyboardShortcuts.Name

    /// Schnellaktion, die denselben Kurzbefehl nutzt (etwa Korrigieren mit
    /// ⇧⌘K). Der Recorder selbst prüft nur System und Hauptmenü.
    @State private var quickActionConflict: String?

    init(title: String, subtitle: String? = nil, name: KeyboardShortcuts.Name) {
        self.title = title
        self.subtitle = subtitle
        self.name = name
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            KeyboardShortcuts.Recorder(for: name) { shortcut in
                quickActionConflict = Self.quickActionConflict(for: shortcut, name: name)
            }
            .labelsHidden()
        }
        .onAppear {
            quickActionConflict = Self.quickActionConflict(for: KeyboardShortcuts.getShortcut(for: name), name: name)
        }
        if let quickActionConflict {
            SettingsHelpText(Self.conflictMessage(quickActionConflict), tone: .warning)
        }
    }

    /// Nur für die festen Kurzbefehle (Aufnahme, Verlauf, Notch); die
    /// Schnellaktionen prüfen sich in ihrem eigenen Abschnitt.
    static func quickActionConflict(for shortcut: KeyboardShortcuts.Shortcut?, name: KeyboardShortcuts.Name) -> String? {
        guard !name.rawValue.hasPrefix(QuickActionShortcuts.namePrefix) else { return nil }
        return QuickActionShortcuts.quickActionUsing(shortcut, modes: OutputModeStore().modes)
    }

    static func conflictMessage(_ mode: String) -> String {
        String(localized: "This shortcut is also the quick action “\(mode)” (AI Output → Modes). Only one of them will work, so pick another one.")
    }
}
