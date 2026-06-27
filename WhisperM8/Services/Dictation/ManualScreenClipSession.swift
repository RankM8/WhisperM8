import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

struct ScreenCaptureTarget {
    let display: SCDisplay
    let filter: SCContentFilter
}

protocol ScreenClipCapturing: AnyObject {
    func stop(startedAt: Date?) async throws -> ContextAttachment
    func cancel() async throws
}

final class ManualScreenClipSession: NSObject, SCStreamOutput, SCStreamDelegate, ScreenClipCapturing, @unchecked Sendable {
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
