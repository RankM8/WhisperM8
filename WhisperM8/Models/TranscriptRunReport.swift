import Foundation

enum TranscriptRunStatus: String, Codable, Equatable {
    case succeeded
    case rawFallback
    case failed

    var displayText: String {
        switch self {
        case .succeeded:
            return "Succeeded"
        case .rawFallback:
            return "Raw Fallback"
        case .failed:
            return "Failed"
        }
    }
}

struct TranscriptRunAttachmentReport: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: ContextAttachmentKind
    var originalPath: String
    var storedPath: String?
    var thumbnailPath: String?
    var duration: TimeInterval?
    var sourceDisplayID: UInt32?
    var sourceAppName: String?
    var includedInCodexInput: Bool
    var createdAt: Date
}

struct TranscriptRunReport: Identifiable, Codable, Equatable {
    struct ModeSnapshot: Codable, Equatable {
        var id: String
        var name: String
        var shortLabel: String
        var templateID: String?
        var contextPolicy: ContextCapturePolicy
    }

    struct TranscriptionSnapshot: Codable, Equatable {
        var provider: String
        var model: String
        var language: String
        var audioDuration: TimeInterval
    }

    struct CodexSnapshot: Codable, Equatable {
        var model: String
        var reasoningEffort: String
        var visualInputMode: String
        var commandPreview: [String]
        var imageInputPaths: [String]
        var videoInputPaths: [String]
        var usesFrameFallbackForVideo: Bool

        private enum CodingKeys: String, CodingKey {
            case model
            case reasoningEffort
            case visualInputMode
            case commandPreview
            case imageInputPaths
            case videoInputPaths
            case usesFrameFallbackForVideo
        }

        init(
            model: String,
            reasoningEffort: String,
            visualInputMode: String,
            commandPreview: [String],
            imageInputPaths: [String],
            videoInputPaths: [String],
            usesFrameFallbackForVideo: Bool
        ) {
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.visualInputMode = visualInputMode
            self.commandPreview = commandPreview
            self.imageInputPaths = imageInputPaths
            self.videoInputPaths = videoInputPaths
            self.usesFrameFallbackForVideo = usesFrameFallbackForVideo
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            reasoningEffort = try container.decode(String.self, forKey: .reasoningEffort)
            visualInputMode = try container.decodeIfPresent(String.self, forKey: .visualInputMode)
                ?? CodexVisualInputMode.defaultMode.rawValue
            commandPreview = try container.decode([String].self, forKey: .commandPreview)
            imageInputPaths = try container.decodeIfPresent([String].self, forKey: .imageInputPaths) ?? []
            videoInputPaths = try container.decodeIfPresent([String].self, forKey: .videoInputPaths) ?? []
            usesFrameFallbackForVideo = try container.decodeIfPresent(Bool.self, forKey: .usesFrameFallbackForVideo) ?? false
        }
    }

    var id: UUID
    var createdAt: Date
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var status: TranscriptRunStatus
    var errorMessage: String?
    var mode: ModeSnapshot
    var transcription: TranscriptionSnapshot
    var codex: CodexSnapshot?
    var selectedText: String?
    var visualContextSummary: String?
    var attachments: [TranscriptRunAttachmentReport]
    var renderedPrompt: String?
    var rawTranscript: String?
    var finalTranscript: String?
    var copiedToClipboard: Bool
    var autoPasteRequested: Bool
}

extension TranscriptRunReport {
    var title: String {
        let modeName = mode.name
        let appName = sourceAppName ?? "Unknown app"
        return "\(modeName) · \(appName)"
    }

    var shortSummary: String {
        if let finalTranscript, !finalTranscript.isEmpty {
            return finalTranscript
        }
        if let rawTranscript, !rawTranscript.isEmpty {
            return rawTranscript
        }
        return errorMessage ?? "No transcript"
    }
}
