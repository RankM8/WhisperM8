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
        HStack(spacing: 12) {
            RecordingStatusIndicator(level: controller.audioLevel, isTranscribing: controller.isTranscribing)

            // Status text
            Text(controller.isTranscribing ? "Transcribing..." : "Recording...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            // Timer
            Text(formatDuration(controller.duration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            // Audio level bars (only during recording)
            if !controller.isTranscribing {
                AudioLevelBars(level: controller.audioLevel)

                // Cancel button (only during recording)
                CancelRecordingButton(iconSize: 16)
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct MiniRecordingOverlayView: View {
    @ObservedObject var controller: OverlayController

    var body: some View {
        HStack(spacing: 8) {
            if controller.isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Transcribing")
            } else {
                MiniAudioLevelBars(level: controller.audioLevel)
                CancelRecordingButton(iconSize: 14)
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

struct CancelRecordingButton: View {
    let iconSize: CGFloat

    var body: some View {
        Button {
            AppState.shared.cancelRecording()
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

    private var clampedLevel: CGFloat {
        max(0, min(CGFloat(level), 1))
    }

    private var ringColor: Color {
        isTranscribing ? .orange : .green
    }

    var body: some View {
        let intensity = isTranscribing ? 0 : clampedLevel

        ZStack {
            Circle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 20, height: 20)

            Circle()
                .strokeBorder(ringColor.opacity(0.4 + 0.5 * intensity), lineWidth: 1.5)
                .scaleEffect(0.85 + intensity * 0.35)
                .animation(.easeOut(duration: 0.12), value: intensity)

            Image(systemName: isTranscribing ? "waveform" : "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ringColor)
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(isTranscribing ? "Transcribing" : "Recording")
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
