import AppKit
import Foundation

/// Wem ein Codex-Lauf gehört: Der Abbruch im Diktat-Overlay trifft nur Diktat-Läufe,
/// nie eine parallel laufende Test-Lab-Vorschau (LR-DIK-014). Wird als Task-Local
/// durchgereicht, damit das `PostProcessing`-Protokoll unverändert bleibt.
enum CodexRunOwner: String, Sendable {
    case dictation
    case testLab

    @TaskLocal static var current: CodexRunOwner = .dictation
}

/// Trackt laufende Codex-Subprozesse je Lauf (Run-ID) für externes Cancel
/// (Cancel-Button im Recording-Overlay, Task-Cancellation) und das harte
/// Zeitlimit. Jeder Lauf hat seinen eigenen Slot und sein eigenes Abbruch-Flag.
final class CodexProcessRegistry: @unchecked Sendable {
    static let shared = CodexProcessRegistry()

    enum Outcome: Equatable {
        case none
        case cancelledByUser
        case timedOut
    }

    private struct Entry {
        var process: Process
        var owner: CodexRunOwner
        var outcome: Outcome = .none
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    /// Abbruch, der vor der Registrierung des Prozesses eintraf (Task-Cancellation
    /// zwischen Start des Detached-Tasks und `process.run()`).
    private var precancelled: Set<UUID> = []
    /// Zeit zwischen SIGTERM und SIGKILL.
    let killGrace: TimeInterval

    init(killGrace: TimeInterval = 3) {
        self.killGrace = killGrace
    }

    /// Meldet einen gestarteten Prozess unter `runID` an. War der Lauf vorher schon
    /// abgebrochen, wird er sofort beendet.
    func register(_ process: Process, runID: UUID = UUID(), owner: CodexRunOwner = .dictation) {
        lock.lock()
        var entry = Entry(process: process, owner: owner)
        let wasPrecancelled = precancelled.remove(runID) != nil
        if wasPrecancelled { entry.outcome = .cancelledByUser }
        entries[runID] = entry
        lock.unlock()
        if wasPrecancelled { terminateWithEscalation(process) }
    }

    func unregister(runID: UUID) {
        lock.lock()
        entries[runID] = nil
        precancelled.remove(runID)
        lock.unlock()
    }

    /// Bricht alle laufenden Läufe EINES Besitzers ab (Overlay-Button → `.dictation`).
    @discardableResult
    func cancel(owner: CodexRunOwner = .dictation) -> Bool {
        lock.lock()
        var processes: [Process] = []
        for (id, entry) in entries where entry.owner == owner {
            entries[id]?.outcome = .cancelledByUser
            processes.append(entry.process)
        }
        lock.unlock()
        var any = false
        for process in processes where process.isRunning {
            terminateWithEscalation(process)
            any = true
        }
        return any
    }

    /// Bricht genau einen Lauf ab (Task-Cancellation).
    @discardableResult
    func cancel(runID: UUID) -> Bool {
        lock.lock()
        guard let entry = entries[runID] else {
            precancelled.insert(runID)
            lock.unlock()
            return false
        }
        entries[runID]?.outcome = .cancelledByUser
        lock.unlock()
        guard entry.process.isRunning else { return false }
        terminateWithEscalation(entry.process)
        return true
    }

    /// Hartes Zeitlimit: markiert den Lauf als `timedOut` und beendet ihn (TERM, dann KILL).
    func expire(runID: UUID) {
        lock.lock()
        // Kurz nach regulärem Prozessende kein Timeout mehr melden (Review W2b).
        guard let entry = entries[runID], entry.outcome == .none, entry.process.isRunning else {
            lock.unlock()
            return
        }
        entries[runID]?.outcome = .timedOut
        lock.unlock()
        if entry.process.isRunning { terminateWithEscalation(entry.process) }
    }

    func outcome(runID: UUID) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        return entries[runID]?.outcome ?? .none
    }

    /// SIGTERM; ignoriert der Prozess es, folgt nach `killGrace` SIGKILL.
    private func terminateWithEscalation(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [weak process] in
            guard let process, process.isRunning, process.processIdentifier == pid else { return }
            kill(pid, SIGKILL)
        }
    }
}

enum CodexInvocation {
    static func arguments(
        promptImageURLs: [URL],
        outputURL: URL,
        model: String,
        reasoningEffort: String,
        serviceTier: String = CodexServiceTier.defaultTier.rawValue,
        isEphemeral: Bool = true,
        projectPath: String? = nil
    ) -> [String] {
        // Egress-Grenze: der persistierte "auto"-Sentinel wird erst hier zum
        // aktuellen Frontier-Modell aufgelöst — jede Nutzung profitiert damit
        // automatisch vom neuesten Katalog-Stand.
        var arguments = [
            "exec",
            "-m", CodexModelSelection.resolveSlug(model),
            "-c", "model_reasoning_effort=\(reasoningEffort)",
        ]
        arguments.append(contentsOf: CodexServiceTier.resolve(serviceTier).configArguments)
        arguments.append(contentsOf: [
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--output-last-message", outputURL.path,
        ])

        if let projectPath, !projectPath.isEmpty {
            arguments.append(contentsOf: ["-C", projectPath])
        }

        if isEphemeral {
            arguments.append("--ephemeral")
        }

        for imageURL in promptImageURLs {
            arguments.append(contentsOf: ["--image", imageURL.path])
        }

        arguments.append("-")
        return arguments
    }
}

