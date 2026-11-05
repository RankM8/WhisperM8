import KeyboardShortcuts
import SwiftUI

/// „Kurzbefehl ohne Diktat“ eines Modus (KI-Ausgabe → Modi). Ab Werk ist nur
/// Korrigieren belegt (⇧⌘K). Ist für Besser formulieren keiner gesetzt,
/// steht ein Vorschlag daneben, der erst per Klick belegt wird.
struct AIOutputQuickActionSection: View {
    let mode: OutputMode
    let modes: [OutputMode]

    @State private var shortcut: KeyboardShortcuts.Shortcut?

    private var name: KeyboardShortcuts.Name { QuickActionShortcuts.name(for: mode.id) }

    var body: some View {
        SettingsSection("Shortcut without dictation") {
            SettingsRow(
                title: "Shortcut",
                subtitle: "Select text in any app and press this shortcut. WhisperM8 reworks the selection with this mode and replaces it, without recording. Cmd+Z undoes it, Esc cancels."
            ) {
                KeyboardShortcuts.Recorder(for: name) { shortcut = $0 }
                    .fixedSize()
            }

            if shortcut == nil, let suggestion, conflict(for: suggestion) == nil {
                SettingsButtonRow(
                    title: String(localized: "Suggestion: \(suggestion.description)"),
                    subtitle: "Nothing is set until you choose it."
                ) {
                    Button(String(localized: "Use \(suggestion.description)")) {
                        KeyboardShortcuts.setShortcut(suggestion, for: name)
                        shortcut = suggestion
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }
            }

            if let conflict = conflict(for: shortcut) {
                SettingsHelpText(
                    String(localized: "This shortcut is also set for “\(conflict)”. Only one of them will work, so pick another one."),
                    tone: .warning
                )
            }
        }
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: name) }
    }

    private var suggestion: KeyboardShortcuts.Shortcut? {
        QuickActionShortcuts.suggestion(for: mode.id)
    }

    private func conflict(for shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        QuickActionShortcuts.conflict(for: shortcut, excluding: mode.id, modes: modes)
    }
}
