import Foundation

/// Die beiden CLIs, die WhisperM8 nicht selbst mitbringt (Beschluss D5/E5).
enum AgentCLI: String, CaseIterable, Equatable {
    case claude
    case codex

    /// Name der ausführbaren Datei (Auflösung über `AgentCommandBuilder.commandPath`).
    var commandName: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Homebrew-Cask. Der Weg ist bewusst fest: nie `curl | bash`.
    var brewCask: String {
        switch self {
        case .claude: return "claude-code"
        case .codex: return "codex"
        }
    }

    /// Offizielle Installationsanleitung (Alternativweg bzw. Fallback ohne Homebrew).
    var documentationURL: URL {
        switch self {
        case .claude: return URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
        case .codex: return URL(string: "https://developers.openai.com/codex/cli")!
        }
    }

    static let homebrewURL = URL(string: "https://brew.sh")!
}

/// Zusätzliche Installationsorte von Versionsmanagern (Volta, Bun, npm-global,
/// mise, asdf, nvm, fnm), die im launchd-PATH der GUI-App fehlen. Ein Ort für
/// Erkennung UND Chatstart, damit „installiert“ und „startbar“ nie auseinanderlaufen
/// (LR-AU-022, D5 „nie doppelt“).
enum AgentCLISearchPaths {
    static func extraDirectories(
        home: String = NSHomeDirectory(),
        listing: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    ) -> [String] {
        var result = [
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
        ]
        // Glob je Versionsordner, neueste Version zuerst.
        func newestFirst(_ base: String, suffix: String) -> [String] {
            listing(base)
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(base)/\($0)\(suffix)" }
        }
        result += newestFirst("\(home)/.nvm/versions/node", suffix: "/bin")
        result += newestFirst("\(home)/.local/share/fnm/node-versions", suffix: "/installation/bin")
        result += newestFirst("\(home)/Library/Application Support/fnm/node-versions", suffix: "/installation/bin")
        return result
    }

    static func firstExecutable(
        _ command: String,
        in directories: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for directory in directories {
            let path = "\(directory)/\(command)"
            if isExecutable(path) { return path }
        }
        return nil
    }
}

/// Zustand einer CLI auf diesem Mac — rein aus Auflösungs-Closures abgeleitet.
enum AgentCLIState: Equatable {
    /// Gefunden (egal ob nativer Installer, npm, Homebrew oder App-Bundle).
    case installed(path: String)
    /// Fehlt, Homebrew ist da: Installation per Cask möglich.
    case missingCanInstall(brewPath: String)
    /// Fehlt und Homebrew fehlt ebenfalls.
    case missingNoHomebrew

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Pur + injizierbar: erkennt vorhandene Installationen (nie doppelt anlegen)
/// und die Voraussetzungen für den Cask-Weg.
struct AgentCLIResolver {
    var commandResolver: (String) -> String?
    var brewResolver: () -> String?

    static let live = AgentCLIResolver(
        commandResolver: { command in
            if command == "codex" { return CodexStatusProbe.resolveCommandPath(command) }
            return AgentCommandBuilder.commandPath(command)
        },
        brewResolver: {
            for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            return AgentCommandBuilder.commandPath("brew")
        }
    )

    func state(of cli: AgentCLI) -> AgentCLIState {
        if let path = commandResolver(cli.commandName) {
            return .installed(path: path)
        }
        if let brew = brewResolver() {
            return .missingCanInstall(brewPath: brew)
        }
        return .missingNoHomebrew
    }
}

// MARK: - Ausführung

enum AgentCLIInstallOutcome: Equatable {
    case installed(path: String)
    case alreadyInstalled(path: String)
    case homebrewMissing
    case failed(message: String)
    case timedOut
}

struct CLIInstallRunResult: Equatable {
    var exitCode: Int32
    var output: String
    var timedOut: Bool
}

/// Prozess-Runner-Seam: Tests liefern Fakes, es werden nie echte Installationen gestartet.
protocol AgentCLIProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> CLIInstallRunResult
}

/// Installiert eine CLI per Homebrew-Cask — nur auf ausdrückliche Anforderung
/// des Aufrufers (die UI fragt vorher), nie doppelt, off-main, mit Timeout.
struct AgentCLIInstaller {
    var resolver: AgentCLIResolver = .live
    var runner: AgentCLIProcessRunning = LiveAgentCLIProcessRunner()
    var environment: () -> [String: String] = { LoginShellEnvironment.shared.processEnvironment() }
    var timeout: TimeInterval = 600

    /// Argumente für `brew`: ein Ort, damit Test und UI-Text dasselbe zeigen.
    static func brewArguments(for cli: AgentCLI) -> [String] {
        ["install", "--cask", cli.brewCask]
    }

    /// Menschenlesbarer Befehl für die Rückfrage.
    static func displayCommand(for cli: AgentCLI) -> String {
        "brew " + brewArguments(for: cli).joined(separator: " ")
    }

    func install(
        _ cli: AgentCLI,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> AgentCLIInstallOutcome {
        switch resolver.state(of: cli) {
        case .installed(let path):
            return .alreadyInstalled(path: path)
        case .missingNoHomebrew:
            return .homebrewMissing
        case .missingCanInstall(let brew):
            var env = environment()
            // Nicht interaktiv: nie auf Rückfragen/Hinweise warten, kein Auto-Update-Stau.
            env["NONINTERACTIVE"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            let result = await runner.run(
                executable: brew,
                arguments: Self.brewArguments(for: cli),
                environment: env,
                timeout: timeout,
                onOutput: onOutput
            )
            if result.timedOut { return .timedOut }
            guard result.exitCode == 0 else {
                return .failed(message: Self.tail(of: result.output))
            }
            // Erfolg zählt erst, wenn die CLI tatsächlich auffindbar ist.
            if case .installed(let path) = resolver.state(of: cli) {
                return .installed(path: path)
            }
            return .failed(message: String(localized: "The installation finished, but the command was not found afterwards. Restart WhisperM8 and check again."))
        }
    }

    /// Letzte Zeilen der Ausgabe als Fehlertext.
    static func tail(of output: String, maxLines: Int = 6) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let text = lines.suffix(maxLines).joined(separator: "\n")
        return text.isEmpty ? String(localized: "The installation failed without any output.") : text
    }
}

/// Echter Runner: Subprozess mit Pipe, Timeout und Live-Ausgabe.
struct LiveAgentCLIProcessRunner: AgentCLIProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> CLIInstallRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                let buffer = LockedString()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    buffer.append(chunk)
                    onOutput(chunk)
                }

                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: CLIInstallRunResult(
                        exitCode: -1, output: error.localizedDescription, timedOut: false
                    ))
                    return
                }

                let timedOut = LockedFlag()
                let timer = DispatchWorkItem {
                    timedOut.set()
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                process.waitUntilExit()
                timer.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd(),
                   let chunk = String(data: rest, encoding: .utf8), !chunk.isEmpty {
                    buffer.append(chunk)
                    onOutput(chunk)
                }
                continuation.resume(returning: CLIInstallRunResult(
                    exitCode: process.terminationStatus,
                    output: buffer.value,
                    timedOut: timedOut.isSet
                ))
            }
        }
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