struct CodexVisualInputSelection {
    let mode: CodexVisualInputMode
    let imageURLs: [URL]
    let videoURLs: [URL]
    let usesFrameFallback: Bool

    init(contextBundle: TranscriptContextBundle, modeRaw: String = AppPreferences.shared.codexVisualInputModeRaw) {
        let resolvedMode = CodexVisualInputMode.resolve(modeRaw)
        self.mode = resolvedMode
        self.videoURLs = contextBundle.screenClips.map(\.fileURL)

        switch resolvedMode {
        case .auto, .frames:
            self.imageURLs = contextBundle.visualAttachments.map(\.fileURL)
            self.usesFrameFallback = false
        case .video:
            self.imageURLs = contextBundle.visualAttachments.map(\.fileURL)
            self.usesFrameFallback = !videoURLs.isEmpty
        }
    }

    func includes(_ attachment: ContextAttachment) -> Bool {
        switch attachment.kind {
        case .screenshot, .annotation, .visualFrame:
            return imageURLs.contains { $0.path == attachment.fileURL.path }
        case .screenClip:
            return videoURLs.contains { $0.path == attachment.fileURL.path }
        }
    }
}

enum CodexConnectionStatus: Equatable {
    case notInstalled
    case installed
    case signedIn
    case notSignedIn
    case unknown

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .installed:
            return "Installed"
        case .signedIn:
            return "Signed in with ChatGPT"
        case .notSignedIn:
            return "Not signed in"
        case .unknown:
            return "Unknown"
        }
    }

    var isReadyForNonInteractiveProcessing: Bool {
        self == .signedIn
    }
}

struct CodexStatusProbe {
    private let commandResolver: (String) -> String?
    private let commandRunner: (String, [String]) -> String

    /// Closures sind Phase-3-Test-Seams: Default = echte CLI-Auflösung/-Ausführung,
    /// in Tests durch Fakes ersetzbar (Status-Parsing ohne echtes `codex`-Binary).
    init(
        commandResolver: @escaping (String) -> String? = { CodexStatusProbe.resolveCommandPath($0) },
        commandRunner: @escaping (String, [String]) -> String = { CodexStatusProbe.runProcess($0, arguments: $1) }
    ) {
        self.commandResolver = commandResolver
        self.commandRunner = commandRunner
    }

    func version() -> String {
        guard let codexPath = commandResolver("codex") else { return "Not installed" }
        return commandRunner(codexPath, ["--version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status() -> CodexConnectionStatus {
        guard let codexPath = commandResolver("codex") else { return .notInstalled }

        let output = commandRunner(codexPath, ["login", "status"])
        let lowercasedOutput = output.lowercased()

        if lowercasedOutput.contains("logged in using chatgpt") {
            return .signedIn
        }

        if lowercasedOutput.contains("not logged in")
            || lowercasedOutput.contains("not authenticated")
            || lowercasedOutput.contains("logged out") {
            return .notSignedIn
        }

        return .installed
    }

    /// Single-Quote-Literal für die Shell: `'` wird zu `'\''` (LR-ONB-017).
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Inhalt des Login-`.command`-Skripts. Der Binary-Pfad wird quotiert: Leerzeichen,
    /// Apostrophe und Metazeichen im Pfad dürfen den Aufruf nicht zerlegen.
    static func loginScript(codexPath: String) -> String {
        """
        #!/bin/zsh
        \(shellSingleQuoted(codexPath)) login
        echo
        echo "You can close this window after login finishes."
        read -k 1 "?Press any key to close..."
        """
    }

    func openLoginInTerminal() {
        guard let codexPath = commandResolver("codex") else {
            NSWorkspace.shared.open(URL(string: "https://help.openai.com/en/articles/11381614-codex-cli-and-sign-in-withgpt")!)
            return
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8-Codex-Login.command")
        let script = Self.loginScript(codexPath: codexPath)

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            NSWorkspace.shared.open(scriptURL)
        } catch {
            Logger.debug("Failed to open Codex login command: \(error.localizedDescription)")
        }
    }

    func commandPath(_ command: String) -> String? {
        commandResolver(command)
    }

    static func resolveCommandPath(_ command: String) -> String? {
        let bundledCodexPath = "/Applications/Codex.app/Contents/Resources/codex"
        if command == "codex",
           FileManager.default.isExecutableFile(atPath: bundledCodexPath) {
            return bundledCodexPath
        }

        return AgentCommandBuilder.commandPath(command)
    }

    /// Läuft IMMER mit korrigiertem Login-Shell-Environment: `codex` kann ein
    /// node-Wrapper sein (npm-Installation), der `node` im PATH braucht — im
    /// minimalen launchd-PATH der GUI scheitert er sonst mit
    /// "env: node: No such file or directory", die Probe meldet dann fälschlich
    /// `.installed` statt `.signedIn` und das Post-Processing verweigert.
    /// `internal` + injizierbares Env für Tests.
    static func runProcess(
        _ path: String,
        arguments: [String],
        environment: [String: String] = LoginShellEnvironment.shared.processEnvironment()
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
