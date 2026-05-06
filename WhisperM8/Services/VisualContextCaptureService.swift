import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import SwiftUI
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

        let captured = try await captureDisplayImage()
        let fileURL = try contextDirectory()
            .appendingPathComponent("Screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try writePNG(captured.image, to: fileURL)

        return ContextAttachment(
            kind: .screenshot,
            fileURL: fileURL,
            thumbnailURL: fileURL,
            sourceDisplayID: captured.displayID,
            sourceAppName: sourceApp?.localizedName
        )
    }

    func captureAnnotation(sourceApp: NSRunningApplication?, number: Int) async throws -> ContextAttachment {
        guard AppPreferences.shared.isVisualContextCaptureEnabled else {
            throw VisualContextCaptureError.disabled
        }
        guard PermissionService.hasScreenRecordingPermission else {
            throw VisualContextCaptureError.missingPermission
        }

        let captured = try await captureDisplayImage()
        let selection = try await AnnotationSelectionWindow.present(
            image: captured.image,
            displayID: captured.displayID,
            number: number
        )
        let annotatedImage = try makeAnnotatedImage(baseImage: captured.image, selection: selection)

        let fileURL = try contextDirectory()
            .appendingPathComponent("Annotation-\(number)-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try writePNG(annotatedImage, to: fileURL)

        return ContextAttachment(
            kind: .annotation,
            fileURL: fileURL,
            thumbnailURL: fileURL,
            sourceDisplayID: captured.displayID,
            sourceAppName: sourceApp?.localizedName,
            annotationNumber: number,
            annotationComment: selection.comment,
            annotationRect: selection.pixelRect
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

    private func captureDisplayImage() async throws -> (image: CGImage, displayID: CGDirectDisplayID) {
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

        return (image, target.display.displayID)
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

    private func makeAnnotatedImage(baseImage: CGImage, selection: AnnotationSelection) throws -> CGImage {
        let width = baseImage.width
        let height = baseImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VisualContextCaptureError.captureFailed("Failed to create annotated screenshot.")
        }

        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(baseImage, in: imageRect)

        let rect = selection.pixelRect.standardized
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.14).cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(max(4, CGFloat(width) / 500))
        context.stroke(rect)

        drawAnnotationBadge(number: selection.number, at: rect.origin, in: context, imageHeight: CGFloat(height))

        if !selection.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drawAnnotationComment(selection.comment, near: rect, in: context, imageSize: imageRect.size)
        }

        guard let image = context.makeImage() else {
            throw VisualContextCaptureError.captureFailed("Failed to render annotated screenshot.")
        }
        return image
    }

    private func drawAnnotationBadge(number: Int, at origin: CGPoint, in context: CGContext, imageHeight: CGFloat) {
        let diameter: CGFloat = 46
        let point = CGPoint(
            x: max(12, origin.x - diameter * 0.45),
            y: min(imageHeight - diameter - 12, max(12, origin.y - diameter * 0.45))
        )
        let rect = CGRect(origin: point, size: CGSize(width: diameter, height: diameter))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(4)
        context.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))

        let text = "\(number)" as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(in: rect.insetBy(dx: 0, dy: 8), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawAnnotationComment(_ comment: String, near rect: CGRect, in context: CGContext, imageSize: CGSize) {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxWidth: CGFloat = min(520, imageSize.width - 40)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: trimmed, attributes: attributes)
        let measured = attributed.boundingRect(
            with: CGSize(width: maxWidth - 32, height: 300),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let boxSize = CGSize(width: min(maxWidth, measured.width + 32), height: measured.height + 24)
        let boxX = min(max(20, rect.midX - boxSize.width / 2), imageSize.width - boxSize.width - 20)
        let preferredY = rect.minY - boxSize.height - 18
        let boxY = preferredY > 20 ? preferredY : min(imageSize.height - boxSize.height - 20, rect.maxY + 18)
        let box = CGRect(x: boxX, y: boxY, width: boxSize.width, height: boxSize.height)

        context.setFillColor(NSColor.black.withAlphaComponent(0.76).cgColor)
        context.fill(box)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(
            with: box.insetBy(dx: 16, dy: 12),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct ScreenCaptureTarget {
    let display: SCDisplay
    let filter: SCContentFilter
}

struct AnnotationSelection {
    var number: Int
    var comment: String
    var pixelRect: CGRect
}

@MainActor
private final class AnnotationSelectionWindow: NSObject, NSWindowDelegate {
    private static var activeWindow: AnnotationSelectionWindow?

    private var window: NSWindow?
    private var continuation: CheckedContinuation<AnnotationSelection, Error>?
    private let image: CGImage
    private let displayID: CGDirectDisplayID
    private let number: Int

    init(image: CGImage, displayID: CGDirectDisplayID, number: Int) {
        self.image = image
        self.displayID = displayID
        self.number = number
        super.init()
    }

    static func present(image: CGImage, displayID: CGDirectDisplayID, number: Int) async throws -> AnnotationSelection {
        try await withCheckedThrowingContinuation { continuation in
            let selector = AnnotationSelectionWindow(image: image, displayID: displayID, number: number)
            selector.continuation = continuation
            activeWindow = selector
            selector.show()
        }
    }

    private func show() {
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        } ?? NSScreen.main

        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero
        let model = AnnotationSelectionModel(
            number: number,
            imageSize: CGSize(width: image.width, height: image.height),
            onCancel: { [weak self] in
                self?.cancel()
            },
            onComplete: { [weak self] selection in
                self?.complete(selection)
            }
        )
        let view = AnnotationSelectionView(image: NSImage(cgImage: image, size: frame.size), model: model)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        if continuation != nil {
            cancel()
        }
    }

    private func complete(_ selection: AnnotationSelection) {
        continuation?.resume(returning: selection)
        continuation = nil
        close()
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        close()
    }

    private func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        Self.activeWindow = nil
    }
}

@MainActor
private final class AnnotationSelectionModel: ObservableObject {
    let number: Int
    let imageSize: CGSize
    let onCancel: () -> Void
    let onComplete: (AnnotationSelection) -> Void

    @Published var selectionRect: CGRect?
    @Published var dragStart: CGPoint?
    @Published var comment = ""
    @Published var viewSize = CGSize(width: 1, height: 1)

    init(
        number: Int,
        imageSize: CGSize,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (AnnotationSelection) -> Void
    ) {
        self.number = number
        self.imageSize = imageSize
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    func updateDrag(to point: CGPoint) {
        if dragStart == nil {
            dragStart = point
        }
        guard let dragStart else { return }
        selectionRect = CGRect(
            x: min(dragStart.x, point.x),
            y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x),
            height: abs(point.y - dragStart.y)
        )
    }

    func finishDrag() {
        dragStart = nil
    }

    func save() {
        guard let rect = selectionRect?.standardized, rect.width >= 8, rect.height >= 8 else { return }
        onComplete(
            AnnotationSelection(
                number: number,
                comment: comment,
                pixelRect: pixelRect(for: rect)
            )
        )
    }

    private func pixelRect(for rect: CGRect) -> CGRect {
        let scaleX = imageSize.width / max(1, viewSize.width)
        let scaleY = imageSize.height / max(1, viewSize.height)
        return CGRect(
            x: rect.minX * scaleX,
            y: (viewSize.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}

private struct AnnotationSelectionView: View {
    let image: NSImage
    @ObservedObject var model: AnnotationSelectionModel
    @FocusState private var commentFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            content(in: proxy.size)
            .onAppear {
                model.viewSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                model.viewSize = newSize
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            model.onCancel()
        }
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay(Color.black.opacity(0.18))

            if let rect = model.selectionRect {
                AnnotationSelectionBox(number: model.number, rect: rect)
                commentEditor(near: rect, in: size)
                    .onAppear {
                        commentFocused = true
                    }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bereich auswählen")
                        .font(.title2.weight(.semibold))
                    Text("Ziehe einen Rahmen um das UI-Element. Danach Kommentar eingeben und mit Enter speichern.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(28)
            }
        }
        .contentShape(Rectangle())
        .modifier(AnnotationDragModifier(isEnabled: model.selectionRect == nil, model: model, commentFocused: $commentFocused))
    }

    private func commentEditor(near rect: CGRect, in size: CGSize) -> some View {
        let width: CGFloat = 440
        let x = min(max(24, rect.midX - width / 2), max(24, size.width - width - 24))
        let belowY = rect.maxY + 16
        let y = belowY + 82 < size.height ? belowY : max(24, rect.minY - 98)

        return HStack(spacing: 10) {
            Text("\(model.number)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.blue))

            TextField("Kommentar hinzufügen...", text: $model.comment)
                .textFieldStyle(.plain)
                .focused($commentFocused)
                .onSubmit {
                    model.save()
                }

            Button {
                model.save()
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderless)
            .disabled((model.selectionRect?.width ?? 0) < 8 || (model.selectionRect?.height ?? 0) < 8)
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: 58)
        .background(.thinMaterial, in: Capsule())
        .position(x: x + width / 2, y: y + 29)
    }
}

private struct AnnotationSelectionBox: View {
    let number: Int
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.blue.opacity(0.14))
                .overlay(Rectangle().stroke(Color.blue, lineWidth: 3))
            Text("\(number)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.blue))
                .offset(x: -15, y: -15)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

private struct AnnotationDragModifier: ViewModifier {
    let isEnabled: Bool
    @ObservedObject var model: AnnotationSelectionModel
    var commentFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if isEnabled {
            content.gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        model.updateDrag(to: value.location)
                        commentFocused.wrappedValue = false
                    }
                    .onEnded { _ in
                        model.finishDrag()
                        commentFocused.wrappedValue = true
                    }
            )
        } else {
            content
        }
    }
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
