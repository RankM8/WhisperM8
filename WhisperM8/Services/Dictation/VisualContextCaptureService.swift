import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum VisualContextCaptureError: LocalizedError, Equatable {
    case disabled
    case missingPermission
    case noDisplay
    case alreadyRecording
    case noActiveRecording
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Visual context capture is disabled."
        case .missingPermission:
            return "Screen Recording permission is required for visual context."
        case .noDisplay:
            return "No active display was available for visual context capture."
        case .alreadyRecording:
            return "A screen clip is already recording."
        case .noActiveRecording:
            return "No screen clip is currently recording."
        case .captureFailed(let message):
            return message
        }
    }
}

@MainActor
final class VisualContextCaptureService {
    private let maxVisualFrames = 5
    private var activeClipSession: ScreenClipCapturing?
    private var activeClipStartDate: Date?

    /// Injizierbarer Runner fuer die native Bereichsauswahl. Default ruft das
    /// System-Binary `/usr/sbin/screencapture -i` auf. Tests ersetzen den Runner,
    /// weil das interaktive Subprocess selbst nicht unit-testbar ist (analog zur
    /// DI-via-Closure-Konvention im Repo).
    var interactiveScreenshotRunner: @Sendable (_ outputURL: URL) async -> Bool
        = { await VisualContextCaptureService.runInteractiveScreenCapture($0) }

    var isRecordingClip: Bool {
        activeClipSession != nil
    }

