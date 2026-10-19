import Foundation

struct CodexPostProcessor: PostProcessing {
    private let templateStore: PostProcessingTemplateStore
    private let promptPackageBuilder: PromptPackageBuilder
    /// Hot-Path nutzt den TTL-Cache; die Settings-UI probt weiterhin direkt
    /// (immer frische Anzeige). Closure-DI für Tests.
    private let statusProvider: () -> CodexConnectionStatus
    /// Auflösung des codex-Binarys (Closure-DI für Tests mit Fake-Skript).
    private let commandPathResolver: () -> String?
    private let registry: CodexProcessRegistry
    /// Hartes Zeitlimit je Lauf (LR-DIK-013). Großzügig, weil der Task-Modus mit
    /// Projektzugriff legitim lange arbeitet; nur ein Hänger soll hier enden.
    private let timeoutProvider: (OutputMode) -> TimeInterval

    static func defaultTimeout(for mode: OutputMode) -> TimeInterval {
        (mode.id == OutputMode.taskID || mode.projectAccess != .off) ? 900 : 300
    }

    init(
        templateStore: PostProcessingTemplateStore = PostProcessingTemplateStore(),
        promptPackageBuilder: PromptPackageBuilder = PromptPackageBuilder(),
        statusProvider: @escaping () -> CodexConnectionStatus = { CodexStatusCache.shared.status() },
        commandPathResolver: @escaping () -> String? = { CodexStatusProbe().commandPath("codex") },
        registry: CodexProcessRegistry = .shared,
        timeoutProvider: @escaping (OutputMode) -> TimeInterval = CodexPostProcessor.defaultTimeout(for:)
    ) {
        self.templateStore = templateStore
        self.promptPackageBuilder = promptPackageBuilder
        self.statusProvider = statusProvider
        self.commandPathResolver = commandPathResolver
        self.registry = registry
        self.timeoutProvider = timeoutProvider
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
        // Eigene Run-ID und Besitzer je Lauf: der Overlay-Abbruch trifft nur Diktat-Läufe,
        // Task-Cancellation nur diesen Lauf (Task-Locals erbt Task.detached nicht → vorher lesen).
        let runID = UUID()
        let owner = CodexRunOwner.current
        let timeout = timeoutProvider(mode)
        let registry = registry
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try performCodexRun(
                    prompt: prompt, imageURLs: imageURLs, mode: mode, projectPath: projectPath,
                    runID: runID, owner: owner, timeout: timeout
                )
            }.value
        } onCancel: {
            registry.cancel(runID: runID)
        }
    }

    private func performCodexRun(
        prompt: String, imageURLs: [URL], mode: OutputMode, projectPath: String?,
        runID: UUID, owner: CodexRunOwner, timeout: TimeInterval
    ) throws -> String {
        guard let codexPath = commandPathResolver() else {
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

        do {
            try process.run()
            registry.register(process, runID: runID, owner: owner)
            if let data = prompt.data(using: .utf8) {
                // Throwing-API: das alte `write(_:)` wirft bei EPIPE (Codex
                // vor dem Lesen beendet) eine NSException — die beendet die
                // App genauso wie ein SIGPIPE (siehe SigpipeGuard).
                try? inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            logPipe.fileHandleForReading.readabilityHandler = nil
            throw PostProcessingError.codexUnavailable("Failed to start Codex: \(error.localizedDescription)")
        }

        // Abschlussgarantie: nach Ablauf des Limits TERM, nach Gnadenfrist KILL.
        let deadline = DispatchWorkItem { [registry] in registry.expire(runID: runID) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        process.waitUntilExit()
        deadline.cancel()

        let outcome = registry.outcome(runID: runID)
        logPipe.fileHandleForReading.readabilityHandler = nil
        // Restbytes konsumieren, falls Pipe-Buffer noch was hat. Bei Abbruch/Timeout nicht:
        // ein verwaistes Kindprozess-Ende könnte das Pipe-Ende offen halten und blockieren.
        let trailing = outcome == .none ? ((try? logPipe.fileHandleForReading.readToEnd()) ?? Data()) : Data()
        activityLock.lock()
        collectedLog.append(trailing)
        let logData = collectedLog
        activityLock.unlock()
        let logOutput = String(data: logData, encoding: .utf8) ?? ""

        registry.unregister(runID: runID)

        if outcome == .cancelledByUser {
            throw PostProcessingError.userCancelled
        }
        if outcome == .timedOut {
            throw PostProcessingError.timedOut(timeout)
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
