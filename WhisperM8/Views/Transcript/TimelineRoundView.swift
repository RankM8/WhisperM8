import SwiftUI

/// Eine Gesprächsrunde in der Timeline: Prompt-Bubble rechts, stille
/// Aktivitätszeile, Antwort als freier Markdown-Text links.
///
/// Equatable, damit Live-Reloads (200-ms-Debounce beim Streaming) nur die
/// tatsächlich veränderte letzte Runde neu evaluieren — Markdown-Parsing
/// pro Body-Aufruf ist sonst der teuerste Posten.
struct TimelineRoundView: View, Equatable {
    let round: TranscriptRound
    let isLatest: Bool
    /// Läuft gerade ein Turn in dieser Runde? (Aktivität offen halten lohnt
    /// sich nicht — aber die Zeile aktualisiert live ihre Summary.)
    let isLiveRound: Bool

    @State private var isHovering = false

    static func == (lhs: TimelineRoundView, rhs: TimelineRoundView) -> Bool {
        lhs.round == rhs.round && lhs.isLatest == rhs.isLatest && lhs.isLiveRound == rhs.isLiveRound
    }

    /// Ältere Runden treten zurück (Design: 50 %); Hover holt sie hoch.
    private var dimOpacity: Double {
        if isLatest || isHovering { return 1.0 }
        return 0.55
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let prompt = round.prompt {
                promptBubble(prompt)
            } else {
                incompleteHeader
            }

            if round.hasActivity || isLiveRound {
                TimelineActivityRow(
                    steps: round.steps,
                    stats: round.stats,
                    isLive: isLiveRound
                )
                .padding(.top, 10)
            }

            ForEach(round.answers) { answer in
                TranscriptMarkdownView(text: answer.text)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.top, 12)
            }
        }
        .padding(.vertical, 10)
        .opacity(dimOpacity)
        .animation(.easeOut(duration: 0.18), value: dimOpacity)
        .onHover { isHovering = $0 }
    }

    // MARK: - Prompt

    @ViewBuilder
    private func promptBubble(_ prompt: TranscriptPrompt) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(prompt.text)
                .font(.system(size: 13.5))
                .foregroundStyle(AgentTheme.textPrimary)
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16, bottomLeadingRadius: 16,
                        bottomTrailingRadius: 5, topTrailingRadius: 16
                    )
                    .fill(AgentTheme.control)
                )
                // Dezenter Akzent NUR an der letzten Runde: Hairline-Ring
                // statt Flächen-Tint — das Dimmen der älteren Runden trägt
                // die Betonung bereits.
                .overlay {
                    if isLatest {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 16, bottomLeadingRadius: 16,
                            bottomTrailingRadius: 5, topTrailingRadius: 16
                        )
                        .strokeBorder(AgentTheme.accent.opacity(0.28), lineWidth: 1)
                    }
                }
                .frame(maxWidth: 460, alignment: .trailing)

            ForEach(Array(prompt.attachments.enumerated()), id: \.offset) { _, attachment in
                Text("📷 Bild angehängt · \(attachment.mediaType) · \(byteLabel(attachment.byteSize))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.trailing, 5)
            }

            if let timestamp = prompt.timestamp {
                Text(Self.timeFormatter.string(from: timestamp))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(isLatest ? AgentTheme.accent : AgentTheme.textTertiary)
                    .padding(.trailing, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Tail-angeschnittene Runde ohne Prompt.
    private var incompleteHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .font(.system(size: 9))
            Text("Runde unvollständig — früherer Verlauf oberhalb des Lesefensters")
                .font(.system(size: 10.5))
        }
        .foregroundStyle(AgentTheme.textTertiary)
    }

    // MARK: - Helpers

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func byteLabel(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
