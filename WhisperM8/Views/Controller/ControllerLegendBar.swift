import SwiftUI

/// Was die Legende links als Ziel zeigt.
struct ControllerLegendTarget: Equatable {
    enum Tone: Equatable {
        case neutral, working, awaiting, recording
    }

    var title: String
    var detail: String?
    var tone: Tone

    /// Ziel aus dem Zusammenhang der letzten Eingabe.
    static func make(context: ControllerContext, chatTitle: String?) -> ControllerLegendTarget {
        let title = chatTitle ?? String(localized: "No chat selected")
        switch context {
        case .paused:
            return .init(title: String(localized: "Controller paused"), detail: nil, tone: .neutral)
        case let .recording(phase, targetIsChat):
            let chatDetail = "→ \(title)"
            let detail = targetIsChat ? chatDetail : String(localized: "→ app in front")
            switch phase {
            case .recording: return .init(title: String(localized: "Recording"), detail: detail, tone: .recording)
            case .transcribing: return .init(title: String(localized: "Transcribing"), detail: detail, tone: .neutral)
            case .postProcessing: return .init(title: String(localized: "Rewriting"), detail: detail, tone: .neutral)
            }
        case .quickAction:
            return .init(title: String(localized: "Quick action running"), detail: nil, tone: .neutral)
        case .clipboardPanel:
            return .init(title: String(localized: "Clipboard"), detail: nil, tone: .neutral)
        case .menu:
            return .init(title: String(localized: "Menu"), detail: title, tone: .neutral)
        case .modal:
            return .init(title: String(localized: "Dialog"), detail: nil, tone: .neutral)
        case .list:
            return .init(title: String(localized: "List"), detail: nil, tone: .neutral)
        case let .chat(state):
            switch state.status {
            case .working: return .init(title: title, detail: String(localized: "working"), tone: .working)
            case .awaitingInput: return .init(title: title, detail: String(localized: "question"), tone: .awaiting)
            case .idle: return .init(title: title, detail: String(localized: "ready"), tone: .neutral)
            case .unknown: return .init(title: title, detail: nil, tone: .neutral)
            case .ended: return .init(title: title, detail: String(localized: "ended"), tone: .neutral)
            }
        case .outsideApp, .otherWindow, .noWindow:
            return .init(title: String(localized: "Another window"), detail: nil, tone: .neutral)
        }
    }
}

/// Legende am unteren Rand des Agent-Chats-Fensters: links das Ziel, rechts
/// nur die Tasten, die jetzt etwas tun. Reine Darstellung — Daten kommen vom
/// `ControllerLegendHost`.
struct ControllerLegendBar: View {
    let target: ControllerLegendTarget
    let entries: [ControllerLegendEntry]
    var holdProgress: ControllerHoldProgress?

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(verbatim: target.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                if let detail = target.detail {
                    Text(verbatim: "· \(detail)")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .layoutPriority(0)

            Rectangle()
                .fill(AppTheme.borderStrong)
                .frame(width: 1, height: 16)

            Spacer(minLength: 0)

            // Schmale Fenster (Kacheln, halbe Bildschirme): von hinten kürzen,
            // die wichtigsten Tasten stehen vorn.
            ViewThatFits(in: .horizontal) {
                keys(entries)
                keys(Array(entries.prefix(6)))
                keys(Array(entries.prefix(4)))
                keys(Array(entries.prefix(2)))
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(AppTheme.header)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.border).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func keys(_ shown: [ControllerLegendEntry]) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 5) {
                    ControllerInputGlyphs(inputs: entry.inputs, isCombination: entry.isCombination)
                        .overlay {
                            if let holdProgress, entry.inputs.contains(where: { $0.matches(holdProgress.button) }) {
                                ControllerHoldRing(duration: holdProgress.duration)
                                    .id(holdProgress.startedAt)
                            }
                        }
                    Text(verbatim: entry.label.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
    }

    private var dotColor: Color {
        switch target.tone {
        case .neutral: return AppTheme.textTertiary
        case .working: return AppTheme.statusWorking
        case .awaiting: return AppTheme.statusAwaiting
        case .recording: return AppTheme.statusError
        }
    }
}

/// Ring, der sich einmal über die Halte-Zeit füllt. Eine endliche Animation,
/// keine Dauerbewegung.
private struct ControllerHoldRing: View {
    let duration: TimeInterval
    @State private var progress: CGFloat = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(-3)
            .onAppear {
                withAnimation(.linear(duration: duration)) { progress = 1 }
            }
            .allowsHitTesting(false)
    }
}

private extension ControllerLegendInput {
    func matches(_ button: ControllerButton) -> Bool {
        switch self {
        case let .button(own): return own == button
        case .bumpers: return button == .l1 || button == .r1
        default: return false
        }
    }
}

/// Bindeglied zwischen Controller-Zustand und Legende. Eigene kleine View:
/// Nur sie beobachtet `ControllerStatus` und `ControllerUIModel`.
struct ControllerLegendHost: View {
    let windowID: UUID
    @State private var status = ControllerManager.shared.status
    @State private var model = ControllerUIModel.shared
    @State private var windows = AgentWindowStore.shared
    @AppStorage(PreferenceKeys.controllerLegendEnabled) private var legendEnabled = true

    var body: some View {
        if legendEnabled, status.isRunning, status.device != nil {
            let isThisWindow = windows.keyAgentChatWindowID == windowID
            let context: ControllerContext = status.isPaused ? .paused : (isThisWindow ? model.context : .otherWindow)
            ControllerLegendBar(
                target: .make(context: context, chatTitle: model.targetTitle),
                entries: isThisWindow || status.isPaused ? ControllerLegend.entries(for: context) : [],
                holdProgress: isThisWindow ? model.holdProgress : nil
            )
        }
    }
}
