import Foundation

/// Spawnt einen Claude-Background-Agent via `claude --bg "<prompt>"`,
/// liest die vom Supervisor zugewiesene Short-ID aus stdout und gibt sie
/// zurueck. Der Spawn-Prozess selbst ist **kein** PTY — er ist ein einmal-
/// Subprocess der ~Sekunden lebt, die Short-ID + Hilfetext druckt und
/// dann mit Exit 0 beendet. Die eigentliche Background-Session wird vom
/// Claude-Supervisor (`~/.claude/daemon/`) gehostet.
///
/// Stdout-Format das wir parsen (Beispiel aus der offiziellen Doku):
/// ```text
/// backgrounded · 7c5dcf5d
///   claude agents             list sessions
///   claude attach 7c5dcf5d    open in this terminal
///   claude logs 7c5dcf5d      show recent output
///   claude stop 7c5dcf5d      stop this session
/// ```
///
/// Die Short-ID ist 6+ Hex-Zeichen lang nach dem `·`-Separator.
enum BackgroundAgentSpawner {
    /// Default-Timeout fuer den Spawn — falls Claude haengt oder eine
    /// Tool-Approval-Frage stellt (sollte mit `--bg` nicht passieren,
    /// aber besser defensiv).
    static let defaultTimeout: TimeInterval = 30

    enum SpawnError: LocalizedError, Equatable {
        case claudeNotFound
        case projectMissing(String)
        case nonZeroExit(Int32, stderr: String)
        case shortIDNotFound(stdout: String)
        case timedOut(TimeInterval)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Claude CLI is not installed."
            case .projectMissing(let path):
                return "Project folder does not exist: \(path)"
            case .nonZeroExit(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "claude --bg exited with code \(code)."
                }
                return "claude --bg exited with code \(code): \(trimmed)"
            case .shortIDNotFound:
                return "Could not parse a background-agent short ID from `claude --bg` output. Claude Code may be too old (needs v2.1.139 or later)."
            case .timedOut(let seconds):
                return "claude --bg did not return a short ID within \(Int(seconds)) seconds."
            case .launchFailed(let reason):
                return "Could not launch claude --bg: \(reason)"
            }
        }
    }

    struct SpawnResult: Equatable {
        let shortID: String
        let stdout: String
        let stderr: String
    }

    /// Spawnt einen neuen Background-Agent. Async — laeuft auf einem
    /// Detached-Task, damit der Main-Thread nicht blockt.
    ///
    /// - Parameters:
    ///   - initialPrompt: erster Prompt der dem Agent uebergeben wird
    ///   - projectPath: cwd fuer den Spawn (= Projekt-Ordner)
    ///   - subAgent: optionaler Sub-Agent-Name fuer `--agent <name>`
    ///   - permissionMode: optionaler `--permission-mode <mode>`
    ///   - extraArguments: weitere CLI-Argumente (z. B. aus User-Preferences)
    ///   - timeout: Zeit-Limit fuer den Spawn (default 30 s)
    ///   - commandResolver: erlaubt Tests, einen Fake-Claude-Pfad zu liefern
    ///   - processRunner: erlaubt Tests, den Process-Lauf zu mocken
    static func spawn(
        initialPrompt: String,
        projectPath: String,
        subAgent: String? = nil,
        permissionMode: String? = nil,
        extraArguments: [String] = [],
        timeout: TimeInterval = defaultTimeout,
        commandResolver: (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        processRunner: ProcessRunner = DefaultProcessRunner()
    ) async throws -> SpawnResult {
        guard FileManager.default.fileExists(atPath: projectPath) else {
            throw SpawnError.projectMissing(projectPath)
        }
        guard let executable = commandResolver("claude") else {
            throw SpawnError.claudeNotFound
        }

        let arguments = AgentCommandBuilder.backgroundSpawnArguments(
            initialPrompt: initialPrompt,
            subAgent: subAgent,
            permissionMode: permissionMode,
            extraArguments: extraArguments
        )

        let started = Date()
        let runResult: ProcessRunResult
        do {
            runResult = try await processRunner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: projectPath,
                timeout: timeout
            )
        } catch let error as SpawnError {
            throw error
        } catch {
            throw SpawnError.launchFailed(error.localizedDescription)
        }

        let elapsed = Date().timeIntervalSince(started)
        Logger.agentPerformance.debug(
            "background_spawn elapsed=\(Int(elapsed * 1000))ms exit=\(runResult.exitCode) stdoutBytes=\(runResult.stdout.utf8.count)"
        )

        guard runResult.exitCode == 0 else {
            throw SpawnError.nonZeroExit(runResult.exitCode, stderr: runResult.stderr)
        }

        guard let shortID = parseShortID(from: runResult.stdout) else {
            throw SpawnError.shortIDNotFound(stdout: runResult.stdout)
        }

        return SpawnResult(
            shortID: shortID,
            stdout: runResult.stdout,
            stderr: runResult.stderr
        )
    }

    // MARK: - Pure parser

    /// Parsed die Background-Agent-Short-ID aus dem Stdout von `claude --bg`.
    ///
    /// Akzeptierte Formen (alle vom Anthropic-Output in der Praxis gesehen):
    /// - `backgrounded · 7c5dcf5d` (Standard, mit Middle-Dot)
    /// - `backgrounded - 7c5dcf5d` (manche Terminals ohne UTF-8-Dot)
    /// - `backgrounded: 7c5dcf5d` (paranoid)
    ///
    /// Die Short-ID ist [0-9a-f]{6,16}. Wir greifen aus Robustheits-Gruenden
    /// die **erste** Zeile, die mit `backgrounded` startet — egal wo sie im
    /// Output erscheint.
    static func parseShortID(from stdout: String) -> String? {
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("backgrounded") else { continue }

            // Alles nach dem ersten Whitespace + Separator extrahieren.
            // Wir nehmen das letzte Token der Zeile, das ein gueltiger
            // Hex-Hash mit 6+ Zeichen ist.
            let tokens = line.split(whereSeparator: { $0.isWhitespace || $0 == "·" || $0 == ":" || $0 == "-" })
            for token in tokens.reversed() {
                let candidate = String(token).lowercased()
                if isLikelyShortID(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// `true` wenn der Token ein 6–16-stelliger Lowercase-Hex-String ist.
    /// Wir lassen die obere Grenze grosszuegig, falls Anthropic die Laenge
    /// kuenftig erhoeht.
    static func isLikelyShortID(_ candidate: String) -> Bool {
        let count = candidate.count
        guard count >= 6 && count <= 16 else { return false }
        return candidate.allSatisfy { ch in
            ("0"..."9").contains(ch) || ("a"..."f").contains(ch)
        }
    }
}

// MARK: - Process-Runner-Abstraktion (testbar)

struct ProcessRunResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

protocol ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        timeout: TimeInterval
    ) async throws -> ProcessRunResult
}

