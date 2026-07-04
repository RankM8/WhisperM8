import SwiftUI

/// Root-View im Recording-Panel: Das Panel hat eine fixe Maximalgröße —
/// hier wird die Pill darin verankert (Rechts-Anker bzw. Spiegel-Fall) und
/// ihr sichtbarer Frame an den Controller gemeldet (hitTest-Passthrough,
/// Hover-Tracking, Drag-Clamp und Anker-Persistenz hängen daran).
struct RecordingOverlayView: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        RecordingPillView(controller: controller)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            controller.reportPillFrame(geometry.frame(in: .global))
                        }
                        .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                            // Feuert auch während der Breitenanimation —
                            // gewollt: Tracking/HitTest folgen der Pill live.
                            controller.reportPillFrame(newFrame)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pillAlignment)
            .padding(OverlayFrameResolver.contentMargin)
    }

    private var pillAlignment: Alignment {
        switch controller.pillAlignment {
        case .trailing:
            return .trailing
        case .leading:
            return .leading
        }
    }
}

// MARK: - Kontext-Menü (wiederverwendet von der Pill)

struct ContextMenuContent: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        agentChatSection
        selectedTextSection
        attachmentsSection

        Divider()

        Button {
            controller.captureScreenshot()
        } label: {
            Label("Take Screenshot (Select Area)", systemImage: "camera.viewfinder")
        }
        .disabled(!isVisualContextEnabled || controller.isScreenClipRecording)

        Button {
            controller.addScreenshot()
        } label: {
            Label("Import Clipboard Screenshot", systemImage: "doc.on.clipboard")
        }
        .disabled(!isVisualContextEnabled || controller.isScreenClipRecording)

        if PermissionService.hasScreenRecordingPermission {
            Button {
                controller.toggleScreenClip()
            } label: {
                Label(controller.isScreenClipRecording ? "Stop Screen Clip" : "Start Screen Clip", systemImage: controller.isScreenClipRecording ? "stop.circle" : "record.circle")
            }
            .disabled((!canRecordScreenClip && !controller.isScreenClipRecording))
        } else {
            Button {
                _ = PermissionService.requestScreenRecordingPermission()
                PermissionService.openScreenRecordingPrivacySettings()
            } label: {
                Label("Grant Screen Recording", systemImage: "rectangle.dashed.badge.record")
            }
        }

        Divider()

        Button(role: .destructive) {
            controller.clearContext()
        } label: {
            Label("Clear All Context", systemImage: "trash")
        }
        .disabled(controller.contextBundle.isEmpty || controller.isScreenClipRecording)
    }

    // MARK: - Section Builders (zeigen pro-Item Delete)

    @ViewBuilder
    private var agentChatSection: some View {
        if let chat = controller.contextBundle.agentChat {
            Section("Chat") {
                Button {
                    controller.performContextAction(.removeAgentChat)
                } label: {
                    Label("Remove · \(chat.title) (\(chat.projectName))", systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var selectedTextSection: some View {
        if !controller.contextBundle.selectedText.isEmpty {
            Section("Text") {
                Text(selectedTextPreview)
                    .lineLimit(1)
                Button {
                    controller.performContextAction(.removeSelectedText)
                } label: {
                    Label("Remove Selected Text", systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        let bundle = controller.contextBundle
        let allAttachments = bundle.allAttachments
        if !allAttachments.isEmpty {
            Section("Visuals (\(allAttachments.count))") {
                ForEach(Array(allAttachments.enumerated()), id: \.element.id) { index, attachment in
                    Button {
                        controller.performContextAction(.removeAttachment(id: attachment.id))
                    } label: {
                        // SwiftUI Menus rendern `Label`-Icons als kleine Bitmap, wenn man
                        // `Image(nsImage:)` mit `.renderingMode(.original)` reicht — das
                        // gibt uns echte Thumbnails statt eines SF-Symbol-Platzhalters.
                        Label {
                            Text(attachmentLabel(attachment, index: index))
                        } icon: {
                            attachmentIcon(attachment)
                        }
                    }
                    .disabled(controller.isScreenClipRecording)
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentIcon(_ attachment: ContextAttachment) -> some View {
        if let nsImage = thumbnailImage(for: attachment) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.original)
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: attachmentSymbolName(attachment))
        }
    }

    private func thumbnailImage(for attachment: ContextAttachment) -> NSImage? {
        let url = attachment.thumbnailURL ?? attachment.fileURL
        // Screen-Clips sind .mov / .mp4 — daraus kein Standbild laden, nur SF-Symbol.
        if attachment.kind == .screenClip { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func attachmentSymbolName(_ attachment: ContextAttachment) -> String {
        switch attachment.kind {
        case .screenshot: return "photo"
        case .annotation: return "pencil.tip.crop.circle"
        case .screenClip: return "film"
        case .visualFrame: return "rectangle.stack"
        }
    }

    private func attachmentLabel(_ attachment: ContextAttachment, index: Int) -> String {
        let position = index + 1
        switch attachment.kind {
        case .screenshot:
            return "Remove Screenshot #\(position)"
        case .annotation:
            if let number = attachment.annotationNumber {
                return "Remove Annotation \(number)"
            }
            return "Remove Annotation #\(position)"
        case .screenClip:
            if let duration = attachment.duration {
                return "Remove Clip #\(position) · \(String(format: "%.1f", duration))s"
            }
            return "Remove Clip #\(position)"
        case .visualFrame:
            return "Remove Frame #\(position)"
        }
    }

    private var selectedTextPreview: String {
        let text = controller.contextBundle.selectedText.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 42 {
            return "\"" + String(text.prefix(42)) + "…\""
        }
        return "\"\(text)\""
    }

    private var isVisualContextEnabled: Bool {
        AppPreferences.shared.isVisualContextCaptureEnabled
    }

    private var canRecordScreenClip: Bool {
        isVisualContextEnabled
            && PermissionService.hasScreenRecordingPermission
            && !controller.isScreenClipRecording
    }
}
