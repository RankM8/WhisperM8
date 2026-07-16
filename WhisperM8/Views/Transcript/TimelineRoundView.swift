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

    static func == (lhs: TimelineRoundView, rhs: TimelineRoundView) -> Bool {
        lhs.round == rhs.round && lhs.isLatest == rhs.isLatest && lhs.isLiveRound == rhs.isLiveRound
    }

    /// Ältere Runden treten KONSTANT leicht zurück (0.8 — jederzeit gut
    /// lesbar). Bewusst KEIN Hover-Effekt: Zustandsinformation darf nie erst
    /// unter dem Cursor erscheinen (User-Feedback 2026-07-05).
    private var dimOpacity: Double {
        isLatest ? 1.0 : 0.8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let prompt = round.prompt {
                if let teammate = prompt.teammate {
                    TeammateMessageBlock(message: teammate, timestamp: prompt.timestamp)
                } else {
                    promptBubble(prompt)
                }
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
                // Finale Subagent-Antworten sind Report-JSON — gerendert
                // statt als Blob (Prototyp-Note 2).
                if let report = TimelineReportView.parseIfReport(answer.text) {
                    TimelineReportView(report: report)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.top, 12)
                } else {
                    TranscriptMarkdownView(text: answer.text)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.top, 12)
                }
            }
        }
        .padding(.vertical, 10)
        .opacity(dimOpacity)
    }

    // MARK: - Prompt

    @ViewBuilder
    private func promptBubble(_ prompt: TranscriptPrompt) -> some View {
        // Harter Render-Deckel: riesige injizierte Prompts (System-Prompt-
        // Dumps, gepastete Blobs) haben als EIN ungedeckelter Text das
        // CoreText-Layout beim Hochscrollen sekundenlang blockiert und die
        // App gekillt. Voller Inhalt bleibt in der Roh-Ansicht.
        let clipped = TranscriptRenderLimits.clip(prompt.text, max: TranscriptRenderLimits.promptChars)
        VStack(alignment: .trailing, spacing: 3) {
            Text(clipped.text)
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

            if clipped.isTruncated {
                Text(TranscriptRenderLimits.truncationHint(clipped.truncatedCount))
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .padding(.trailing, 5)
            }

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

/// Injizierte Teammate-/System-Nachricht: gestrichelter Block mit Badge und
/// Ein-Zeilen-Gist; das rohe Payload erst nach Klick (nie wieder eine
/// bildschirmfüllende JSON-Bubble).
struct TeammateMessageBlock: View {
    let message: InjectedTeammateMessage
    let timestamp: Date?

    @State private var isExpanded = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("TEAMMATE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color(red: 0.89, green: 0.60, blue: 0.78))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color(red: 0.89, green: 0.60, blue: 0.78).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.89, green: 0.60, blue: 0.78).opacity(0.28), lineWidth: 1))
                    Text(message.gist)
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if let timestamp {
                        Text(Self.timeFormatter.string(from: timestamp))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(AgentTheme.textTertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(AgentTheme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Render-Deckel wie überall: Teammate-Payloads können ganze
                // JSON-Dumps sein.
                Text(TranscriptRenderLimits.clip(message.raw, max: TranscriptRenderLimits.rawBlockChars).text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AgentTheme.textSecondary)
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(AgentTheme.border), alignment: .top)
                    .transition(.opacity)
            }
        }
        .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AgentTheme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .frame(maxWidth: 500, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, 12)
    }
}
