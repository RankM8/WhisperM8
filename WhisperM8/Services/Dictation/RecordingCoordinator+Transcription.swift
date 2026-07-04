import Foundation
import AppKit

/// Transkriptions-Auslieferung des RecordingCoordinator: Whisper/Groq-Call,
/// optionales Codex-Post-Processing, Routing in Clipboard/Auto-Paste/Agent-Chat
/// und das Schreiben des Run-Reports. Aus RecordingCoordinator.swift
/// ausgelagert (Phase-2-Split); Fassade + Aufruf-API unveraendert.
extension RecordingCoordinator {
    func transcribeAndDeliver(
        audioURL: URL,
        audioDuration: TimeInterval,
        outputMode: OutputMode,
        contextBundle: TranscriptContextBundle
    ) async throws {
        guard let appState else { return }

        let provider = providerResolver()
        let model = modelResolver()
        Logger.debug("Using provider: \(provider.rawValue), model: \(model.rawValue)")

        guard let apiKey = apiKeyResolver(provider), !apiKey.isEmpty else {
            Logger.debug("ERROR: No API key found for \(provider.keychainKey)")
            throw TranscriptionError.missingAPIKey
        }
        Logger.debug(" API key loaded (length: \(apiKey.count))")

        let language = AppPreferences.shared.language
        Logger.debug(" Language: \(language)")

        let service = transcriberFactory(provider, model, apiKey)
        Logger.debug(" Starting transcription...")

        let rawText = try await service.transcribe(
            audioURL: audioURL,
            language: language.isEmpty ? nil : language,
            audioDuration: audioDuration
        )

        // Später Abbruch (Cancel/ESC exakt beim Eintreffen der Response) soll
        // sauber im Preserve-Pfad landen statt mit gesetztem Cancel-Flag in
        // die Delivery zu laufen — dort würde `Task.sleep` im PasteService
        // alle Paste-Delays auf 0 kollabieren lassen (Cmd+V-Race).
        try Task.checkCancellation()
        // Ab hier ist die Response da: Ein Cancel darf nichts mehr abbrechen.
        isDeliveringTranscription = true

        let normalizedRawText = TextNormalizer.normalizeTranscriptionText(rawText)

        Logger.debug(" Transcription SUCCESS! Raw length: \(rawText.count), normalized length: \(normalizedRawText.count)")
        Logger.debug(" Text preview: \(String(normalizedRawText.prefix(100)))...")

        appState.lastRawTranscription = normalizedRawText

        let postProcessingResult = try await processTranscriptIfNeeded(
            normalizedRawText,
            mode: outputMode,
            language: language,
            contextBundle: contextBundle
        )
        let finalText = postProcessingResult.finalText
        let autoPasteRequested = AppPreferences.shared.isAutoPasteEnabled && outputMode.id != OutputMode.chatID
        var deliveryAttachments: [PasteAttachment] = []
        var deliveryErrors: [String] = []

        if autoPasteRequested {
            do {
                deliveryAttachments = try visualAttachmentDeliveryBuilder.build(
                    contextBundle: contextBundle,
                    mode: outputMode
                )
            } catch {
                let message = "Could not prepare visual attachments for paste: \(error.localizedDescription)"
                Logger.paste.error("\(message, privacy: .public)")
                deliveryErrors.append(message)
            }
        }

        pasteService.copyToClipboard(finalText)
        appState.lastFinalTranscription = finalText
        appState.lastTranscription = finalText

        var pasteResult = PasteDeliveryResult.notRequested

        if autoPasteRequested {
            let previousApp = overlayController.getPreviousApp()
            overlayController.hide()
            pasteResult = await pasteService.pastePayloadToActiveApp(
                PastePayload(
                    text: finalText,
                    attachments: deliveryAttachments,
                    restoreTextToClipboardAfterPaste: true
                ),
                previousApp: previousApp,
                onMissingPermission: {
                    appState.lastError = "Accessibility permission required for auto-paste"
                    overlayController.hide()
                },
                onMissingTarget: {
                    overlayController.hide()
                }
            )
        } else {
            overlayController.hide()
            Logger.debug(" Auto-paste disabled, text copied to clipboard only")
        }

        deliveryErrors.append(contentsOf: pasteResult.errors)
        if appState.lastError == nil, let firstError = deliveryErrors.first {
            appState.lastError = firstError
        }

        saveRunReport(
            status: postProcessingResult.fallbackStatus ?? (postProcessingResult.errorMessage == nil ? .succeeded : .rawFallback),
            errorMessage: postProcessingResult.errorMessage,
            outputMode: outputMode,
            provider: provider,
            model: model,
            language: language,
            audioDuration: audioDuration,
            contextBundle: contextBundle,
            renderedPrompt: postProcessingResult.renderedPrompt,
            replyIntent: postProcessingResult.replyIntent,
            visualManifest: postProcessingResult.visualManifest,
            rawText: normalizedRawText,
            finalText: finalText,
            copiedToClipboard: true,
            autoPasteRequested: autoPasteRequested,
            autoPasteTextRequested: autoPasteRequested,
            autoPasteAttachmentsRequested: autoPasteRequested && !deliveryAttachments.isEmpty,
            pastedAttachmentCount: pasteResult.pastedAttachments.count,
            pasteErrors: deliveryErrors,
            deliveryAttachmentLabels: deliveryAttachments.map(\.label),
            agentProvider: postProcessingResult.agentProvider,
            agentSessionID: postProcessingResult.agentSessionID,
            agentProjectPath: postProcessingResult.agentProjectPath
        )

        try? FileManager.default.removeItem(at: audioURL)
        visualContextCaptureService.cleanup(contextBundle)
    }

