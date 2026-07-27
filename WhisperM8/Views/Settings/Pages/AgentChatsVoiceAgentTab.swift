import SwiftUI

/// Eigener Tab für die Codewort-Steuerung der Codex-Sprachsitzung.
///
/// Bewusst mit viel Erklärung: Das Feature hängt an einer Voraussetzung, die
/// WhisperM8 nicht selbst herstellen kann — dem Kürzel in Codex' eigenen
/// Einstellungen. Ohne diesen Hinweis ist der Rest wirkungslos.
struct AgentChatsVoiceAgentTab: View {
    @AppStorage(PreferenceKeys.codexVoiceGateEnabled) private var voiceGateEnabled = false
    @AppStorage(PreferenceKeys.codexVoiceGateDryRun) private var dryRun = true
    @AppStorage(PreferenceKeys.codexVoiceGateSoundEnabled) private var soundEnabled = true

    @AppStorage(PreferenceKeys.codexVoiceGateCarrier) private var carrier = VoiceGateVocabulary.default.carrier
    @AppStorage(PreferenceKeys.codexVoiceGateMuteWord) private var muteWord = VoiceGateVocabulary.default.muteCommand
    @AppStorage(PreferenceKeys.codexVoiceGateUnmuteWord) private var unmuteWord = VoiceGateVocabulary.default.unmuteCommand

    @AppStorage(PreferenceKeys.codexVoiceGateVerboseLogging) private var verboseLogging = false

    @State private var gate = VoiceGateCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupSection
            listeningSection

