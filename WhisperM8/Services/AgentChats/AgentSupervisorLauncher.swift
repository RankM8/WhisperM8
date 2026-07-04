import Foundation

/// Startet den detachten Supervisor-Prozess: dasselbe whisperm8-Binary im
/// internen Modus `agent-supervise <short-id>` (E5). Das Frontend wartet
/// NICHT — es notiert nur die PID in state.json und beendet sich; das Kind
/// löst sich selbst per setsid() vom Terminal.
struct AgentSupervisorLauncher {
    enum LaunchError: LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let reason):
                return "Supervisor-Prozess konnte nicht starten: \(reason)"
            }
        }
    }

    /// Pfad zum eigenen Binary. `Bundle.main.executablePath` funktioniert
    /// sowohl im App-Bundle als auch beim nackten SwiftPM-Build; argv0 als
    /// letzter Fallback (Symlink löst auf dasselbe Binary auf).
    var executablePath: String

    init(executablePath: String? = nil) {
        self.executablePath = executablePath
            ?? Bundle.main.executablePath
            ?? CommandLine.arguments[0]
    }

    /// Spawnt den Supervisor, stdout/stderr → supervisor.log (append),
    /// stdin geschlossen. Gibt die PID zurück (Liveness-Anker).
    func launchDetached(shortId: String, logURL: URL) throws -> Int32 {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle: FileHandle
        do {
            logHandle = try FileHandle(forWritingTo: logURL)
            try logHandle.seekToEnd()
        } catch {
            throw LaunchError.launchFailed("supervisor.log nicht beschreibbar: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["agent-supervise", shortId]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.environment = LoginShellEnvironment.shared.processEnvironment()

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw LaunchError.launchFailed(error.localizedDescription)
        }
        try? logHandle.close()
        return process.processIdentifier
    }
}
