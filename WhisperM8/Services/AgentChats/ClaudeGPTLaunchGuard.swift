import Foundation

enum ClaudeGPTLaunchGuardResult: Equatable {
    case notNeeded
    case ready
    case unavailable
}

struct ClaudeGPTLaunchDecision: Equatable {
    var usesRouter: Bool
    var presentsGPTFallbackAlert: Bool
}

enum ClaudeGPTLaunchGuard {
    /// Trennt die Seiteneffekte des Lifecycle-Starts von der Launch-Wahl.
    /// Dadurch bleibt exakt testbar, wann der Builder auf Direktbetrieb
    /// zurueckfallen und wann der User einen deutlichen Hinweis sehen muss.
    static func decision(
        for result: ClaudeGPTLaunchGuardResult,
        hasGPTModelStamp: Bool,
        hasGPTSubagentModel: Bool
    ) -> ClaudeGPTLaunchDecision {
        switch result {
        case .ready:
            return ClaudeGPTLaunchDecision(
                usesRouter: true,
                presentsGPTFallbackAlert: false
            )
        case .notNeeded:
            return ClaudeGPTLaunchDecision(
                usesRouter: false,
                presentsGPTFallbackAlert: false
            )
        case .unavailable:
            return ClaudeGPTLaunchDecision(
                usesRouter: false,
                presentsGPTFallbackAlert: hasGPTModelStamp || hasGPTSubagentModel
            )
        }
    }
}
