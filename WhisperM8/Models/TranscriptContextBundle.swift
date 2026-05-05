import AppKit
import Foundation

enum ContextAttachmentKind: String, Codable, Equatable, CaseIterable {
    case screenshot
    case screenClip
    case visualFrame
}

struct ContextAttachment: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: ContextAttachmentKind
    var fileURL: URL
    var thumbnailURL: URL?
    var duration: TimeInterval?
    var sourceDisplayID: UInt32?
    var sourceAppName: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: ContextAttachmentKind,
        fileURL: URL,
        thumbnailURL: URL? = nil,
        duration: TimeInterval? = nil,
        sourceDisplayID: UInt32? = nil,
        sourceAppName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.sourceDisplayID = sourceDisplayID
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
    }
}

struct TranscriptContextBundle: Codable, Equatable {
    var selectedText: SelectedContext
    var screenshots: [ContextAttachment]
    var screenClips: [ContextAttachment]
    var visualFrames: [ContextAttachment]
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var createdAt: Date

    init(
        selectedText: SelectedContext = .empty,
        screenshots: [ContextAttachment] = [],
        screenClips: [ContextAttachment] = [],
        visualFrames: [ContextAttachment] = [],
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.selectedText = selectedText
        self.screenshots = screenshots
        self.screenClips = screenClips
        self.visualFrames = visualFrames
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.createdAt = createdAt
    }

    var isEmpty: Bool {
        selectedText.isEmpty && screenshots.isEmpty && screenClips.isEmpty && visualFrames.isEmpty
    }

    var visualAttachments: [ContextAttachment] {
        screenshots + visualFrames
    }

    var screenClipPaths: [String] {
        screenClips.map(\.fileURL.path)
    }

    var allAttachments: [ContextAttachment] {
        screenshots + screenClips + visualFrames
    }

    var attachmentCount: Int {
        allAttachments.count
    }

    var displaySummary: String {
        var parts: [String] = []

        if !selectedText.isEmpty {
            parts.append("Text")
        }

        if !screenshots.isEmpty {
            parts.append(screenshots.count == 1 ? "Shot" : "\(screenshots.count) Shots")
        }

        if !screenClips.isEmpty {
            parts.append(screenClips.count == 1 ? "Clip" : "\(screenClips.count) Clips")
        }

        if parts.isEmpty {
            return "No Context"
        }

        return parts.joined(separator: " + ")
    }

    var compactSummary: String {
        if isEmpty { return "No Ctx" }
        if !screenClips.isEmpty { return "Clip" }
        if !screenshots.isEmpty { return "Shot" }
        return "Ctx"
    }

    var visualContextSummary: String {
        var lines: [String] = []

        if !screenshots.isEmpty {
            lines.append("\(screenshots.count) screenshot(s) captured from the active screen.")
        }

        if !screenClips.isEmpty {
            let durations = screenClips.compactMap(\.duration)
            if let totalDuration = durations.isEmpty ? nil : durations.reduce(0, +) {
                lines.append("\(screenClips.count) screen clip(s), \(String(format: "%.1f", totalDuration)) seconds total.")
            } else {
                lines.append("\(screenClips.count) screen clip(s) captured.")
            }
        }

        if !visualFrames.isEmpty {
            lines.append("\(visualFrames.count) visual summary image(s) extracted from screen clip(s).")
        }

        if !screenClips.isEmpty {
            lines.append("Full screen clip file(s), stored locally for review and future direct video input:")
            lines.append(contentsOf: screenClipPaths.map { "- \($0)" })
            lines.append("Current Codex CLI non-interactive input uses image frames for visual understanding; use these video paths only as local reference if available.")
        }

        return lines.joined(separator: "\n")
    }

    var screenClipPathSummary: String {
        screenClipPaths.joined(separator: "\n")
    }

    static let empty = TranscriptContextBundle()

    static func from(selectedContext: SelectedContext, sourceApp: NSRunningApplication?) -> TranscriptContextBundle {
        TranscriptContextBundle(
            selectedText: selectedContext,
            sourceAppName: sourceApp?.localizedName ?? selectedContext.sourceAppName,
            sourceBundleIdentifier: sourceApp?.bundleIdentifier ?? selectedContext.sourceBundleIdentifier
        )
    }
}
