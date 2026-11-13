import SwiftUI

/// Labs-Seite „Neustart ohne Chatverlust“ (Plan docs/plans/neustart-ohne-chatverlust.md).
/// **Noch nicht eingehängt** (Entscheidung 13.11.2026): Sie kommt in die
/// Labs-Gruppe (`SettingsPage`, `SettingsNavigation`), sobald das Feature
/// einschaltbar ist; bis dahin steht der Schlüssel in `PreferenceBedienweg`.
/// Ein Schalter: Beim Neustart über `make dev` gibt die App laufende Chats an
/// einen Aufbewahrer ab und holt sie danach zurück; der GPT-Router läuft dafür
/// als eigener Dienst. Derselbe Schlüssel wie aus Paket 3, kein zweiter.
struct RestartSettingsPage: View {
    @AppStorage(PreferenceKeys.restartKeepsChatsEnabled) private var enabled = false

    var body: some View {
        SettingsPageContainer(
            title: "Restart without losing chats",
            subtitle: "Running chats keep working while WhisperM8 restarts."
        ) {
            SettingsLabsNotice("Still being built and tested. Try it only with chats you could afford to lose. Off by default.")

            SettingsSection("Chats during a restart") {
                SettingsToggleRow(
                    title: "Keep chats running across a restart",
                    subtitle: "On a restart through make dev, running chats and terminal tabs are handed to a small helper process and taken back by the new app. If anything goes wrong, the chats are resumed as before. Quitting with Cmd+Q still ends all chats. The GPT router then runs as its own service; the change takes effect at the next app start.",
                    isOn: $enabled
                )
            }
        }
    }
}
