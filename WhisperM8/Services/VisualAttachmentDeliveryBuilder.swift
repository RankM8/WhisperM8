import Foundation

struct VisualAttachmentDeliveryBuilder {
    private let fileManager: FileManager
    private let rootDirectory: URL

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Delivery", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
    }

    func build(
        contextBundle: TranscriptContextBundle,
        mode: OutputMode,
        runID: UUID = UUID(),
        maxAttachments: Int = AppPreferences.shared.maxScreenshotsPerRecording
    ) throws -> [PasteAttachment] {
        guard mode.pasteVisualAttachments else { return [] }

        let imageAttachments = Array(contextBundle.visualAttachments.prefix(maxAttachments))
        guard !imageAttachments.isEmpty else { return [] }

        let runDirectory = rootDirectory.appendingPathComponent(runID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)

        return try imageAttachments.enumerated().compactMap { index, attachment in
            guard fileManager.fileExists(atPath: attachment.fileURL.path) else {
                Logger.paste.warning("Visual attachment missing before delivery: \(attachment.fileURL.path, privacy: .public)")
                return nil
            }

            let label = "Screenshot \(index + 1)"
            let destinationURL = runDirectory.appendingPathComponent("\(label).png")
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: attachment.fileURL, to: destinationURL)

            return PasteAttachment(
                id: attachment.id,
                label: label,
                fileURL: destinationURL,
                kind: attachment.kind
            )
        }
    }
}
