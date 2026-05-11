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
    var replyIntent: ReplyIntentKind?
    var visualManifest: VisualManifest?
    var rawTranscript: String?
    var finalTranscript: String?
    var copiedToClipboard: Bool
    var autoPasteRequested: Bool
    var autoPasteTextRequested = false
    var autoPasteAttachmentsRequested = false
    var pastedAttachmentCount = 0
    var pasteErrors: [String] = []
    var deliveryAttachmentLabels: [String] = []
    var agentProvider: AgentProvider?
    var agentSessionID: String?
    var agentProjectPath: String?
}

struct TranscriptRunReportStore {
    struct CleanupPolicy {
        var maxAge: TimeInterval?
        var maxCount: Int?
        var maxBytes: Int64?

        init(maxAge: TimeInterval? = nil, maxCount: Int? = nil, maxBytes: Int64? = nil) {
            self.maxAge = maxAge
            self.maxCount = maxCount
            self.maxBytes = maxBytes
        }
    }

    struct CleanupResult: Equatable {
        var removedCount: Int
        var removedBytes: Int64
    }

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
        if draft.mode.usesPostProcessing && draft.mode.id != OutputMode.chatID {
            let outputURL = runDirectory.appendingPathComponent("codex-output.txt")
            codex = TranscriptRunReport.CodexSnapshot(
                model: AppPreferences.shared.codexPostProcessingModelRaw,
                reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                visualInputMode: visualInput.mode.rawValue,
                commandPreview: CodexInvocation.arguments(
                    promptImageURLs: imageInputPaths.map(URL.init(fileURLWithPath:)),
                    outputURL: outputURL,
                    model: AppPreferences.shared.codexPostProcessingModelRaw,
                    reasoningEffort: AppPreferences.shared.codexReasoningEffortRaw,
                    isEphemeral: draft.mode.id != OutputMode.taskID,
                    projectPath: draft.mode.id == OutputMode.taskID ? AppPreferences.shared.agentDefaultProjectPath : nil
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
            replyIntent: draft.replyIntent,
            visualManifest: draft.visualManifest,
            attachments: attachments,
            renderedPrompt: draft.renderedPrompt,
            rawTranscript: draft.rawTranscript,
            finalTranscript: draft.finalTranscript,
            copiedToClipboard: draft.copiedToClipboard,
            autoPasteRequested: draft.autoPasteRequested,
            autoPasteTextRequested: draft.autoPasteTextRequested,
            autoPasteAttachmentsRequested: draft.autoPasteAttachmentsRequested,
            pastedAttachmentCount: draft.pastedAttachmentCount,
            pasteErrors: draft.pasteErrors,
            deliveryAttachmentLabels: draft.deliveryAttachmentLabels,
            agentProvider: draft.agentProvider,
            agentSessionID: draft.agentSessionID,
            agentProjectPath: draft.agentProjectPath
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

    @discardableResult
    func cleanup(policy: CleanupPolicy, now: Date = Date()) throws -> CleanupResult {
        let directories = reportDirectories()
        var candidates: [(url: URL, createdAt: Date, size: Int64)] = directories.map { directory in
            let report = try? loadReport(from: directory.appendingPathComponent("report.json"))
            return (
                url: directory,
                createdAt: report?.createdAt ?? directoryModificationDate(directory),
                size: directorySize(directory)
            )
        }
        candidates.sort { $0.createdAt > $1.createdAt }

        var removalPaths = Set<URL>()
        if let maxAge = policy.maxAge {
            for candidate in candidates where now.timeIntervalSince(candidate.createdAt) > maxAge {
                removalPaths.insert(candidate.url)
            }
        }

        if let maxCount = policy.maxCount, maxCount >= 0, candidates.count > maxCount {
            for candidate in candidates.dropFirst(maxCount) {
                removalPaths.insert(candidate.url)
            }
        }

        if let maxBytes = policy.maxBytes, maxBytes >= 0 {
            var keptBytes = candidates
                .filter { !removalPaths.contains($0.url) }
                .reduce(Int64(0)) { $0 + $1.size }
            for candidate in candidates.reversed() where keptBytes > maxBytes && !removalPaths.contains(candidate.url) {
                removalPaths.insert(candidate.url)
                keptBytes -= candidate.size
            }
        }

        var removedCount = 0
        var removedBytes: Int64 = 0
        for candidate in candidates where removalPaths.contains(candidate.url) {
            if FileManager.default.fileExists(atPath: candidate.url.path) {
                try FileManager.default.removeItem(at: candidate.url)
                removedCount += 1
                removedBytes += candidate.size
            }
        }

        return CleanupResult(removedCount: removedCount, removedBytes: removedBytes)
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

    private func reportDirectories() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
    }

    private func directoryModificationDate(_ directory: URL) -> Date {
        (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
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
