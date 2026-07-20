import Foundation

/// Prüft den GPT-Router vor einem Background-Spawn und baut dessen Environment
/// erst aus dem unmittelbar danach erneut gelesenen Launch-Zustand.
enum BackgroundRouterLaunchGuard {
    static func resolveEnvironment(
        isEnabled: () -> Bool,
        port: () -> Int,
        ensureRunning: (Int) -> Bool,
        makeEnvironment: (Int) -> [String: String]?,
        onUnavailable: () -> Void
    ) -> [String: String]? {
        guard isEnabled() else { return nil }

        let guardedPort = port()
        guard ensureRunning(guardedPort) else {
            onUnavailable()
            return nil
        }

        guard isEnabled() else { return nil }
        let launchPort = port()
        if launchPort != guardedPort, !ensureRunning(launchPort) {
            onUnavailable()
            return nil
        }

        return makeEnvironment(launchPort)
    }
}
