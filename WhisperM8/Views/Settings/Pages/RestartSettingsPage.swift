import SwiftUI

/// Labs-Seite „Neustart ohne Chatverlust“ (Plan docs/plans/neustart-ohne-chatverlust.md),
/// eingehängt in die Labs-Gruppe nach dem grünen Pflichttest (WM8-11). Ab Werk aus.
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
            SettingsLabsNotice("New and experimental. Off by default. A change takes effect at the next start of WhisperM8.")

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
