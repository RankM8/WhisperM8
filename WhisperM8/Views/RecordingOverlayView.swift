import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        Group {
            switch controller.overlayStyle {
            case .full:
                FullRecordingOverlayView(controller: controller)
            case .mini:
                MiniRecordingOverlayView(controller: controller)
            }
        }
    }
}

struct FullRecordingOverlayView: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        HStack(spacing: 10) {
            RecordingStatusIndicator(
                level: controller.audioLevel,
                isTranscribing: controller.isTranscribing,
                isPostProcessing: controller.isPostProcessing
            )

            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)

            Text(formatDuration(controller.duration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            OutputModeMenu(
                modes: controller.outputModes,
                selectedMode: controller.selectedOutputMode,
                isDisabled: controller.isTranscribing || controller.isPostProcessing,
                action: controller.setOutputMode
            )

            ContextControl(controller: controller, compact: false)

            VisualContextActionButtons(controller: controller)

            Spacer(minLength: 0)

            if !controller.isTranscribing && !controller.isPostProcessing {
                AudioLevelBars(level: controller.audioLevel)

                CancelRecordingButton(iconSize: 16, action: controller.cancelRecording)
            } else {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 24, height: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        }
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 2)
    }

    private var statusText: String {
        if controller.isPostProcessing { return "Improving..." }
        if controller.isTranscribing { return "Transcribing..." }
        return "Recording..."
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct VisualContextActionButtons: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if PermissionService.hasScreenRecordingPermission {
                    controller.addScreenshot()
                } else {
                    _ = PermissionService.requestScreenRecordingPermission()
                    PermissionService.openScreenRecordingPrivacySettings()
                }
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canAddVisualContext ? Color.green : Color.secondary.opacity(0.7))
            .disabled(controller.isTranscribing || controller.isPostProcessing || controller.isScreenClipRecording)
            .help(PermissionService.hasScreenRecordingPermission ? "Add screenshot context" : "Grant Screen Recording permission")
            .accessibilityLabel("Add screenshot context")

            Button {
                if PermissionService.hasScreenRecordingPermission {
                    controller.addAnnotation()
                } else {
                    _ = PermissionService.requestScreenRecordingPermission()
                    PermissionService.openScreenRecordingPrivacySettings()
                }
            } label: {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canAddVisualContext ? Color.green : Color.secondary.opacity(0.7))
            .disabled(controller.isTranscribing || controller.isPostProcessing || controller.isScreenClipRecording)
            .help(PermissionService.hasScreenRecordingPermission ? "Select and comment on a screen region" : "Grant Screen Recording permission")
            .accessibilityLabel("Select and comment on a screen region")

            Button {
                if PermissionService.hasScreenRecordingPermission {
                    controller.toggleScreenClip()
                } else {
                    _ = PermissionService.requestScreenRecordingPermission()
                    PermissionService.openScreenRecordingPrivacySettings()
                }
            } label: {
                Image(systemName: controller.isScreenClipRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background {
                        Circle()
                            .fill(controller.isScreenClipRecording ? Color.red.opacity(0.18) : Color.primary.opacity(0.08))
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(controller.isScreenClipRecording ? Color.red : (canAddVisualContext ? Color.green : Color.secondary.opacity(0.7)))
            .disabled(controller.isTranscribing || controller.isPostProcessing)
            .help(controller.isScreenClipRecording ? "Stop screen clip context" : (PermissionService.hasScreenRecordingPermission ? "Start screen clip context" : "Grant Screen Recording permission"))
            .accessibilityLabel(controller.isScreenClipRecording ? "Stop screen clip context" : "Start screen clip context")
        }
    }

    private var canAddVisualContext: Bool {
        AppPreferences.shared.isVisualContextCaptureEnabled
            && PermissionService.hasScreenRecordingPermission
    }
}

struct MiniRecordingOverlayView: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        HStack(spacing: 8) {
            if controller.showModePickerInMiniOverlay {
                MiniOutputModeChip(
                    mode: controller.selectedOutputMode,
                    isDisabled: controller.isTranscribing || controller.isPostProcessing
                )
            }

