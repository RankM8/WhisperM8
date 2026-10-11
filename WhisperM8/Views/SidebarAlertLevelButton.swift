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
        .accessibilityLabel(Text("Ton und Mitteilungen"))
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
        case .all: return "Ton und Mitteilungen an"
        case .soundOff: return "Ton aus, Mitteilungen an"
        case .off: return "Ton und Mitteilungen aus"
        }
    }

    static func helpText(current: AgentAlertLevel, next: AgentAlertLevel) -> String {
        let action: String
        switch next {
        case .all: action = "alles wieder an"
        case .soundOff: action = "Ton aus"
        case .off: action = "alles aus"
        }
        return "\(title(for: current)) — Klick: \(action)"
    }
}
