import Foundation

struct TranscriptRunReportDraft {
    var id = UUID()
    var createdAt = Date()
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var status: TranscriptRunStatus
    var errorMessage: String?
    var mode: OutputMode
    var provider: TranscriptionProvider
    var transcriptionModel: TranscriptionModel
    var language: String
    var audioDuration: TimeInterval
    var contextBundle: TranscriptContextBundle
    var renderedPrompt: String?
    var rawTranscript: String?
    var finalTranscript: String?
    var copiedToClipboard: Bool
    var autoPasteRequested: Bool
}

struct TranscriptRunReportStore {
    private let reportsDirectory: URL

    init(reportsDirectory: URL? = nil) {
        if let reportsDirectory {
            self.reportsDirectory = reportsDirectory
        } else {
            self.reportsDirectory = Self.defaultReportsDirectory()
        }
    }

    func save(_ draft: TranscriptRunReportDraft) throws -> TranscriptRunReport {
        let runDirectory = reportsDirectory
            .appendingPathComponent(draft.id.uuidString, isDirectory: true)
        let attachmentsDirectory = runDirectory
            .appendingPathComponent("Attachments", isDirectory: true)

        try FileManager.default.createDirectory(
            at: attachmentsDirectory,
            withIntermediateDirectories: true
        )

        let visualInput = CodexVisualInputSelection(contextBundle: draft.contextBundle)
        let attachments = try draft.contextBundle.allAttachments.map { attachment in
            try attachmentReport(
                for: attachment,
                visualInput: visualInput,
                attachmentsDirectory: attachmentsDirectory
            )
        }
        let imageInputPaths = attachments
            .filter { attachment in
                attachment.includedInCodexInput
                    && visualInput.imageURLs.contains { $0.path == attachment.originalPath }
            }
            .compactMap(\.storedPath)
        let videoInputPaths = attachments
            .filter { attachment in
                attachment.kind == .screenClip
                    && visualInput.videoURLs.contains { $0.path == attachment.originalPath }
            }
            .compactMap(\.storedPath)

        let codex: TranscriptRunReport.CodexSnapshot?
        if draft.mode.usesPostProcessing {
            let outputURL = runDirectory.appendingPathComponent("codex-output.txt")
            codex = TranscriptRunReport.CodexSnapshot(
                model: AppPreferences.shared.codexPostProcessingModelRaw,
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                visualInputMode: visualInput.mode.rawValue,
                commandPreview: CodexInvocation.arguments(
                    promptImageURLs: imageInputPaths.map(URL.init(fileURLWithPath:)),
                    outputURL: outputURL,
                    model: AppPreferences.shared.codexPostProcessingModelRaw,
                    reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw
                ),
                imageInputPaths: imageInputPaths,
                videoInputPaths: videoInputPaths,
                usesFrameFallbackForVideo: visualInput.usesFrameFallback
            )
        } else {
            codex = nil
        }

        let report = TranscriptRunReport(
            id: draft.id,
            createdAt: draft.createdAt,
            sourceAppName: draft.sourceAppName ?? draft.contextBundle.sourceAppName,
            sourceBundleIdentifier: draft.sourceBundleIdentifier ?? draft.contextBundle.sourceBundleIdentifier,
            status: draft.status,
            errorMessage: draft.errorMessage,
            mode: TranscriptRunReport.ModeSnapshot(
                id: draft.mode.id,
                name: draft.mode.name,
                shortLabel: draft.mode.shortLabel,
                templateID: draft.mode.templateID,
                contextPolicy: draft.mode.contextPolicy
            ),
            transcription: TranscriptRunReport.TranscriptionSnapshot(
                provider: draft.provider.displayName,
                model: draft.transcriptionModel.displayName,
                language: draft.language,
                audioDuration: draft.audioDuration
            ),
            codex: codex,
            selectedText: draft.contextBundle.selectedText.isEmpty ? nil : draft.contextBundle.selectedText.text,
            visualContextSummary: draft.contextBundle.visualContextSummary.isEmpty ? nil : draft.contextBundle.visualContextSummary,
            attachments: attachments,
            renderedPrompt: draft.renderedPrompt,
            rawTranscript: draft.rawTranscript,
            finalTranscript: draft.finalTranscript,
            copiedToClipboard: draft.copiedToClipboard,
            autoPasteRequested: draft.autoPasteRequested
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: reportURL(for: draft.id), options: .atomic)
        return report
    }

    func recentReports(limit: Int = 50) -> [TranscriptRunReport] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories
            .compactMap { directory in
                try? loadReport(from: directory.appendingPathComponent("report.json"))
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    func delete(_ report: TranscriptRunReport) throws {
        let directory = reportsDirectory.appendingPathComponent(report.id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func attachmentReport(
        for attachment: ContextAttachment,
        visualInput: CodexVisualInputSelection,
        attachmentsDirectory: URL
    ) throws -> TranscriptRunAttachmentReport {
        let sourceURL = attachment.fileURL
        let storedURL = try copyAttachment(sourceURL, id: attachment.id, kind: attachment.kind, to: attachmentsDirectory)
        let thumbnailURL: URL?
        if let sourceThumbnailURL = attachment.thumbnailURL {
            thumbnailURL = try copyAttachment(
                sourceThumbnailURL,
                id: attachment.id,
                kind: attachment.kind,
                suffix: "thumb",
                to: attachmentsDirectory
            )
        } else {
            thumbnailURL = nil
        }

        return TranscriptRunAttachmentReport(
            id: attachment.id,
            kind: attachment.kind,
            originalPath: sourceURL.path,
            storedPath: storedURL?.path,
            thumbnailPath: thumbnailURL?.path,
            duration: attachment.duration,
            sourceDisplayID: attachment.sourceDisplayID,
            sourceAppName: attachment.sourceAppName,
            annotationNumber: attachment.annotationNumber,
            annotationComment: attachment.annotationComment,
            annotationRect: attachment.annotationRect,
            includedInCodexInput: visualInput.includes(attachment),
            createdAt: attachment.createdAt
        )
    }

    private func copyAttachment(
        _ sourceURL: URL,
        id: UUID,
        kind: ContextAttachmentKind,
        suffix: String? = nil,
        to directory: URL
    ) throws -> URL? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        let extensionName = sourceURL.pathExtension.isEmpty ? defaultPathExtension(for: kind) : sourceURL.pathExtension
        let suffixPart = suffix.map { "-\($0)" } ?? ""
        let destinationURL = directory
            .appendingPathComponent("\(kind.rawValue)-\(id.uuidString)\(suffixPart)")
            .appendingPathExtension(extensionName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func defaultPathExtension(for kind: ContextAttachmentKind) -> String {
        switch kind {
        case .screenshot, .annotation, .visualFrame:
            return "png"
        case .screenClip:
            return "mp4"
        }
    }

    private func loadReport(from url: URL) throws -> TranscriptRunReport {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptRunReport.self, from: data)
    }

    private func reportURL(for id: UUID) -> URL {
        reportsDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("report.json")
    }

    private static func defaultReportsDirectory() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return supportDirectory
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
    }
}
