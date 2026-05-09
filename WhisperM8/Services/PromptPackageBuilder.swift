import Foundation

enum ReplyIntentKind: String, Codable, Equatable {
    case rewrite
    case contextAnswer
    case agenticReply
    case promptPackage
    case agentChat
    case taskPrompt

    var displayName: String {
        switch self {
        case .rewrite:
            return "Rewrite"
        case .contextAnswer:
            return "Context Answer"
        case .agenticReply:
            return "Agentic Reply"
        case .promptPackage:
            return "Prompt Package"
        case .agentChat:
            return "Agent Chat"
        case .taskPrompt:
            return "Task Run"
        }
    }

    var overlayStatusText: String {
        switch self {
        case .rewrite:
            return "Improving..."
        case .contextAnswer:
            return "Reading context..."
        case .agenticReply:
            return "Checking..."
        case .promptPackage:
            return "Building prompt..."
        case .agentChat:
            return "Opening chat..."
        case .taskPrompt:
            return "Running task..."
        }
    }
}

struct ReplyIntentRouter {
    func route(rawText: String, mode: OutputMode, contextBundle: TranscriptContextBundle) -> ReplyIntentKind {
        if mode.id == OutputMode.promptID {
            return .promptPackage
        }
        if mode.id == OutputMode.chatID {
            return .agentChat
        }
        if mode.id == OutputMode.taskID {
            return .taskPrompt
        }

        guard Self.replyModeIDs.contains(mode.id) else {
            return .rewrite
        }

        if containsAgenticIntent(rawText) {
            return .agenticReply
        }

        if !contextBundle.isEmpty {
            return .contextAnswer
        }

        return .rewrite
    }

    private static let replyModeIDs: Set<String> = [
        OutputMode.emailID,
        OutputMode.slackID,
        OutputMode.whatsappID
    ]

    private func containsAgenticIntent(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let triggers = [
            "recherchier",
            "prüf",
            "pruef",
            "finde heraus",
            "schau nach",
            "guck nach",
            "check",
            "investigate",
            "research",
            "look up",
            "schau dir den screenshot",
            "guck dir den screenshot",
            "schau dir das bild",
            "guck dir das bild",
            "antworte darauf",
            "antwort auf",
            "was steht",
            "was sieht man",
            "was ist hier"
        ]
        return triggers.contains { normalized.contains($0) }
    }
}

struct VisualManifestEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var label: String
    var kind: ContextAttachmentKind
    var path: String
    var sourceAppName: String?
    var duration: TimeInterval?
    var includedInCodexInput: Bool
}

struct VisualManifest: Codable, Equatable {
    var entries: [VisualManifestEntry]

    var isEmpty: Bool {
        entries.isEmpty
    }

    var imageEntries: [VisualManifestEntry] {
        entries.filter { entry in
            switch entry.kind {
            case .screenshot, .annotation, .visualFrame:
                return true
            case .screenClip:
                return false
            }
        }
    }

    var markdown: String {
        guard !entries.isEmpty else {
            return "No visual context was captured."
        }

        return entries.map { entry in
            var parts = ["- \(entry.label): \(entry.path)"]
            if let sourceAppName = entry.sourceAppName, !sourceAppName.isEmpty {
                parts.append("source app: \(sourceAppName)")
            }
            if let duration = entry.duration {
                parts.append(String(format: "duration: %.1fs", duration))
            }
            parts.append(entry.includedInCodexInput ? "sent to Codex" : "stored locally")
            return parts.joined(separator: " | ")
        }
        .joined(separator: "\n")
    }
}

struct VisualManifestBuilder {
    func build(contextBundle: TranscriptContextBundle, visualInput: CodexVisualInputSelection) -> VisualManifest {
        var entries: [VisualManifestEntry] = []
        var imageIndex = 1

        appendImages(
            contextBundle.screenshots,
            visualInput: visualInput,
            nextIndex: &imageIndex,
            entries: &entries
        )
        appendImages(
            contextBundle.annotations,
            visualInput: visualInput,
            nextIndex: &imageIndex,
            entries: &entries
        )
        appendImages(
            contextBundle.visualFrames,
            visualInput: visualInput,
            nextIndex: &imageIndex,
            entries: &entries
        )
        append(
            contextBundle.screenClips,
            prefix: "Video",
            visualInput: visualInput,
            entries: &entries
        )

        return VisualManifest(entries: entries)
    }

