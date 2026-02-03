import SwiftUI

struct RecordingOverlayView: View {
    @Binding var audioLevel: Float
    @Binding var duration: TimeInterval
    @Binding var isTranscribing: Bool

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing red dot
            Circle()
                .fill(isTranscribing ? Color.orange : Color.red)
                .frame(width: 12, height: 12)
                .scaleEffect(isPulsing && !isTranscribing ? 1.3 : 1.0)
                .animation(
                    isTranscribing ? .none : .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .onAppear {
                    isPulsing = true
                }

            // Status text
            Text(isTranscribing ? "Transkribiere..." : "Aufnahme...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            // Timer
            Text(formatDuration(duration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            // Audio level bars (only during recording)
            if !isTranscribing {
                AudioLevelBars(level: audioLevel)
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

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index + 1) / 5.0
        let active = level >= threshold * 0.8
        let baseHeight: CGFloat = 4
        let maxHeight = CGFloat(8 + index * 3)
        return active ? maxHeight : baseHeight
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / 5.0
        if level >= threshold * 0.8 {
            if index >= 4 {
                return .orange
            } else if index >= 3 {
                return .yellow
            }
            return .green
        }
        return .gray.opacity(0.3)
    }
}

