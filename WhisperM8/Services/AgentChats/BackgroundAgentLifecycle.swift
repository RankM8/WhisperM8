import Foundation

/// Lifecycle-Kommandos fuer Background-Agents — duenne Wrapper um
/// `claude logs/stop/respawn/rm`. Pendant zum `BackgroundAgentSpawner`
/// (der `claude --bg` kennt). Alle Aufrufe sind einmalige Subprocesses,
/// keine PTYs — die eigentliche Background-Session wird vom Claude-
/// Supervisor (`~/.claude/daemon/`) gehostet, wir reden nur ueber das
/// CLI mit ihm.
///
/// Offizielle CLI-Referenz (Claude Code 2.1.139+):
/// - `claude logs <short-id>`     — letzten Output ausgeben
/// - `claude stop <short-id>`     — Session anhalten (Alias: `kill`)
/// - `claude respawn <short-id>`  — gestoppte Session wieder hochfahren
/// - `claude rm <short-id>`       — Job-Huelle samt Worktree loeschen
enum BackgroundAgentLifecycle {
    /// Default-Timeout fuer einmalige Subprocesses. `claude logs` kann bei
    /// grossen Sessions kurz dauern; 30 s reicht in der Praxis.
    static let defaultTimeout: TimeInterval = 30

    enum Action: String, CaseIterable {
        case logs
        case stop
        case respawn
        case rm

        /// Subcommand-Token fuer den CLI-Aufruf (= `rawValue` aktuell, aber
        /// als eigene Property damit ein evtl. Aliasing (z. B. `kill`)
        /// zentral aenderbar ist).
        var subcommand: String { rawValue }
    }