/// Default-Implementierung mit `Foundation.Process`. Wird im Test durch
/// einen Mock ersetzt, damit wir keine echten `claude`-Aufrufe machen.
struct DefaultProcessRunner: ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        timeout: TimeInterval
    ) async throws -> ProcessRunResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessRunResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // Stdin schliessen — claude --bg liest nichts.
            process.standardInput = FileHandle.nullDevice

            // Atomic-Flag, damit wir die Continuation genau einmal resumen
            // (Timeout-Path und Termination-Path koennten beide feuern).
            let resumed = AtomicFlag()

            let timeoutSource = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timeoutSource.schedule(deadline: .now() + timeout)
            timeoutSource.setEventHandler {
                guard resumed.consume() else { return }
                if process.isRunning {
                    process.terminate()
                }
                continuation.resume(throwing: BackgroundAgentSpawner.SpawnError.timedOut(timeout))
            }

            process.terminationHandler = { proc in
                timeoutSource.cancel()
                guard resumed.consume() else { return }
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessRunResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }

            do {
                try process.run()
                timeoutSource.resume()
            } catch {
                timeoutSource.cancel()
                guard resumed.consume() else { return }
                continuation.resume(throwing: BackgroundAgentSpawner.SpawnError.launchFailed(error.localizedDescription))
            }
        }
    }
}

/// Minimaler thread-safe Flag fuer das einmalige Continuation-Resume.
private final class AtomicFlag {
    private let lock = NSLock()
    private var used = false

    /// Liefert `true` beim ersten Call, danach immer `false`.
    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