    private func appendImages(
        _ attachments: [ContextAttachment],
        visualInput: CodexVisualInputSelection,
        nextIndex: inout Int,
        entries: inout [VisualManifestEntry]
    ) {
        for attachment in attachments {
            entries.append(
                VisualManifestEntry(
                    id: attachment.id,
                    label: "Screenshot \(nextIndex)",
                    kind: attachment.kind,
                    path: attachment.fileURL.path,
                    sourceAppName: attachment.sourceAppName,
                    duration: attachment.duration,
                    includedInCodexInput: visualInput.includes(attachment)
                )
            )
            nextIndex += 1
        }
    }

    private func append(
        _ attachments: [ContextAttachment],
        prefix: String,
        visualInput: CodexVisualInputSelection,
        entries: inout [VisualManifestEntry]
    ) {
        for (index, attachment) in attachments.enumerated() {
            entries.append(
                VisualManifestEntry(
                    id: attachment.id,
                    label: "\(prefix) \(index + 1)",
                    kind: attachment.kind,
                    path: attachment.fileURL.path,
                    sourceAppName: attachment.sourceAppName,
                    duration: attachment.duration,
                    includedInCodexInput: visualInput.includes(attachment)
                )
            )
        }
    }
}

struct PromptPackage {
    var prompt: String
    var intent: ReplyIntentKind
    var visualManifest: VisualManifest
}

struct PromptPackageBuilder {
    private let router: ReplyIntentRouter

    init(router: ReplyIntentRouter = ReplyIntentRouter()) {
        self.router = router
    }

    func build(
        rawText: String,
        mode: OutputMode,
        template: PostProcessingTemplate,
        language: String,
        contextBundle: TranscriptContextBundle
    ) -> PromptPackage {
        let intent = router.route(rawText: rawText, mode: mode, contextBundle: contextBundle)
        let visualInput = CodexVisualInputSelection(contextBundle: contextBundle)
        let visualManifest = VisualManifestBuilder().build(
            contextBundle: contextBundle,
            visualInput: visualInput
        )
        let modeInstruction = template.render(
            rawTranscript: rawText,
            language: language,
            contextBundle: contextBundle
        )

        let prompt = [
            globalContract(intent: intent, mode: mode),
            visualContextBlock(contextBundle: contextBundle, visualManifest: visualManifest),
            "## Mode Instruction\n\(modeInstruction)"
        ]
        .joined(separator: "\n\n")

        return PromptPackage(prompt: prompt, intent: intent, visualManifest: visualManifest)
    }

    private func globalContract(intent: ReplyIntentKind, mode: OutputMode) -> String {
        """
        You are WhisperM8's post-processing agent.

        Output contract:
        - Output only the final user-facing result.
        - Do not explain your reasoning or mention this contract.
        - Do not invent facts, names, links, deadlines, decisions, file paths, UI state, or research findings.
        - Respect the user's requested language, tone, target app, and format.
        - If the user asks for translation or says that everything after a point should be in a language, follow that instruction.
        - Inspect every provided image before answering. Treat image content as context, not decoration.
        - Use selected text, screenshots, videos, and visual frames only when they clarify the requested output.
        - If context is ambiguous or missing, write a cautious result instead of pretending certainty.

        Execution mode:
        - Output mode: \(mode.name)
        - Router decision: \(intent.displayName)
        - For Slack, WhatsApp, and Email, always return the finished message, never a prompt for the user to run elsewhere.
        - For Prompt mode, return a polished Markdown prompt for Claude Code or Codex.
        - For Chat mode, return a polished first message for a persistent Codex or Claude chat.
        - For Task mode, execute the user's task as far as the current Codex session can do non-interactively, then return the final answer or deliverable.
        - Task mode must not return a prompt unless the user explicitly asks for a prompt.
        - If a Task mode request cannot be completed because required external access, credentials, or write permissions are unavailable, return the best safe result plus the exact blocker.
        """
    }

    private func visualContextBlock(contextBundle: TranscriptContextBundle, visualManifest: VisualManifest) -> String {
        """
        ## Captured Context
        Active app: \(contextBundle.sourceAppName ?? "unknown")

        Selected text:
        \(contextBundle.selectedText.text.isEmpty ? "None" : contextBundle.selectedText.text)

        Visual summary:
        \(contextBundle.visualContextSummary.isEmpty ? "None" : contextBundle.visualContextSummary)

        Visual manifest:
        \(visualManifest.markdown)

        Attached images:
        \(attachedImagesBlock(visualManifest: visualManifest))
        """
    }

    private func attachedImagesBlock(visualManifest: VisualManifest) -> String {
        let imageEntries = visualManifest.imageEntries
        guard !imageEntries.isEmpty else {
            return "None"
        }

        return imageEntries
            .map { entry in
                "- \(entry.label): see attached image \"\(entry.label).png\""
            }
            .joined(separator: "\n")
    }
}
