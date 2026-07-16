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
    /// Lade-Feedback + Fenster-Hinweis des Owners (vier Zustände).
    var history: TranscriptHistoryState = .idle
    var loadHint: String?
    /// Summary-Karte über der Timeline (Chat-Sessions; Subagents haben die
    /// Ergebnis-Karte in ihrer eigenen Detail-View).
    var showsSummaryCard: Bool = false
    /// Persistierter Terminal-Stand der beendeten Session (Stufe 1,
    /// Plaintext) — schaltet den „Terminal"-Modus frei. `nil` = kein
    /// Snapshot vorhanden (Legacy-Sessions), Modi Chat|Roh wie bisher.
    var terminalSnapshot: TerminalSnapshot? = nil

    /// Global gemerkter Modus — wer Roh bevorzugt, bekommt Roh überall.
    /// Default „terminal": beendete Chats sehen wie beendete Terminals aus;
    /// ohne Snapshot löst der Modus auf Chat auf (`mode`-Getter).
    @AppStorage("agentTranscriptViewMode") private var storedMode = TranscriptViewMode.terminal.rawValue
    /// Runden-Projektion, off-main gebaut (volle Transcripts können groß sein).
    @State private var timeline: TranscriptTimeline = .empty

    enum TranscriptViewMode: String, CaseIterable {
        case terminal
        case chat
        case raw

        var label: String {
            switch self {
            case .terminal: return "Terminal"
            case .chat: return "Chat"
            case .raw: return "Roh"
            }
        }
    }

    private var mode: TranscriptViewMode {
        let resolved = TranscriptViewMode(rawValue: storedMode) ?? .chat
        // Terminal-Modus nur mit vorhandenem Snapshot — sonst Chat.
        if resolved == .terminal, terminalSnapshot == nil { return .chat }
        return resolved
    }

    /// Modi im Umschalter: „Terminal" erscheint nur, wenn ein Snapshot da ist.
    private var availableModes: [TranscriptViewMode] {
        terminalSnapshot == nil ? [.chat, .raw] : TranscriptViewMode.allCases
    }

    private var isEmpty: Bool {
        transcript?.messages.isEmpty ?? true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isEmpty || terminalSnapshot != nil {
                headerStrip
            }
            if showsSummaryCard, !isEmpty, mode != .terminal {
                SessionSummaryCard(session: session)
                    .background(AgentTheme.background)
            }
            if mode == .terminal, let terminalSnapshot {
                TerminalSnapshotView(snapshot: terminalSnapshot)
            } else if isEmpty || mode == .raw {
                AgentChatTranscriptView(
                    transcript: transcript,
                    session: session,
                    history: history,
                    loadHint: loadHint,
                    onLoadEarlierHistory: onLoadEarlierHistory
                )
            } else if timeline.isEmpty {
                // Die Runden-Projektion baut noch (off-main). Die ScrollView
                // darf sich NICHT an leerem Inhalt verankern — sonst bleibt
                // der Viewport nach dem Befüllen leer stehen, bis der User
                // scrollt (defaultScrollAnchor(.bottom)-Race).
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentTheme.background)
            } else {
                AgentTimelineView(
                    timeline: timeline,
                    isWorking: isWorking,
                    hasTruncatedHead: transcript?.hasTruncatedHead ?? false,
                    history: history,
                    loadHint: loadHint,
                    onLoadEarlierHistory: onLoadEarlierHistory
                )
                .background(AgentTheme.background)
            }
        }
        .task(id: rebuildTaskID) {
            await rebuildTimeline()
        }
    }

    /// Inhaltsbasierte Rebuild-ID: Zahl allein reicht nicht — beim Wechsel
    /// zwischen zwei Chats mit gleicher Nachrichtenzahl bliebe sonst die
    /// alte Timeline stehen.
    private var rebuildTaskID: String {
        guard let transcript, let first = transcript.messages.first, let last = transcript.messages.last else {
            return "leer"
        }
        return "\(transcript.messages.count)-\(first.id.uuidString)-\(last.id.uuidString)"
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
                ForEach(availableModes, id: \.self) { candidate in
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
        // Terminal-Modus mit (noch) ungeladenem Transcript: kein irreführendes
        // „0 Nachrichten" — der Load ist bewusst deferred (Performance).
        if mode == .terminal, transcript == nil {
            return "Terminal-Stand"
        }
        let messages = transcript?.messages.count ?? 0
        var parts = ["\(messages) Nachrichten"]
        if mode == .chat, !timeline.isEmpty {
            parts.append(timeline.rounds.count == 1 ? "1 Runde" : "\(timeline.rounds.count) Runden")
        }
        return parts.joined(separator: " · ")
    }
}