    /// Startet die native macOS-Bereichsauswahl (Fadenkreuz) und liefert ein
    /// Screenshot-Attachment. Gibt `nil` zurueck, wenn der User die Auswahl
    /// abbricht (ESC) — im Gegensatz zu `captureClipboardScreenshot` nimmt das
    /// hier einen NEUEN Screenshot auf, statt das Clipboard zu lesen.
    func captureInteractiveScreenshot(sourceApp: NSRunningApplication?) async throws -> ContextAttachment? {
        guard AppPreferences.shared.isVisualContextCaptureEnabled else {
            throw VisualContextCaptureError.disabled
        }

        let fileURL = try contextDirectory()
            .appendingPathComponent("InteractiveScreenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")

        let didCapture = await interactiveScreenshotRunner(fileURL)

        // Abbruch (ESC) oder leere Auswahl: screencapture schreibt keine bzw. eine
        // leere Datei. Aufraeumen und still zurueck — kein Fehler-Toast.
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        guard didCapture, FileManager.default.fileExists(atPath: fileURL.path), (size ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        return ContextAttachment(
            kind: .screenshot,
            fileURL: fileURL,
            thumbnailURL: fileURL,
            sourceAppName: sourceApp?.localizedName ?? "Screenshot"
        )
    }

    /// Default-Runner: ruft `/usr/sbin/screencapture -i <file>` auf und wartet auf
    /// Beendigung. `-i` = interaktive Auswahl (Region aufziehen, Leertaste =
    /// Fenstermodus, ESC = Abbruch). Schreibt direkt in die Datei statt ins
    /// Clipboard, damit die Zwischenablage des Users unangetastet bleibt und der
    /// 500-ms-Clipboard-Monitor nichts doppelt importiert. Kein LoginShellEnvironment
    /// noetig — absoluter System-Pfad, kein PATH-Lookup.
    nonisolated private static func runInteractiveScreenCapture(_ outputURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", outputURL.path]
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                Logger.permission.warning("screencapture launch failed: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }

    func captureClipboardScreenshot(
        from pasteboard: NSPasteboard,
        changeCount: Int,
        sourceApp: NSRunningApplication?
    ) throws -> ContextAttachment? {
        guard AppPreferences.shared.isVisualContextCaptureEnabled else {
            throw VisualContextCaptureError.disabled
        }

        guard let image = NSImage(pasteboard: pasteboard) else {
            return nil
        }

        let fileURL = try contextDirectory()
            .appendingPathComponent("ClipboardScreenshot-\(changeCount)-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try writePNG(image, to: fileURL)

        return ContextAttachment(
            kind: .screenshot,
            fileURL: fileURL,
            thumbnailURL: fileURL,
            sourceAppName: sourceApp?.localizedName ?? "Clipboard"
        )
    }

    func startScreenClip(sourceApp: NSRunningApplication?) async throws {
        guard AppPreferences.shared.isVisualContextCaptureEnabled else {
            throw VisualContextCaptureError.disabled
        }
        guard PermissionService.hasScreenRecordingPermission else {
            throw VisualContextCaptureError.missingPermission
        }
        guard activeClipSession == nil else {
            throw VisualContextCaptureError.alreadyRecording
        }

        let target = try await makeCaptureTarget()
        let fileURL = try contextDirectory()
            .appendingPathComponent("ScreenClip-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        let session = try await ManualScreenClipSession.start(
            target: target,
            outputURL: fileURL,
            sourceAppName: sourceApp?.localizedName
        )
        activeClipSession = session
        activeClipStartDate = Date()
    }

    func stopScreenClip() async throws -> (clip: ContextAttachment, visualFrames: [ContextAttachment]) {
        guard let session = activeClipSession else {
            throw VisualContextCaptureError.noActiveRecording
        }

        activeClipSession = nil
        let startedAt = activeClipStartDate
        activeClipStartDate = nil

        let clip = try await session.stop(startedAt: startedAt)
        let frames = try await extractVisualFrames(from: clip)
        return (clip, frames)
    }

    func cancelActiveClip() async {
        guard let session = activeClipSession else {
            activeClipSession = nil
            activeClipStartDate = nil
            return
        }

        activeClipSession = nil
        activeClipStartDate = nil
        try? await session.cancel()
    }

    func cleanup(_ bundle: TranscriptContextBundle) {
        guard AppPreferences.shared.deleteContextFilesAfterProcessing else { return }

        for attachment in bundle.allAttachments {
            try? FileManager.default.removeItem(at: attachment.fileURL)
            if let thumbnailURL = attachment.thumbnailURL, thumbnailURL != attachment.fileURL {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
        }
    }

    private func extractVisualFrames(from clip: ContextAttachment) async throws -> [ContextAttachment] {
        let asset = AVURLAsset(url: clip.fileURL)
        let durationSeconds = try await asset.load(.duration).seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1000)

        let frameCount = min(maxVisualFrames, max(1, Int(ceil(durationSeconds / 4.0))))
        let step = durationSeconds / Double(frameCount + 1)

        var frames: [ContextAttachment] = []
        for index in 1...frameCount {
            let time = CMTime(seconds: step * Double(index), preferredTimescale: 600)
            do {
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                let fileURL = try contextDirectory()
                    .appendingPathComponent("VisualSummary-\(clip.id.uuidString)-\(index)")
                    .appendingPathExtension("png")
                try writePNG(image, to: fileURL)
                frames.append(
                    ContextAttachment(
                        kind: .visualFrame,
                        fileURL: fileURL,
                        thumbnailURL: fileURL,
                        sourceDisplayID: clip.sourceDisplayID,
                        sourceAppName: clip.sourceAppName
                    )
                )
            } catch {
                Logger.debug("Visual frame extraction failed: \(error.localizedDescription)")
            }
        }

        return frames
    }

    private func makeCaptureTarget() async throws -> ScreenCaptureTarget {
        let content = try await SCShareableContent.current
        guard let display = activeDisplay(from: content) ?? content.displays.first else {
            throw VisualContextCaptureError.noDisplay
        }

        let excludedApplications = content.applications.filter { application in
            application.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        return ScreenCaptureTarget(display: display, filter: filter)
    }

    private func activeDisplay(from content: SCShareableContent) -> SCDisplay? {
        guard let screen = OverlayPositionStore.activeScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(number.uint32Value)
        return content.displays.first { $0.displayID == displayID }
    }

    private func contextDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Context", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw VisualContextCaptureError.captureFailed("Failed to encode screenshot image.")
        }
        try data.write(to: url, options: .atomic)
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisualContextCaptureError.captureFailed("Failed to read clipboard screenshot image.")
        }
        try writePNG(cgImage, to: url)
    }
}