            ContextControl(controller: controller, compact: true)

            if controller.isTranscribing || controller.isPostProcessing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(controller.isPostProcessing ? "Improving" : "Transcribing")
            } else {
                MiniAudioLevelBars(level: controller.audioLevel)
                CancelRecordingButton(iconSize: 14, action: controller.cancelRecording)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        }
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
    }
}

struct OutputModeMenu: View {
    let modes: [OutputMode]
    let selectedMode: OutputMode
    let isDisabled: Bool
    let action: (OutputMode) -> Void

    var body: some View {
        Menu {
            ForEach(modes) { mode in
                Button {
                    action(mode)
                } label: {
                    if mode.id == selectedMode.id {
                        Label(mode.name, systemImage: "checkmark")
                    } else {
                        Text(mode.name)
                    }
                }
                .disabled(!mode.isEnabled)
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedMode.shortLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isDisabled ? Color.secondary.opacity(0.7) : Color.primary)
            .frame(width: 70, height: 24)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("Output mode")
    }
}

struct ContextControl: View {
    @ObservedObject var controller: OverlayController
    let compact: Bool

    var body: some View {
        Menu {
            ContextMenuContent(controller: controller)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))

                Text(label)
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(controller.contextBundle.isEmpty ? Color.secondary.opacity(0.75) : Color.green)
            .frame(width: compact ? 58 : 96, height: compact ? 22 : 24)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(controller.isTranscribing || controller.isPostProcessing)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var label: String {
        if compact {
            return controller.contextBundle.compactSummary
        }
        return controller.contextBundle.displaySummary
    }

    private var iconName: String {
        if controller.isScreenClipRecording { return "record.circle" }
        if !controller.contextBundle.screenshots.isEmpty || !controller.contextBundle.screenClips.isEmpty {
            return "photo.on.rectangle"
        }
        if !controller.contextBundle.annotations.isEmpty {
            return "cursorarrow.rays"
        }
        return controller.contextBundle.selectedText.isEmpty ? "text.badge.xmark" : "text.viewfinder"
    }

    private var helpText: String {
        if controller.contextBundle.isEmpty {
            return "No context was captured for this recording."
        }
        return "Context captured for this recording: \(controller.contextBundle.displaySummary)."
    }
}

struct ContextMenuContent: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        if !controller.contextBundle.selectedText.isEmpty {
            Text("Selected Text")
            Text(contextPreview)
        } else {
            Text("No selected text")
        }

        Divider()

        if PermissionService.hasScreenRecordingPermission {
            Button {
                controller.addScreenshot()
            } label: {
                Label("Add Screenshot", systemImage: "camera.viewfinder")
            }
            .disabled(!canAddVisualContext)

            Button {
                controller.addAnnotation()
            } label: {
                Label("Select + Comment", systemImage: "cursorarrow.rays")
            }
            .disabled(!canAddVisualContext)

            Button {
                controller.toggleScreenClip()
            } label: {
                Label(controller.isScreenClipRecording ? "Stop Screen Clip" : "Start Screen Clip", systemImage: controller.isScreenClipRecording ? "stop.circle" : "record.circle")
            }
            .disabled(!canAddVisualContext && !controller.isScreenClipRecording)
        } else {
            Button {
                _ = PermissionService.requestScreenRecordingPermission()
                PermissionService.openScreenRecordingPrivacySettings()
            } label: {
                Label("Grant Screen Recording", systemImage: "rectangle.dashed.badge.record")
            }
        }

        Button {
            controller.clearContext()
        } label: {
            Label("Clear Context", systemImage: "trash")
        }
        .disabled(controller.contextBundle.isEmpty || controller.isScreenClipRecording)

        Divider()

