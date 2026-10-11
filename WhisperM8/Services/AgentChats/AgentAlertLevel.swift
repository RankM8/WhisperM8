import Foundation

/// Ruhe-Stufe des Glocken-Schalters unten in der Sidebar. Überlagert die
/// Einstellungen (Fertig-Ton, Mitteilungen, Terminal-Glocke), ändert sie aber
/// nie — „Alles an" heißt deshalb immer: genau das, was in den Einstellungen
/// steht. Ein Klick schaltet zyklisch weiter: alles an → Ton aus → alles aus.
enum AgentAlertLevel: String, CaseIterable {
    /// Keine Überlagerung — es gelten die Einstellungen.
    case all
    /// Fertig-Ton und Voice-Callouts stumm, Mitteilungen bleiben.
    case soundOff
    /// Zusätzlich keine Mitteilungen (Fertig, Rückfrage, Subagent) und keine
    /// Terminal-Glocke.
    case off

    /// Fertig-Ton und Voice-Callouts schweigen.
    var silencesSound: Bool { self != .all }
    /// Mitteilungen und Terminal-Glocke schweigen.
    var silencesNotifications: Bool { self == .off }

    /// Nächste Stufe beim Klick. „Ton aus" wird übersprungen, wenn es nichts
    /// stumm zu schalten gibt (Fertig-Ton in den Einstellungen aus, Callouts
    /// aus oder schon stumm) — sonst täte ein Klick scheinbar nichts.
    func next(soundStageHasEffect: Bool) -> AgentAlertLevel {
        switch self {
        case .all:
            return soundStageHasEffect ? .soundOff : .off
        case .soundOff:
            return .off
        case .off:
            return .all
        }
    }

    /// Legt die Stufe über die Einstellungen. Hooks bleiben unberührt — die
    /// Stufe dämpft nur Effekte, nie die Status-Erkennung.
    func applied(to preferences: AgentStatusPreferences) -> AgentStatusPreferences {
        var result = preferences
        if silencesSound {
            result.stopSoundEnabled = false
        }
        if silencesNotifications {
            result.stopNotificationEnabled = false
            result.awaitingNotificationEnabled = false
        }
        return result
    }
}
