import Foundation
import AppKit

protocol PostProcessing {
    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String
}

enum PostProcessingError: LocalizedError, Equatable {
    case missingTemplate
    case codexUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingTemplate:
            return "No template is configured for this output mode."
        case .codexUnavailable(let message):
            return message
        }
    }
}

struct NoOpPostProcessor: PostProcessing {
    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        rawText
    }
}

struct MockPostProcessor: PostProcessing {
    var output: String
    var onProcess: ((String, OutputMode, String, TranscriptContextBundle) -> Void)?

    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        onProcess?(rawText, mode, language, contextBundle)
        return output
    }
}

struct CodexPostProcessor: PostProcessing {
    private let templateStore: PostProcessingTemplateStore
    private let promptPackageBuilder: PromptPackageBuilder

    init(
        templateStore: PostProcessingTemplateStore = PostProcessingTemplateStore(),
        promptPackageBuilder: PromptPackageBuilder = PromptPackageBuilder()
    ) {
        self.templateStore = templateStore
        self.promptPackageBuilder = promptPackageBuilder
    }

    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        guard let template = templateStore.template(for: mode.templateID) else {
            throw PostProcessingError.missingTemplate
        }

        let status = CodexStatusProbe().status()
        guard status.isReadyForNonInteractiveProcessing else {
            throw PostProcessingError.codexUnavailable(
                "Codex post-processing is not ready. Raw transcript was used instead."
            )
        }

        let visualInput = CodexVisualInputSelection(contextBundle: contextBundle)
        let package = promptPackageBuilder.build(
            rawText: rawText,
            mode: mode,
            template: template,
            language: language,
            contextBundle: contextBundle
        )
        return try await runCodex(prompt: package.prompt, imageURLs: visualInput.imageURLs)
    }

    private func runCodex(prompt: String, imageURLs: [URL]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try performCodexRun(prompt: prompt, imageURLs: imageURLs)
        }.value
    }

    private func performCodexRun(prompt: String, imageURLs: [URL]) throws -> String {
        guard let codexPath = CodexStatusProbe().commandPath("codex") else {
            throw PostProcessingError.codexUnavailable("Codex CLI is not installed.")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8-Codex-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.arguments = CodexInvocation.arguments(
            promptImageURLs: imageURLs,
            outputURL: outputURL,
            model: AppPreferences.shared.codexPostProcessingModelRaw,
            reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw
        )

        let inputPipe = Pipe()
        let logPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = logPipe
        process.standardError = logPipe

        do {
            try process.run()
            if let data = prompt.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            throw PostProcessingError.codexUnavailable("Failed to start Codex: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let logData = logPipe.fileHandleForReading.readDataToEndOfFile()
        let logOutput = String(data: logData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = conciseCodexError(from: logOutput)
            throw PostProcessingError.codexUnavailable(message)
        }

        guard let output = try? String(contentsOf: outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            throw PostProcessingError.codexUnavailable("Codex returned no post-processed text.")
        }

        return output
    }

    private func conciseCodexError(from output: String) -> String {
        if output.contains("requires a newer version of Codex") {
            return "Codex CLI needs an update before post-processing can run."
        }
        if output.lowercased().contains("not logged in") {
            return "Codex is not signed in with ChatGPT."
        }
        if let lastLine = output
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return lastLine
        }
        return "Codex post-processing failed."
    }
}

struct PostProcessingService {
    var processor: PostProcessing

    init(processor: PostProcessing = CodexPostProcessor()) {
        self.processor = processor
    }

    func process(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle = .empty
    ) async throws -> String {
        guard mode.usesPostProcessing else {
            return try await NoOpPostProcessor().process(
                rawText: rawText,
                mode: mode,
                language: language,
                contextBundle: contextBundle
            )
        }

        let allowedContext = allowedContextBundle(for: mode, capturedContext: contextBundle)
        if mode.contextPolicy == .required, allowedContext.isEmpty {
            throw PostProcessingError.codexUnavailable("This mode requires context, but no selected text or visual context was captured.")
        }

        return try await processor.process(
            rawText: rawText,
            mode: mode,
            language: language,
            contextBundle: allowedContext
        )
    }

    func allowedContextBundle(for mode: OutputMode, capturedContext: TranscriptContextBundle) -> TranscriptContextBundle {
        switch mode.contextPolicy {
        case .off:
            return .empty
        case .auto, .required:
            return capturedContext
        }
    }

    func renderedPrompt(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) -> String? {
        guard mode.usesPostProcessing,
              let template = PostProcessingTemplateStore().template(for: mode.templateID) else {
            return nil
        }
        return PromptPackageBuilder().build(
            rawText: rawText,
            mode: mode,
            template: template,
            language: language,
            contextBundle: contextBundle
        ).prompt
    }

    func promptPackage(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) -> PromptPackage? {
        guard mode.usesPostProcessing,
              let template = PostProcessingTemplateStore().template(for: mode.templateID) else {
            return nil
        }
        return PromptPackageBuilder().build(
            rawText: rawText,
            mode: mode,
            template: template,
            language: language,
            contextBundle: contextBundle
        )
    }

    func process(
        rawText: String,
        mode: OutputMode,
        language: String,
        selectedContext: SelectedContext
    ) async throws -> String {
        try await process(
            rawText: rawText,
            mode: mode,
            language: language,
            contextBundle: TranscriptContextBundle(selectedText: selectedContext)
        )
    }
}

enum CodexInvocation {
    static func arguments(
        promptImageURLs: [URL],
        outputURL: URL,
        model: String,
        reasoningEffort: String
    ) -> [String] {
        var arguments = [
            "exec",
            "-m", model,
            "-c", "model_reasoning_effort=\(reasoningEffort)",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ephemeral",
            "--output-last-message", outputURL.path,
        ]

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
        if FileManager.default.isExecutableFile(atPath: bundledCodexPath) {
            return bundledCodexPath
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
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
