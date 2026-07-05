import SwiftUI

/// Hülle um die Transcript-Anzeige: schmale Kopf-Leiste (Meta + Chat|Roh-
/// Umschalter) über der Timeline (Variante E, primäre UX) bzw. der
/// bestehenden Roh-Ansicht (`AgentChatTranscriptView`, verlustfreier
/// Fallback). Leere/fehlende Transcripts delegieren komplett an die
/// Roh-View — deren Empty-States (Resume-Hinweis, Orphan-BG-Chat) bleiben
/// die eine Wahrheit.
struct AgentTranscriptContainerView: View {
    let transcript: AgentChatTranscript?
    let session: AgentChatSession
    /// Läuft gerade ein Turn (Subagent working)? → Live-Indikator unten.
    var isWorking: Bool = false
    /// Nachlade-Hook des Owners (vergrößert dessen Tail-Lesefenster) — nur
    /// relevant wenn `transcript.hasTruncatedHead`.
    var onLoadEarlierHistory: (() -> Void)?

    /// Global gemerkter Modus — wer Roh bevorzugt, bekommt Roh überall.
    @AppStorage("agentTranscriptViewMode") private var storedMode = TranscriptViewMode.chat.rawValue
    /// Runden-Projektion, off-main gebaut (volle Transcripts können groß sein).
    @State private var timeline: TranscriptTimeline = .empty

    enum TranscriptViewMode: String, CaseIterable {
        case chat
        case raw

        var label: String {
            switch self {
            case .chat: return "Chat"
            case .raw: return "Roh"
            }
        }
    }

    private var mode: TranscriptViewMode {
        TranscriptViewMode(rawValue: storedMode) ?? .chat
    }

    private var isEmpty: Bool {
        transcript?.messages.isEmpty ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isEmpty {
                headerStrip
            }
            if isEmpty || mode == .raw {
                AgentChatTranscriptView(
                    transcript: transcript,
                    session: session,
                    onLoadEarlierHistory: onLoadEarlierHistory
                )
            } else {
                AgentTimelineView(
                    timeline: timeline,
                    isWorking: isWorking,
                    hasTruncatedHead: transcript?.hasTruncatedHead ?? false,
                    onLoadEarlierHistory: onLoadEarlierHistory
                )
                .background(AgentTheme.background)
            }
        }
        .task(id: transcript?.messages.count ?? -1) {
            await rebuildTimeline()
        }
    }

    /// Off-main, weil volle Claude-Transcripts tausende Messages haben können
    /// und der Builder pro Tool-Step Input-JSON parst.
    private func rebuildTimeline() async {
        guard let transcript, !transcript.messages.isEmpty else {
            timeline = .empty
            return
        }
        let built = await Task.detached(priority: .userInitiated) {
            TranscriptTimelineBuilder.build(from: transcript)
        }.value
        timeline = built
    }

    @ViewBuilder
    private var headerStrip: some View {
        HStack(spacing: 8) {
            Text(metaLabel)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(AgentTheme.textTertiary)
            Spacer()
            Picker("", selection: Binding(
                get: { mode },
                set: { storedMode = $0.rawValue }
            )) {
                ForEach(TranscriptViewMode.allCases, id: \.self) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AgentTheme.surface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AgentTheme.border),
            alignment: .bottom
        )
    }

    private var metaLabel: String {
        let messages = transcript?.messages.count ?? 0
        var parts = ["\(messages) Nachrichten"]
        if mode == .chat, !timeline.isEmpty {
            parts.append(timeline.rounds.count == 1 ? "1 Runde" : "\(timeline.rounds.count) Runden")
        }
        return parts.joined(separator: " · ")
    }
}
