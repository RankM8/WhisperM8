import SwiftUI

/// Eigene Seite der Gruppe „Labs“ für die Codewort-Steuerung der Codex-Sprachsitzung
/// (früher Tab von „Agent Chats“; die Alt-Route `voiceAgent` führt hierher).
struct VoiceGateSettingsPage: View {
    var body: some View {
        SettingsPageContainer(
            title: "Codex Voice Agent",
            subtitle: "Mute and unmute a Codex Desktop voice session with a spoken code word."
        ) {
            SettingsLabsNotice("Experimental. Needs a keyboard shortcut set once inside Codex and on-device speech recognition. Off by default.")
            AgentChatsVoiceAgentTab()
        }
    }
}
