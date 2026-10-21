import AVFoundation
import SwiftUI

/// Labs-Seite für Jarvis-Board, Notiz-Karten, gesprochene Ansagen und
/// experimentelle Terminal-Optionen. Bisher nur per `defaults write` erreichbar.
struct JarvisCalloutsSettingsPage: View {
    @AppStorage(PreferenceKeys.jarvisBoardEnabled) private var boardEnabled = true
    @AppStorage(PreferenceKeys.jarvisNotesEnabled) private var notesEnabled = true
    @AppStorage(PreferenceKeys.jarvisNotesDefaultOpen) private var notesDefaultOpen = true
    @AppStorage(PreferenceKeys.agentChatTasksInNotesEnabled) private var tasksInNotesEnabled = true
    @AppStorage(PreferenceKeys.speechCalloutsEnabled) private var calloutsEnabled = true
    @AppStorage(PreferenceKeys.speechCalloutsMuted) private var calloutsMuted = false
    @AppStorage(PreferenceKeys.speechCalloutVoiceIdentifier) private var voiceIdentifier = ""
    @AppStorage(PreferenceKeys.agentTerminalMetalEnabled) private var metalEnabled = false
    @AppStorage(PreferenceKeys.agentPerfDetailEnabled) private var perfDetailEnabled = false

    @State private var voices: [VoiceChoice] = []

    struct VoiceChoice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    var body: some View {
        SettingsPageContainer(
            title: "Jarvis & Callouts",
            subtitle: "Experimental: Jarvis board, per-chat notes and spoken callouts."
        ) {
            SettingsLabsNotice("These features are still evolving. They never run unless you use the matching skill or CLI command.")

            SettingsSection("Jarvis board") {
                SettingsToggleRow(
                    title: "Enable Jarvis board",
                    subtitle: "Lets `whisperm8 chats board` keep a status board for a supervising chat. When off, board commands answer with an error.",
                    isOn: $boardEnabled
                )
                SettingsToggleRow(
                    title: "Show notes on grid tiles",
                    subtitle: "A small card on each tile of the Jarvis board: work package, what needs you, blockers.",
                    isOn: $notesEnabled
                )
                SettingsToggleRow(
                    title: "Show chat tasks in notes",
                    subtitle: "Every Claude chat with open tasks gets a note card listing them, with clickable links. Works without Jarvis.",
                    isOn: $tasksInNotesEnabled
                )
                SettingsToggleRow(
                    title: "Open notes by default",
                    subtitle: "Also available as the Notes toggle in the workspace bar (⌥⌘N).",
                    isOn: $notesDefaultOpen
                )
            }

            SettingsSection("Spoken callouts") {
                SettingsToggleRow(
                    title: "Enable spoken callouts",
                    subtitle: "A chat can read a short announcement aloud when it finishes or needs you. Never during a dictation recording. Mute from the menu bar.",
                    isOn: $calloutsEnabled
                )
                SettingsToggleRow(
                    title: "Mute callouts",
                    subtitle: "Announcements are accepted but not spoken. Same switch as in the menu bar.",
                    isOn: $calloutsMuted
                )
                SettingsPickerRow(
                    title: "Voice",
                    subtitle: "Automatic picks the best installed voice for the language of the announcement.",
                    selection: $voiceIdentifier,
                    options: [""] + voices.map(\.id)
                ) { identifier in
                    Text(settingsLocalized: voiceName(identifier))
                }
            }

            SettingsSection("Terminal experiments") {
                SettingsToggleRow(
                    title: "GPU terminal renderer (Metal)",
                    subtitle: "Faster in theory, but text can look softer. Takes effect after restarting WhisperM8.",
                    isOn: $metalEnabled
                )
                SettingsToggleRow(
                    title: "Detailed performance measurement",
                    subtitle: "Adds finer-grained timing to the log for performance investigations. Takes effect after restarting WhisperM8.",
                    isOn: $perfDetailEnabled
                )
            }
        }
        .onAppear(perform: loadVoices)
    }

    private func voiceName(_ identifier: String) -> String {
        if identifier.isEmpty { return "Automatic" }
        return voices.first(where: { $0.id == identifier })?.name ?? identifier
    }

    private func loadVoices() {
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.contains(".eloquence.") }
            .map { VoiceChoice(id: $0.identifier, name: "\($0.name) (\($0.language))") }
            .sorted { $0.name < $1.name }
        // Eine gespeicherte, nicht (mehr) installierte Stimme bleibt auswählbar.
        var list = all
        if !voiceIdentifier.isEmpty, !list.contains(where: { $0.id == voiceIdentifier }) {
            list.insert(VoiceChoice(id: voiceIdentifier, name: voiceIdentifier), at: 0)
        }
        voices = list
    }
}