    func processTranscriptIfNeeded(
        _ rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) async throws -> PostProcessingRunResult {
        guard let appState else {
            return PostProcessingRunResult(finalText: rawText)
        }

        guard mode.usesPostProcessing else {
            return PostProcessingRunResult(finalText: rawText)
        }

        // Letzter Sweep + Live-Bundle statt des beim Stop eingefrorenen:
        // Kopien WÄHREND der Transkription (der 500-ms-Monitor läuft weiter)
        // fließen so noch in den Prompt ein. Overlay-Edits sind in den
        // Busy-Phasen gesperrt — das Live-Bundle ist also stets ein Superset
        // des eingefrorenen. Leeres Live-Bundle = Retry-Pfad (appState wurde
        // nach dem Erstlauf geleert) → dort gilt das mitgegebene Bundle.
        observeClipboardChange()
        let contextBundle = appState.contextBundle.isEmpty ? contextBundle : appState.contextBundle

        let allowedContextBundle = postProcessingService.allowedContextBundle(for: mode, capturedContext: contextBundle)
        let promptPackage = postProcessingService.promptPackage(
            rawText: rawText,
            mode: mode,
            language: language,
            contextBundle: allowedContextBundle
        )
        let renderedPrompt = promptPackage?.prompt

        appState.isTranscribing = false
        appState.isPostProcessing = true
        appState.postProcessingStatusText = promptPackage?.intent.overlayStatusText
        overlayController.update(appState: appState)

        do {
            if mode.id == OutputMode.chatID, let promptPackage {
                let visualInput = CodexVisualInputSelection(contextBundle: contextBundle)
                let result = try agentChatLauncherFactory().openCodexChat(
                    title: chatTitle(from: rawText),
                    prompt: promptPackage.prompt,
                    imagePaths: visualInput.imageURLs.map(\.path)
                )
                appState.isPostProcessing = false
                appState.postProcessingStatusText = nil
                overlayController.update(appState: appState)
                return PostProcessingRunResult(
                    finalText: "Opened Codex chat: \(result.session.title)",
                    renderedPrompt: renderedPrompt,
                    replyIntent: promptPackage.intent,
                    visualManifest: promptPackage.visualManifest,
                    agentProvider: .codex,
                    agentSessionID: result.session.externalSessionID ?? result.session.id.uuidString,
                    agentProjectPath: result.project.path
                )
            }

            let processedText = try await postProcessingService.process(
                rawText: rawText,
                mode: mode,
                language: language,
                contextBundle: contextBundle
            )
            let agentSession = mode.id == OutputMode.taskID ? latestTaskAgentSession() : nil
            appState.isPostProcessing = false
            appState.postProcessingStatusText = nil
            overlayController.update(appState: appState)
            return PostProcessingRunResult(
                finalText: TextNormalizer.normalizeTranscriptionText(processedText),
                renderedPrompt: renderedPrompt,
                replyIntent: promptPackage?.intent,
                visualManifest: promptPackage?.visualManifest,
                agentProvider: agentSession?.provider,
                agentSessionID: agentSession?.externalSessionID,
                agentProjectPath: agentSession?.projectPath
            )
        } catch {
            appState.isPostProcessing = false
            appState.postProcessingStatusText = nil
            overlayController.update(appState: appState)

            if case PostProcessingError.userCancelled = error {
                Logger.transcription.info("Post-processing cancelled by user; using raw transcript without surfacing an error")
                return PostProcessingRunResult(
                    finalText: rawText,
                    renderedPrompt: renderedPrompt,
                    replyIntent: promptPackage?.intent,
                    visualManifest: promptPackage?.visualManifest,
                    fallbackStatus: .rawFallback
                )
            }

            if AppPreferences.shared.fallbackToRawOnProcessingError {
                let message = error.localizedDescription
                appState.lastError = message
                Logger.transcription.error("Post-processing failed; falling back to raw: \(message)")
                let fallback = cautiousFallbackText(
                    rawText: rawText,
                    mode: mode,
                    intent: promptPackage?.intent
                )
                return PostProcessingRunResult(
                    finalText: fallback.text,
                    renderedPrompt: renderedPrompt,
                    replyIntent: promptPackage?.intent,
                    visualManifest: promptPackage?.visualManifest,
                    fallbackStatus: fallback.status,
                    errorMessage: message
                )
            }

            throw error
        }
    }

