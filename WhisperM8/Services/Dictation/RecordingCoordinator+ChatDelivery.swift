import Foundation

/// Zustellung eines Diktats an einen Agent-Chat statt ins vordere Programm.
/// Der Text geht direkt ins Terminal des Chats (kein Cmd+V, keine
/// Bedienungshilfen). Was nicht geschrieben werden kann, bleibt in der
/// Zwischenablage, und ein Hinweis sagt, warum.
///
/// Grenze dieser Runde: Bild-Anhänge aus dem Kontext werden hier nicht
/// eingefügt, nur der Text.
extension RecordingCoordinator {
    func deliverToChatTarget(
        decision: DictationDeliveryDecision,
        audioURL: URL,
        audioDuration: TimeInterval,
        outputMode: OutputMode,
        contextBundle: TranscriptContextBundle,
        provider: TranscriptionProvider,
        model: TranscriptionModel,
        language: String,
        rawText: String,
        postProcessingResult: PostProcessingRunResult
    ) async {
        guard let appState else { return }
        let finalText = postProcessingResult.finalText
        var copiedToClipboard = false
        var deliveryErrors: [String] = []

        // Wie beim vorderen Programm: erst Zwischenablage und Verlauf, damit
        // der Text auch dann nicht verloren ist, wenn das Schreiben scheitert.
        func copyAndRecord() {
            pasteService.copyToClipboard(finalText)
            copiedToClipboard = true
            _ = dictationHistoryRecorder(.make(
                finalText: finalText, rawText: rawText,
                mode: outputMode, targetApp: overlayController.getPreviousApp()
            ))
            appState.lastFinalTranscription = finalText
            appState.lastTranscription = finalText
        }

        func noteClipboardOnly(_ reason: DictationClipboardReason) {
            let body = Self.clipboardOnlyMessage(for: reason)
            appState.lastError = body
            deliveryErrors.append(body)
            dictationNoticePoster(String(localized: "Text not inserted"), body)
            // Die Mitteilung allein sieht man leicht nicht (Fokus, Mitteilungen
            // aus): Die Pille sagt es kurz selbst, ohne Bewegung (WM8-66).
            overlayController.showQuickActionHint(Self.clipboardOnlyPillHint(for: reason), duration: Self.clipboardOnlyPillSeconds)
        }

        switch decision {
        case .frontApp:
            // Gehört nicht hierher; `transcribeAndDeliver` erledigt diesen Weg selbst.
            assertionFailure("frontApp delivery must not reach the chat branch")
            return
        case .nothing:
            overlayController.hide()
            Logger.paste.info("Dictation for agent chat was empty, nothing delivered")
        case .writeToQuestion(let sessionID):
            copyAndRecord()
            overlayController.hide()
            if chatWriter.writeToQuestion(finalText, to: sessionID) {
                Logger.paste.info("Dictation written into the open question of an agent chat")
            } else {
                // Die Frage war beim Schreiben nicht mehr sicher erkannt.
                Logger.paste.warning("Dictation for an open question kept on clipboard")
                noteClipboardOnly(.decisionPending)
            }
        case .writeToChat(let sessionID, let submit):
            copyAndRecord()
            overlayController.hide()
            if chatWriter.write(finalText, to: sessionID, submit: submit) {
                Logger.paste.info("Dictation written to agent chat submit=\(submit, privacy: .public)")
            } else {
                Logger.paste.warning("Dictation could not be written to agent chat, text stays on clipboard")
                noteClipboardOnly(.writeFailed)
            }
        case .clipboardOnly(let reason):
            copyAndRecord()
            Logger.paste.info("Dictation for agent chat kept on clipboard reason=\(String(describing: reason), privacy: .public)")
            noteClipboardOnly(reason)
        }

        await saveRunReport(
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
            rawText: rawText,
            finalText: finalText,
            copiedToClipboard: copiedToClipboard,
            autoPasteRequested: false,
            pasteErrors: deliveryErrors,
            agentProvider: postProcessingResult.agentProvider,
            agentSessionID: postProcessingResult.agentSessionID,
            agentProjectPath: postProcessingResult.agentProjectPath,
            postProcessing: postProcessingResult.postProcessing
        )

        try? FileManager.default.removeItem(at: audioURL)
        visualContextCaptureService.cleanup(contextBundle)
    }

    /// Kurzer Hinweis in der Pille, wenn ein Diktat nur in der Zwischenablage
    /// liegt. Bei offener Rückfrage ohne ⌘V: In einer Freigabe bewirkt es nichts.
    static func clipboardOnlyPillHint(for reason: DictationClipboardReason) -> String {
        switch reason {
        // Am Limit kein ⌘V-Tipp: auch eingefügter Text würde verbraucht.
        case .decisionPending, .chatUsageLimited: return String(localized: "On the clipboard")
        case .chatStarting, .chatNotRunning, .writeFailed: return String(localized: "On the clipboard · ⌘V to paste")
        }
    }

    static let clipboardOnlyPillSeconds: TimeInterval = 4

    /// Ein Satz je Grund: warum nicht eingefügt wurde und wo der Text liegt.
    static func clipboardOnlyMessage(for reason: DictationClipboardReason) -> String {
        switch reason {
        case .decisionPending:
            return String(localized: "The agent is waiting for your answer, so the dictation wasn't added to the chat. Your text is on the clipboard.")
        case .chatStarting:
            return String(localized: "The chat is still starting, so the dictation wasn't added. Your text is on the clipboard.")
        case .chatUsageLimited:
            return String(localized: "The chat's account has reached its usage limit, so the dictation wasn't added. Your text is on the clipboard.")
        case .chatNotRunning:
            return String(localized: "The chat isn't running anymore, so the dictation wasn't added. Your text is on the clipboard.")
        case .writeFailed:
            return String(localized: "The dictation couldn't be written to the chat. Your text is on the clipboard.")
        }
    }
}
