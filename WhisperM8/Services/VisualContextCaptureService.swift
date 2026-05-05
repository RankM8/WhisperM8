import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers

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

    var isRecordingClip: Bool {
        activeClipSession != nil
    }

    func captureScreenshot(sourceApp: NSRunningApplication?) async throws -> ContextAttachment {
        guard AppPreferences.shared.isVisualContextCaptureEnabled else {
            throw VisualContextCaptureError.disabled
        }
        guard PermissionService.hasScreenRecordingPermission else {
            throw VisualContextCaptureError.missingPermission
        }

        let target = try await makeCaptureTarget()
        let configuration = streamConfiguration(for: target.display, frameRate: 1)

        let image: CGImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: VisualContextCaptureError.captureFailed("No screenshot image was returned."))
                }
            }
        }

        let fileURL = try contextDirectory()
            .appendingPathComponent("Screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try writePNG(image, to: fileURL)

        return ContextAttachment(
            kind: .screenshot,
            fileURL: fileURL,
            thumbnailURL: fileURL,
            sourceDisplayID: target.display.displayID,
            sourceAppName: sourceApp?.localizedName
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

    private func streamConfiguration(for display: SCDisplay, frameRate: Int32) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, CGDisplayPixelsWide(display.displayID))
        configuration.height = max(1, CGDisplayPixelsHigh(display.displayID))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }
        return configuration
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
}

struct ScreenCaptureTarget {
    let display: SCDisplay
    let filter: SCContentFilter
}

private protocol ScreenClipCapturing: AnyObject {
    func stop(startedAt: Date?) async throws -> ContextAttachment
    func cancel() async throws
}

private final class ManualScreenClipSession: NSObject, SCStreamOutput, SCStreamDelegate, ScreenClipCapturing, @unchecked Sendable {
    private let stream: SCStream
    private let outputURL: URL
    private let displayID: CGDirectDisplayID
    private let sourceAppName: String?
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let sampleQueue = DispatchQueue(label: "com.whisperm8.visual-context.screen-clip")
    private var firstSampleTime: CMTime?
    private var didAppendFrame = false
    private var streamError: Error?

    private init(
        stream: SCStream,
        outputURL: URL,
        displayID: CGDirectDisplayID,
        sourceAppName: String?,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) {
        self.stream = stream
        self.outputURL = outputURL
        self.displayID = displayID
        self.sourceAppName = sourceAppName
        self.writer = writer
        self.writerInput = writerInput
        self.adaptor = adaptor
        super.init()
    }

    @MainActor
    static func start(target: ScreenCaptureTarget, outputURL: URL, sourceAppName: String?) async throws -> ManualScreenClipSession {
        let width = max(1, CGDisplayPixelsWide(target.display.displayID))
        let height = max(1, CGDisplayPixelsHigh(target.display.displayID))

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw VisualContextCaptureError.captureFailed("Could not configure screen clip writer.")
        }
        writer.add(input)

        let stream = SCStream(filter: target.filter, configuration: configuration, delegate: nil)
        let session = ManualScreenClipSession(
            stream: stream,
            outputURL: outputURL,
            displayID: target.display.displayID,
            sourceAppName: sourceAppName,
            writer: writer,
            writerInput: input,
            adaptor: adaptor
        )

        try stream.addStreamOutput(session, type: .screen, sampleHandlerQueue: session.sampleQueue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        return session
    }

    func stop(startedAt: Date?) async throws -> ContextAttachment {
        try await stopStream()

        let appendedFrame = sampleQueue.sync { didAppendFrame }
        guard appendedFrame else {
            try? FileManager.default.removeItem(at: outputURL)
            throw VisualContextCaptureError.captureFailed("No screen frames were captured.")
        }

        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if let streamError {
            throw VisualContextCaptureError.captureFailed(streamError.localizedDescription)
        }

        guard writer.status == .completed else {
            throw VisualContextCaptureError.captureFailed(writer.error?.localizedDescription ?? "Screen clip writer did not finish.")
        }

        let duration = startedAt.map { Date().timeIntervalSince($0) }
        return ContextAttachment(
            kind: .screenClip,
            fileURL: outputURL,
            duration: duration,
            sourceDisplayID: displayID,
            sourceAppName: sourceAppName
        )
    }

    func cancel() async throws {
        try? await stopStream()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func stopStream() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error {
                    continuation.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstSampleTime == nil {
            firstSampleTime = time
            guard writer.startWriting() else {
                streamError = writer.error
                return
            }
            writer.startSession(atSourceTime: time)
        }

        guard writer.status == .writing, writerInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            didAppendFrame = true
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error
    }
}

@available(macOS 15.0, *)
private final class ScreenClipSession: NSObject, SCRecordingOutputDelegate, ScreenClipCapturing, @unchecked Sendable {
    private let stream: SCStream
    private var recordingOutput: SCRecordingOutput!
    private let outputURL: URL
    private let displayID: CGDirectDisplayID
    private let sourceAppName: String?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    private init(
        stream: SCStream,
        outputURL: URL,
        displayID: CGDirectDisplayID,
        sourceAppName: String?
    ) {
        self.stream = stream
        self.outputURL = outputURL
        self.displayID = displayID
        self.sourceAppName = sourceAppName
        super.init()
    }

    @MainActor
    static func start(target: ScreenCaptureTarget, outputURL: URL, sourceAppName: String?) async throws -> ScreenClipSession {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, CGDisplayPixelsWide(target.display.displayID))
        configuration.height = max(1, CGDisplayPixelsHigh(target.display.displayID))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = false

        let stream = SCStream(filter: target.filter, configuration: configuration, delegate: nil)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.videoCodecType = .h264
        recordingConfiguration.outputFileType = .mp4

        let placeholder = ScreenClipSession(
            stream: stream,
            outputURL: outputURL,
            displayID: target.display.displayID,
            sourceAppName: sourceAppName
        )
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: placeholder)
        placeholder.recordingOutput = recordingOutput

        try stream.addRecordingOutput(recordingOutput)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            placeholder.startContinuation = continuation
            stream.startCapture { error in
                if let error {
                    placeholder.startContinuation = nil
                    continuation.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
                }
            }
        }

        return placeholder
    }

    func stop(startedAt: Date?) async throws -> ContextAttachment {
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            do {
                try stream.removeRecordingOutput(recordingOutput)
            } catch {
                finishContinuation = nil
                continuation.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
            }
        }

        try await stopStream()

        let duration = startedAt.map { Date().timeIntervalSince($0) }
        return ContextAttachment(
            kind: .screenClip,
            fileURL: outputURL,
            duration: duration,
            sourceDisplayID: displayID,
            sourceAppName: sourceAppName
        )
    }

    func cancel() async throws {
        try await stopStream()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func stopStream() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error {
                    continuation.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        startContinuation?.resume()
        startContinuation = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        startContinuation?.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
        startContinuation = nil
        finishContinuation?.resume(throwing: VisualContextCaptureError.captureFailed(error.localizedDescription))
        finishContinuation = nil
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}