    func chatTitle(from rawText: String) -> String {
        let trimmed = rawText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Voice Chat" }
        return String(trimmed.prefix(52))
    }

    func latestTaskAgentSession() -> (provider: AgentProvider, externalSessionID: String?, projectPath: String?)? {
        let projectPath = AppPreferences.shared.agentDefaultProjectPath
        do {
            let store = AgentSessionStore()
            let indexedSessions = CodexSessionIndexer().indexedSessions(limit: 20)
            try store.mergeIndexedSessions(indexedSessions)
            let latest = indexedSessions.first { URL(fileURLWithPath: $0.cwd).standardizedFileURL.path == URL(fileURLWithPath: projectPath).standardizedFileURL.path }
            return latest.map { ($0.provider, $0.externalSessionID, $0.cwd) }
        } catch {
            Logger.debug("Failed to sync task agent session: \(error.localizedDescription)")
            return nil
        }
    }

    func cautiousFallbackText(
        rawText: String,
        mode: OutputMode,
        intent: ReplyIntentKind?
    ) -> (text: String, status: TranscriptRunStatus) {
        guard intent == .agenticReply || intent == .contextAnswer else {
            return (rawText, .rawFallback)
        }

        switch mode.id {
        case OutputMode.slackID:
            return ("Ich prüfe das kurz sauber und melde mich direkt mit einer konkreten Antwort.", .cautiousFallback)
        case OutputMode.whatsappID:
            return ("Ich schau mir das kurz in Ruhe an und melde mich gleich mit einer konkreten Antwort.", .cautiousFallback)
        case OutputMode.emailID:
            return ("Ich prüfe das kurz sorgfältig und melde mich anschließend mit einer konkreten Antwort.", .cautiousFallback)
        default:
            return (rawText, .rawFallback)
        }
    }

    func saveRunReport(
        status: TranscriptRunStatus,
        errorMessage: String?,
        outputMode: OutputMode,
        provider: TranscriptionProvider,
        model: TranscriptionModel,
        language: String,
        audioDuration: TimeInterval,
        contextBundle: TranscriptContextBundle,
        renderedPrompt: String?,
        replyIntent: ReplyIntentKind?,
        visualManifest: VisualManifest?,
        rawText: String?,
        finalText: String?,
        copiedToClipboard: Bool,
        autoPasteRequested: Bool,
        autoPasteTextRequested: Bool = false,
        autoPasteAttachmentsRequested: Bool = false,
        pastedAttachmentCount: Int = 0,
        pasteErrors: [String] = [],
        deliveryAttachmentLabels: [String] = [],
        agentProvider: AgentProvider? = nil,
        agentSessionID: String? = nil,
        agentProjectPath: String? = nil
    ) {
        let draft = TranscriptRunReportDraft(
            sourceAppName: contextSourceApp?.localizedName,
            sourceBundleIdentifier: contextSourceApp?.bundleIdentifier,
            status: status,
            errorMessage: errorMessage,
            mode: outputMode,
            provider: provider,
            transcriptionModel: model,
            language: language,
            audioDuration: audioDuration,
            contextBundle: contextBundle,
            renderedPrompt: renderedPrompt,
            replyIntent: replyIntent,
            visualManifest: visualManifest,
            rawTranscript: rawText,
            finalTranscript: finalText,
            copiedToClipboard: copiedToClipboard,
            autoPasteRequested: autoPasteRequested,
            autoPasteTextRequested: autoPasteTextRequested,
            autoPasteAttachmentsRequested: autoPasteAttachmentsRequested,
            pastedAttachmentCount: pastedAttachmentCount,
            pasteErrors: pasteErrors,
            deliveryAttachmentLabels: deliveryAttachmentLabels,
            agentProvider: agentProvider,
            agentSessionID: agentSessionID,
            agentProjectPath: agentProjectPath
        )

        do {
            appState?.lastTranscriptRunReport = try reportStore.save(draft)
        } catch {
            Logger.debug("Failed to save transcript report: \(error.localizedDescription)")
        }
    }
}