    enum LifecycleError: LocalizedError, Equatable {
        case claudeNotFound
        case shortIDEmpty
        case nonZeroExit(action: Action, code: Int32, stderr: String, stdout: String)
        case timedOut(action: Action, timeout: TimeInterval)
        case launchFailed(action: Action, reason: String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Claude CLI is not installed."
            case .shortIDEmpty:
                return "Background-agent short ID is empty."
            case .nonZeroExit(let action, let code, let stderr, let stdout):
                let extra = !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    : stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if extra.isEmpty {
                    return "claude \(action.subcommand) exited with code \(code)."
                }
                return "claude \(action.subcommand) exited with code \(code): \(extra)"
            case .timedOut(let action, let seconds):
                return "claude \(action.subcommand) did not return within \(Int(seconds)) seconds."
            case .launchFailed(let action, let reason):
                return "Could not launch claude \(action.subcommand): \(reason)"
            }
        }
    }

    struct ActionResult: Equatable {
        let stdout: String
        let stderr: String
    }

    /// Ergebnis eines Health-Checks (`claude logs <id>` ohne Output-Capture).
    /// Wir unterscheiden bewusst „kennt die Short-ID nicht mehr" (Supervisor
    /// hat sie geloescht) von „echtem Fehler" (z. B. Daemon down) — beim
    /// ersten Fall wollen wir lokal aufraeumen, beim zweiten lassen wir die
    /// Session in Ruhe.
    enum HealthCheck: Equatable {
        case alive
        case unknown
        case error(reason: String)
    }

    // MARK: - Public API

    static func logs(
        shortID: String,
        timeout: TimeInterval = defaultTimeout,
        commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        processRunner: ProcessRunner = DefaultProcessRunner()
    ) async throws -> ActionResult {
        try await run(action: .logs, shortID: shortID, timeout: timeout,
                      commandResolver: commandResolver, processRunner: processRunner)
    }

    static func stop(
        shortID: String,
        timeout: TimeInterval = defaultTimeout,
        commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        processRunner: ProcessRunner = DefaultProcessRunner()
    ) async throws -> ActionResult {
        try await run(action: .stop, shortID: shortID, timeout: timeout,
                      commandResolver: commandResolver, processRunner: processRunner)
    }

    static func respawn(
        shortID: String,
        timeout: TimeInterval = defaultTimeout,
        commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        processRunner: ProcessRunner = DefaultProcessRunner()
    ) async throws -> ActionResult {
        try await run(action: .respawn, shortID: shortID, timeout: timeout,
                      commandResolver: commandResolver, processRunner: processRunner)
    }

    static func remove(
        shortID: String,
        timeout: TimeInterval = defaultTimeout,
        commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        processRunner: ProcessRunner = DefaultProcessRunner()
    ) async throws -> ActionResult {
        try await run(action: .rm, shortID: shortID, timeout: timeout,
                      commandResolver: commandResolver, processRunner: processRunner)
    }

    /// Beim App-Start fuer jede lokal gespeicherte Short-ID aufgerufen, um zu
    /// pruefen, ob der Supervisor sie noch kennt. Default-Implementation:
    /// `claude logs <id>` einmal aufrufen und die Klassifikation darunter
    /// nutzen — Exit 0 = alive; Exit != 0 mit Hint auf „unknown id" im
    /// stderr = unknown; sonst = error.
    static func healthCheck(
        shortID: String,
        timeout: TimeInterval = 10,
        commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        processRunner: ProcessRunner = DefaultProcessRunner()
    ) async -> HealthCheck {
        let trimmed = shortID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }
        guard let executable = commandResolver("claude") else {
            return .error(reason: "claude CLI not found")
        }
        do {
            let runResult = try await processRunner.run(
                executable: executable,
                arguments: ["logs", trimmed],
                workingDirectory: FileManager.default.currentDirectoryPath,
                timeout: timeout
            )
            return classifyHealthCheck(exitCode: runResult.exitCode, stderr: runResult.stderr)
        } catch {
            return .error(reason: error.localizedDescription)
        }
    }

    // MARK: - Internals

    private static func run(
        action: Action,
        shortID: String,
        timeout: TimeInterval,
        commandResolver: (String) -> String?,
        processRunner: ProcessRunner
    ) async throws -> ActionResult {
        let trimmed = shortID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LifecycleError.shortIDEmpty }
        guard let executable = commandResolver("claude") else {
            throw LifecycleError.claudeNotFound
        }

        let arguments = [action.subcommand, trimmed]
        let started = Date()
        let runResult: ProcessRunResult
        do {
            runResult = try await processRunner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: FileManager.default.currentDirectoryPath,
                timeout: timeout
            )
        } catch let error as BackgroundAgentSpawner.SpawnError {
            // Der DefaultProcessRunner wirft seinen Timeout via SpawnError —
            // wir reichen das als unsere Lifecycle-Error-Variante weiter,
            // damit Caller nicht zwei Error-Typen abfangen muessen.
            switch error {
            case .timedOut(let seconds):
                throw LifecycleError.timedOut(action: action, timeout: seconds)
            case .launchFailed(let reason):
                throw LifecycleError.launchFailed(action: action, reason: reason)
            default:
                throw LifecycleError.launchFailed(action: action, reason: error.localizedDescription)
            }
        } catch {
            throw LifecycleError.launchFailed(action: action, reason: error.localizedDescription)
        }

        let elapsed = Date().timeIntervalSince(started)
        Logger.agentPerformance.debug(
            "background_lifecycle action=\(action.subcommand, privacy: .public) elapsed=\(Int(elapsed * 1000))ms exit=\(runResult.exitCode)"
        )

        guard runResult.exitCode == 0 else {
            throw LifecycleError.nonZeroExit(
                action: action,
                code: runResult.exitCode,
                stderr: runResult.stderr,
                stdout: runResult.stdout
            )
        }

        return ActionResult(stdout: runResult.stdout, stderr: runResult.stderr)
    }

    /// Pure Klassifikation fuer den Health-Check — separat ausgelagert, damit
    /// sie ohne Subprocess unit-testbar ist.
    ///
    /// Heuristik: Exit 0 → alive. Sonst durchsuchen wir stderr/stdout nach
    /// einem von wenigen SPEZIFISCHEN Markern, die der Supervisor bei
    /// "id existiert nicht" druckt. Das frühere blanke "not found" war zu
    /// breit (Review-Befund 2026-07-13): ein beliebiger "file/config not
    /// found"-Fehler klassifizierte einen existierenden Agenten als verwaist
    /// — und die Folgekette (forget → Prune) koppelte den Chat ab. Findet
    /// sich kein Marker: `error` — die Session bleibt lokal gespeichert.
    static func classifyHealthCheck(exitCode: Int32, stderr: String) -> HealthCheck {
        if exitCode == 0 { return .alive }
        let haystack = stderr.lowercased()
        let unknownMarkers = [
            "no such session",
            "no such short id",
            "unknown short id",
            "unknown session",
            "session not found",
            "agent not found",
            "no background agent",
            "no session with id"
        ]
        if unknownMarkers.contains(where: { haystack.contains($0) }) {
            return .unknown
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .error(reason: trimmed.isEmpty ? "exit code \(exitCode)" : trimmed)
    }
}