            if voiceGateEnabled {
                codeWordsSection
                behaviourSection
                diagnosticsSection
            }
        }
    }

    // MARK: - Voraussetzung in Codex

    private var setupSection: some View {
        SettingsSection("Setup in Codex") {
            SettingsHelpText(
                "WhisperM8 does not mute Codex itself — it triggers Codex's own microphone toggle. That command ships without a default shortcut, so you have to assign one once:",
                tone: .secondary
            )

            SettingsHelpText(
                "Codex → Settings → Keyboard shortcuts → “Toggle Voice Chat microphone” → assign Control-Shift-U.",
                tone: .secondary
            )

            SettingsHelpText(
                "The shortcut only fires while Codex is the front app, so WhisperM8 briefly activates Codex and returns to your previous window. That flicker is expected.",
                tone: .secondary
            )

            SettingsRow(title: "Codex", subtitle: "Detected via the running application.") {
                Text(gate.armState == .codexNotRunning ? "not running" : "running")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    // MARK: - Mithören

    private var listeningSection: some View {
        SettingsSection("Listening") {
            SettingsToggleRow(
                title: "Listen for the code word",
                subtitle: "Recognition runs on-device while a Codex voice chat is active. No audio is stored or sent. Turning this off releases the microphone immediately.",
                isOn: $voiceGateEnabled
            )
            .onChange(of: voiceGateEnabled) { _, newValue in
                gate.setEnabled(newValue)
            }

            if voiceGateEnabled {
                SettingsToggleRow(
                    title: "Dry run",
                    subtitle: "Detects the code word and plays a sound, but never switches Codex. Use this to check for false triggers before going live.",
                    isOn: $dryRun
                )

                SettingsToggleRow(
                    title: "Play a sound on trigger",
                    subtitle: "Short confirmation tone whenever the code word takes effect.",
                    isOn: $soundEnabled
                )
            } else {
                SettingsHelpText(
                    "Off: WhisperM8 does not touch the microphone, and the code words are ignored.",
                    tone: .secondary
                )
            }
        }
    }

    // MARK: - Codewörter

    private var codeWordsSection: some View {
        SettingsSection("Code words") {
            SettingsHelpText(
                "Carrier word plus command, spoken together after a short pause. The carrier alone never triggers anything — it comes up in normal conversation too often.",
                tone: .secondary
            )

            wordRow(
                title: "Carrier word",
                subtitle: "Spoken before every command.",
                placeholder: VoiceGateVocabulary.default.carrier,
                text: $carrier
            )

            wordRow(
                title: "Mute word",
                subtitle: "Mutes Codex. Codex still hears this one — the channel is open when you say it.",
                placeholder: VoiceGateVocabulary.default.muteCommand,
                text: $muteWord
            )

            wordRow(
                title: "Unmute word",
                subtitle: "Unmutes Codex. Codex never hears this one, because it is deaf at that moment.",
                placeholder: VoiceGateVocabulary.default.unmuteCommand,
                text: $unmuteWord
            )

            if let warning = vocabularyWarning {
                SettingsHelpText(warning, tone: .warning)
            }

            SettingsHelpText(carrierToleranceHint, tone: .secondary)
        }
    }

    // MARK: - Verhalten

    private var behaviourSection: some View {
        SettingsSection("Behaviour") {
            SettingsHelpText(
                "Codex's shortcut is a blind toggle — it flips the microphone but never reports the result. WhisperM8 therefore tracks an assumption, and the mute word only fires when that assumption disagrees.",
                tone: .secondary
            )

            SettingsHelpText(
                "If the direction is ever wrong, repeat the same phrase within four seconds. That overrides the assumption and switches anyway — so saying the unmute word twice always gets you out of a muted state.",
                tone: .secondary
            )

            SettingsRow(
                title: "Assumed microphone state",
                subtitle: "Correct this if you toggled Codex by hand."
            ) {
                Picker("", selection: assumedStateBinding) {
                    Text("open").tag(VoiceGateAssumedState.open)
                    Text("muted").tag(VoiceGateAssumedState.muted)
                    Text("unknown").tag(VoiceGateAssumedState.unknown)
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    // MARK: - Diagnose

    private var diagnosticsSection: some View {
        SettingsSection("Diagnostics") {
            SettingsHelpText(statusText, tone: gate.startupError == nil ? .secondary : .warning)

            SettingsRow(title: dryRun ? "Would have switched" : "Switched") {
                Text("\(dryRun ? gate.wouldPressCount : gate.pressCount)×  ·  skipped \(gate.skippedCount)×")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            if let event = gate.lastEvent {
                SettingsRow(title: "Last event") {
                    Text(event)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .frame(width: 320, alignment: .trailing)
                }
            }

            SettingsToggleRow(
                title: "Log recognized words",
                subtitle: "Troubleshooting only: writes what the recognizer understood into the log, so you can see why a code word did not match. Off by default.",
                isOn: $verboseLogging
            )

            SettingsCopyCommandRow(
                command: "log stream --predicate 'subsystem == \"com.whisperm8.app\" && category == \"voice.gate\"' --level debug",
                caption: "Live log — shows every detection, every rejection reason, and the measured round-trip duration."
            )
        }
    }

    // MARK: - Bausteine

    private var assumedStateBinding: Binding<VoiceGateAssumedState> {
        Binding(
            get: { gate.assumedState },
            set: { gate.correctAssumedState(to: $0) }
        )
    }

    private func wordRow(
        title: String,
        subtitle: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .frame(width: 180)
        }
    }

    /// Kurze oder gleichlautende Wörter sind der Hauptgrund für Fehlalarme —
    /// lieber vorher warnen als hinterher im Log suchen.
    private var vocabularyWarning: String? {
        let words = [carrier, muteWord, unmuteWord].map {
            VoiceGateCommandMatcher.normalize($0)
        }
        let filled = words.filter { !$0.isEmpty }

        if filled.contains(where: { $0.count < 4 }) {
            return "Short words trigger far more often by accident. Four letters or more is much safer."
        }
        if Set(filled).count < filled.count {
            return "The three words must differ from each other."
        }
        if !words[1].isEmpty, !words[2].isEmpty,
           VoiceGateCommandMatcher.editDistance(Array(words[1]), Array(words[2])) <= 1 {
            return "Mute and unmute word sound almost identical — a misrecognition would do the opposite of what you want."
        }
        return nil
    }

    /// Erklaert die laengenabhaengige Toleranz, damit die Wortwahl bewusst
    /// getroffen wird statt durch Ausprobieren.
    private var carrierToleranceHint: String {
        var vocabulary = VoiceGateVocabulary.default
        vocabulary.carrier = carrier
        if vocabulary.carrierDistanceAllowance() > 0 {
            return "Long carrier word — a single misheard letter is still accepted."
        }
        return "Short carrier word — it has to be recognized exactly, because near-misses like “Anne” or “Hanna” would otherwise slip through."
    }

    private var statusText: String {
        if let error = gate.startupError { return error }

        switch gate.armState {
        case .armed:
            return "Active — listening while the Codex voice chat is running."
        case .codexNotRunning:
            return "Idle — Codex is not running, the microphone stays untouched."
        case .noRecentSession:
            return "Idle — no Codex voice chat detected, the microphone stays untouched."
        case .pausedForDictation:
            return "Paused — WhisperM8 is recording a dictation right now."
        }
    }
}