        Text(attachmentSummary)
    }

    private var canAddVisualContext: Bool {
        AppPreferences.shared.isVisualContextCaptureEnabled
            && PermissionService.hasScreenRecordingPermission
            && !controller.isScreenClipRecording
    }

    private var contextPreview: String {
        let text = controller.contextBundle.selectedText.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 42 {
            return String(text.prefix(42)) + "..."
        }
        return text
    }

    private var attachmentSummary: String {
        if controller.isScreenClipRecording {
            return "Screen clip recording..."
        }
        if controller.contextBundle.isEmpty {
            return PermissionService.hasScreenRecordingPermission ? "Ready for visual context" : "Screen Recording permission needed"
        }
        return controller.contextBundle.displaySummary
    }
}

struct MiniOutputModeChip: View {
    let mode: OutputMode
    let isDisabled: Bool

    var body: some View {
        Text(mode.shortLabel)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(isDisabled ? .secondary : .primary)
            .frame(width: 48, height: 22)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            }
            .accessibilityLabel("Output mode \(mode.name)")
    }
}

struct CancelRecordingButton: View {
    let iconSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Cancel recording")
    }
}

// MARK: - Status Indicator

struct RecordingStatusIndicator: View {
    let level: Float
    let isTranscribing: Bool
    let isPostProcessing: Bool

    private var clampedLevel: CGFloat {
        max(0, min(CGFloat(level), 1))
    }

    private var ringColor: Color {
        if isPostProcessing { return .purple }
        return isTranscribing ? .orange : .green
    }

    var body: some View {
        let intensity = (isTranscribing || isPostProcessing) ? 0 : clampedLevel

        ZStack {
            Circle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 20, height: 20)

            Circle()
                .strokeBorder(ringColor.opacity(0.4 + 0.5 * intensity), lineWidth: 1.5)
                .scaleEffect(0.85 + intensity * 0.35)
                .animation(.easeOut(duration: 0.12), value: intensity)

            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ringColor)
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusIcon: String {
        if isPostProcessing { return "sparkles" }
        return isTranscribing ? "waveform" : "mic.fill"
    }

    private var accessibilityLabel: String {
        if isPostProcessing { return "Improving" }
        return isTranscribing ? "Transcribing" : "Recording"
    }
}

// MARK: - Audio Level Bars

struct AudioLevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 4, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 20)
    }

    private var easedLevel: CGFloat {
        let clamped = max(0, min(CGFloat(level), 1))
        return pow(clamped, 0.6)
    }

    private func barIntensity(for index: Int) -> CGFloat {
        let boost = 0.55 + CGFloat(index) * 0.12
        return min(1, easedLevel * boost)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let baseHeight: CGFloat = 4
        let maxHeight = CGFloat(10 + index * 4)
        let intensity = barIntensity(for: index)
        return baseHeight + (maxHeight - baseHeight) * intensity
    }

    private func barColor(for index: Int) -> Color {
        let intensity = barIntensity(for: index)
        if intensity < 0.08 {
            return .gray.opacity(0.25)
        }
        if intensity > 0.75 {
            return .orange.opacity(0.9)
        }
        if intensity > 0.5 {
            return .yellow.opacity(0.85)
        }
        return .green.opacity(0.8)
    }
}

struct MiniAudioLevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(miniBarColor(for: index))
                    .frame(width: 3, height: miniBarHeight(for: index))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 14)
        .accessibilityLabel("Audio level")
    }

    private var miniEasedLevel: CGFloat {
        let clamped = max(0, min(CGFloat(level), 1))
        return pow(clamped, 0.65)
    }

    private func miniBarHeight(for index: Int) -> CGFloat {
        let baseHeight: CGFloat = 4
        let maxHeight = CGFloat(8 + index * 2)
        let intensity = min(1, miniEasedLevel * (0.6 + CGFloat(index) * 0.14))
        return baseHeight + (maxHeight - baseHeight) * intensity
    }

    private func miniBarColor(for index: Int) -> Color {
        let intensity = min(1, miniEasedLevel * (0.6 + CGFloat(index) * 0.14))
        if intensity < 0.08 {
            return .gray.opacity(0.25)
        }
        if intensity > 0.72 {
            return .orange.opacity(0.9)
        }
        if intensity > 0.5 {
            return .yellow.opacity(0.85)
        }
        return .green.opacity(0.8)
    }
}
