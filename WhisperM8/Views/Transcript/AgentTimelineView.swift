import SwiftUI

/// Timeline-Ansicht eines Transcripts nach Variante E
/// (docs/design/agent-transcript-timeline.html): User-Prompt als Bubble
/// rechts, Antwort als freier Markdown-Text links, Tool-Aktivität als stille
/// aufklappbare Zeile. Ältere Runden sind gedimmt (Hover hebt an); die
/// letzte Runde trägt den Akzent BEWUSST dezent — nur Hairline-Ring +
/// Indigo-Zeitstempel, kein Flächen-Tint (User-Entscheidung 2026-07-05).
struct AgentTimelineView: View {
    let timeline: TranscriptTimeline
    /// `true` solange ein Turn läuft (Subagent working) — zeigt unter der
    /// letzten Runde eine pulsierende Live-Aktivitätszeile.
    var isWorking: Bool = false
    /// Die Quelldatei hat vor dem Lesefenster weiteren Verlauf.
    var hasTruncatedHead: Bool = false
    /// Vergrößert das Tail-Lesefenster des Owners (explizites Nachladen).
    var onLoadEarlierHistory: (() -> Void)?

    /// Runden-Windowing analog zum Message-Windowing der Roh-Ansicht:
    /// `.defaultScrollAnchor(.bottom)` zwingt SwiftUI, alle Item-Höhen
    /// vorauszuberechnen — bei hunderten Runden würde der Initial-Layout-Pass
    /// den Main-Thread blockieren.
    private static let initialRoundWindow = 40
    private static let roundBatchIncrement = 40

    @State private var visibleCount: Int = initialRoundWindow

    private var visibleRounds: ArraySlice<TranscriptRound> {
        let rounds = timeline.rounds
        guard !rounds.isEmpty else { return [] }
        return rounds[max(0, rounds.count - visibleCount)...]
    }

    private var hiddenEarlierCount: Int {
        max(0, timeline.rounds.count - visibleRounds.count)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 4) {
                if hiddenEarlierCount > 0 || (hasTruncatedHead && onLoadEarlierHistory != nil) {
                    earlierButton
                }
                ForEach(visibleRounds) { round in
                    TimelineRoundView(
                        round: round,
                        isLatest: round.id == timeline.rounds.last?.id,
                        isLiveRound: isWorking && round.id == timeline.rounds.last?.id
                    )
                    .equatable()
                }
                if isWorking {
                    liveActivityIndicator
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: timeline.rounds.count) { old, new in
            // Nur bei schrumpfender Rundenzahl (Session-Wechsel) resetten —
            // Wachstum ist Live-Append oder nachgeladener Verlauf, dort muss
            // das (präventiv geweitete) Fenster erhalten bleiben.
            if new < old {
                visibleCount = Self.initialRoundWindow
            }
        }
    }

    @ViewBuilder
    private var earlierButton: some View {
        Button {
            if hiddenEarlierCount > 0 {
                // Erst das Render-Fenster über bereits geladene Runden ziehen …
                visibleCount = min(timeline.rounds.count, visibleCount + Self.roundBatchIncrement)
            } else {
                // … dann von der Platte nachladen (Owner vergrößert sein
                // Tail-Fenster). Fenster präventiv weiten, damit die neuen
                // Runden direkt sichtbar sind.
                visibleCount += Self.roundBatchIncrement
                onLoadEarlierHistory?()
            }
        } label: {
            Text(hiddenEarlierCount > 0
                ? "\(hiddenEarlierCount) frühere Runden anzeigen"
                : "Früheren Verlauf laden …")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentTheme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
    }

    /// Pulsierender „arbeitet"-Hinweis unter der letzten Runde — die
    /// eigentlichen Steps wachsen live in der Runden-Aktivität mit.
    @ViewBuilder
    private var liveActivityIndicator: some View {
        HStack(spacing: 7) {
            TimelinePulsingDot(color: AgentTheme.statusWorking)
            Text(liveHint)
                .font(.system(size: 11.5))
                .foregroundStyle(AgentTheme.textSecondary)
        }
        .padding(.leading, 2)
    }

    private var liveHint: String {
        guard let lastRound = timeline.rounds.last else { return "arbeitet …" }
        let lastToolSubject = lastRound.steps.reversed().compactMap { step -> String? in
            if case .tool(let tool) = step.kind { return tool.subject }
            return nil
        }.first
        if let lastToolSubject, !lastToolSubject.isEmpty {
            return "arbeitet … zuletzt: \(lastToolSubject)"
        }
        return "arbeitet …"
    }
}

/// Sanft pulsierender Status-Punkt (schlichter als der Sonar-Dot der
/// Sidebar — hier reicht ein Opacity-Puls, kein auslaufender Ring).
struct TimelinePulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
