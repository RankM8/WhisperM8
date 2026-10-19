import SwiftUI

/// Glocken-Schalter im Sidebar-Footer: ein Klick schaltet die Ruhe-Stufe
/// weiter (alles an → Ton aus → alles aus → alles an). Eigene kleine View,
/// damit ein Klick nur dieses Icon neu zeichnet, nicht die ganze Sidebar.
struct SidebarAlertLevelButton: View {
    @AppStorage(PreferenceKeys.agentAlertLevel) private var level: AgentAlertLevel = .all
    @AppStorage(PreferenceKeys.agentStopSoundEnabled) private var stopSoundEnabled = true
    @AppStorage(PreferenceKeys.speechCalloutsEnabled) private var calloutsEnabled = true
    @AppStorage(PreferenceKeys.speechCalloutsMuted) private var calloutsMuted = false

    var body: some View {
        Button {
            let newLevel = nextLevel
            level = newLevel
            if newLevel.silencesSound {
                SpeechCalloutCenter.shared.discardAll()
            }
            Logger.claudeBinding.info("alert_level_changed level=\(newLevel.rawValue, privacy: .public)")
        } label: {
            Image(systemName: Self.symbolName(for: level))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(level == .all ? AgentTheme.textSecondary : AgentTheme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.helpText(current: level, next: nextLevel))
        .accessibilityLabel(Text("Sound and notifications"))
        .accessibilityValue(Text(Self.title(for: level)))
    }

    private var nextLevel: AgentAlertLevel {
        level.next(soundStageHasEffect: stopSoundEnabled || (calloutsEnabled && !calloutsMuted))
    }

    static func symbolName(for level: AgentAlertLevel) -> String {
        switch level {
        case .all: return "bell.and.waves.left.and.right"
        case .soundOff: return "bell"
        case .off: return "bell.slash"
        }
    }

    static func title(for level: AgentAlertLevel) -> String {
        switch level {
        case .all: return String(localized: "Sound and notifications on")
        case .soundOff: return String(localized: "Sound off, notifications on")
        case .off: return String(localized: "Sound and notifications off")
        }
    }

    static func helpText(current: AgentAlertLevel, next: AgentAlertLevel) -> String {
        let action: String
        switch next {
        case .all: action = String(localized: "everything back on")
        case .soundOff: action = String(localized: "sound off")
        case .off: action = String(localized: "everything off")
        }
        return String(localized: "\(title(for: current)) — click: \(action)")
    }
}
