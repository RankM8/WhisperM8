import AppKit
import Foundation

/// Trackt den aktuell laufenden Codex-Subprocess für externes Cancel
/// (z. B. Cancel-Button im Recording-Overlay).
final class CodexProcessRegistry: @unchecked Sendable {
    static let shared = CodexProcessRegistry()

    private let lock = NSLock()
    private weak var current: Process?
    private var cancelledByUser = false

    private init() {}

    func register(_ process: Process) {
        lock.lock()
        current = process
        cancelledByUser = false
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        if current === process {
            current = nil
        }
        lock.unlock()
    }

    /// Bricht einen laufenden Codex-Subprocess auf Anforderung ab (Cancel-Button).
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        let process = current
        cancelledByUser = true
        lock.unlock()
        guard let process, process.isRunning else { return false }
        process.terminate()
        return true
    }

    var didCancel: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledByUser
    }

    func resetCancelFlag() {
        lock.lock(); cancelledByUser = false; lock.unlock()
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
        var arguments = [
            "exec",
            "-m", model,
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
    func version() -> String {
        guard let codexPath = commandPath("codex") else { return "Not installed" }
        return run(codexPath, arguments: ["--version"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status() -> CodexConnectionStatus {
        guard let codexPath = commandPath("codex") else { return .notInstalled }

        let output = run(codexPath, arguments: ["login", "status"])
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

    func openLoginInTerminal() {
        guard let codexPath = commandPath("codex") else {
            NSWorkspace.shared.open(URL(string: "https://help.openai.com/en/articles/11381614-codex-cli-and-sign-in-withgpt")!)
            return
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8-Codex-Login.command")
        let script = """
        #!/bin/zsh
        \(codexPath) login
        echo
        echo "You can close this window after login finishes."
        read -k 1 "?Press any key to close..."
        """

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
        let bundledCodexPath = "/Applications/Codex.app/Contents/Resources/codex"
        if command == "codex",
           FileManager.default.isExecutableFile(atPath: bundledCodexPath) {
            return bundledCodexPath
        }

        return AgentCommandBuilder.commandPath(command)
    }

    private func run(_ path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
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
