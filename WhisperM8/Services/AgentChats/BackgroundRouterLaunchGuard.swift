import Foundation

/// Prüft den GPT-Router vor einem Background-Spawn und baut dessen vollstaendigen
/// Environment-Snapshot erst aus dem unmittelbar danach erneut gelesenen
/// Launch-Zustand. Derselbe Snapshot geht an Dispatcher und session-scoped
/// Settings-Datei, damit der Supervisor-Worker die internen Werte ebenfalls
/// erhaelt.
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

    /// Ohne aktives Router-Env bleibt der bisherige fail-open Direktbetrieb
    /// erhalten. Sobald Routing aktiv ist, ist die session-scoped Settings-Datei
    /// dagegen Teil der Launch-Invariante und ein Schreibfehler muss blockieren.
    static func blocksSpawnAfterSettingsPreparation(
        routerEnvironment: [String: String]?,
        settingsFilePath: String?
    ) -> Bool {
        routerEnvironment != nil && settingsFilePath == nil
    }
}
