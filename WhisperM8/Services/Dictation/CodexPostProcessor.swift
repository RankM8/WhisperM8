import Foundation

struct CodexPostProcessor: PostProcessing {
    private let templateStore: PostProcessingTemplateStore
    private let promptPackageBuilder: PromptPackageBuilder
    /// Hot-Path nutzt den TTL-Cache; die Settings-UI probt weiterhin direkt
    /// (immer frische Anzeige). Closure-DI für Tests.
    private let statusProvider: () -> CodexConnectionStatus

    init(
        templateStore: PostProcessingTemplateStore = PostProcessingTemplateStore(),
        promptPackageBuilder: PromptPackageBuilder = PromptPackageBuilder(),
        statusProvider: @escaping () -> CodexConnectionStatus = { CodexStatusCache.shared.status() }
    ) {
        self.templateStore = templateStore
        self.promptPackageBuilder = promptPackageBuilder
        self.statusProvider = statusProvider
    }

    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        guard let template = templateStore.template(for: mode.templateID) else {
            throw PostProcessingError.missingTemplate
        }

        let status = statusProvider()
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
        // Projekt-Auflösung passiert hier (nicht in performCodexRun), weil nur
        // process() das contextBundle mit dem aktiven Agent-Chat kennt.
        let projectPath = ProjectPathResolver.resolvedProjectPath(
            mode: mode,
            agentChatProjectPath: contextBundle.agentChat?.projectPath,
            defaultProjectPath: AppPreferences.shared.agentDefaultProjectPath
        )
        return try await runCodex(
            prompt: package.prompt,
            imageURLs: visualInput.imageURLs,
            mode: mode,
            projectPath: projectPath
        )
    }

    private func runCodex(prompt: String, imageURLs: [URL], mode: OutputMode, projectPath: String?) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try performCodexRun(prompt: prompt, imageURLs: imageURLs, mode: mode, projectPath: projectPath)
        }.value
    }

    private func performCodexRun(prompt: String, imageURLs: [URL], mode: OutputMode, projectPath: String?) throws -> String {
        guard let codexPath = CodexStatusProbe().commandPath("codex") else {
            throw PostProcessingError.codexUnavailable("Codex CLI is not installed.")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8-Codex-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.currentDirectoryURL = projectPath.map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
        process.arguments = CodexInvocation.arguments(
            promptImageURLs: imageURLs,
            outputURL: outputURL,
            model: mode.resolvedCodexModelRaw(),
            reasoningEffort: mode.resolvedCodexReasoningEffortRaw(),
            serviceTier: mode.resolvedCodexServiceTierRaw(),
            isEphemeral: mode.id != OutputMode.taskID,
            projectPath: projectPath
        )
        // Korrigierter PATH, falls Codex CLI intern Tools wie `git` aufruft.
        process.environment = LoginShellEnvironment.shared.processEnvironment()

        let inputPipe = Pipe()
        let logPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = logPipe
        process.standardError = logPipe

        let activityLock = NSLock()
        var collectedLog = Data()
        logPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            activityLock.lock()
            collectedLog.append(chunk)
            activityLock.unlock()
        }

        CodexProcessRegistry.shared.resetCancelFlag()

        do {
            try process.run()
            CodexProcessRegistry.shared.register(process)
            if let data = prompt.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            logPipe.fileHandleForReading.readabilityHandler = nil
            throw PostProcessingError.codexUnavailable("Failed to start Codex: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        logPipe.fileHandleForReading.readabilityHandler = nil
        // Restbytes konsumieren, falls Pipe-Buffer noch was hat.
        let trailing = (try? logPipe.fileHandleForReading.readToEnd()) ?? Data()
        activityLock.lock()
        collectedLog.append(trailing)
        let logData = collectedLog
        activityLock.unlock()
        let logOutput = String(data: logData, encoding: .utf8) ?? ""

        let wasCancelledByUser = CodexProcessRegistry.shared.didCancel
        CodexProcessRegistry.shared.unregister(process)

        if wasCancelledByUser {
            throw PostProcessingError.userCancelled
        }

        guard process.terminationStatus == 0 else {
            let message = CodexErrorSummary.concise(from: logOutput)
            // Scheiterte der Lauf an fehlender Anmeldung, war der gecachte
            // .signedIn-Status stale — nächster Lauf probt frisch.
            if logOutput.lowercased().contains("not logged in") {
                CodexStatusCache.shared.invalidate()
            }
            throw PostProcessingError.codexUnavailable(message)
        }

        guard let output = try? String(contentsOf: outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            throw PostProcessingError.codexUnavailable("Codex returned no post-processed text.")
        }

        return output
    }

}
