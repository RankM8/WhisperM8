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
    /// Lade-Feedback des Owners (Spinner / „✓ N geladen" / Anfang erreicht).
    var history: TranscriptHistoryState = .idle
    /// Fenster-Hinweis für den Button, z.B. „512 KB → 2 MB".
    var loadHint: String?
    /// Vergrößert das Tail-Lesefenster des Owners (explizites Nachladen).
    var onLoadEarlierHistory: (() -> Void)?

    /// Runden-Windowing mit HARTER Obergrenze (Hang-Fix 2026-07-16):
    /// `.defaultScrollAnchor(.bottom)` zwingt SwiftUI, alle Item-Höhen
    /// vorauszuberechnen — das bisherige, additiv wachsende Fenster ließ
    /// einen einzigen Layout-Pass bei langen Chats auf Minuten anwachsen
    /// (Apple-Hang-Report: 186 s). Jetzt fallen beim Hochblättern die
    /// neuesten Runden aus dem Render-Baum (`TranscriptWindow`), der
    /// Scroll-Anker wird per ScrollViewReader wiederhergestellt.
    private static let initialRoundWindow = 40
    private static let roundBatchIncrement = 40
    private static let maxRenderedRounds = 160

    @State private var window = TranscriptWindow(
        initialSize: initialRoundWindow,
        batchSize: roundBatchIncrement,
        maxSize: maxRenderedRounds
    )
    /// Erste Runden-ID des letzten Sync-Stands — unterscheidet Kopf-Wachstum
    /// (Disk-Nachladen prependet ältere Runden) von Tail-Wachstum (Live).
    @State private var firstRoundID: String?

    private var visibleRounds: ArraySlice<TranscriptRound> {
        window.slice(of: timeline.rounds)
    }

    private var hiddenEarlierCount: Int {
        window.hiddenEarlierCount
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if showsHistorySection {
                        historySection(proxy: proxy)
                    }
                    ForEach(visibleRounds) { round in
                        TimelineRoundView(
                            round: round,
                            isLatest: round.id == timeline.rounds.last?.id,
                            isLiveRound: isWorking && round.id == timeline.rounds.last?.id
                        )
                        .equatable()
                    }
                    if window.hiddenLaterCount > 0 {
                        laterSection(proxy: proxy)
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
        }
        .onAppear {
            syncWindow()
        }
        .onChange(of: timeline.rounds.count) { _, _ in
            syncWindow()
        }
    }

    /// Fenster mit dem aktuellen Timeline-Stand abgleichen. Kopf- vs.
    /// Tail-Wachstum wird über die Identität der ersten Runde erkannt —
    /// Disk-Nachladen prependet (erste ID ändert sich), Live-Streaming
    /// appendet (erste ID bleibt).
    private func syncWindow() {
        let rounds = timeline.rounds
        defer { firstRoundID = rounds.first?.id }
        if window.total == 0 || rounds.count < window.total {
            window.reset(total: rounds.count)
            return
        }
        if rounds.count > window.total, let known = firstRoundID, known != rounds.first?.id {
            window.updateForHeadGrowth(total: rounds.count)
        } else {
            window.updateForTailChange(total: rounds.count)
        }
    }

    /// Blättert nach oben und hält die bislang oberste Runde im Viewport —
    /// ohne Anker würde der Inhalt unter dem Cursor wegspringen.
    private func pageUp(proxy: ScrollViewProxy) {
        let anchorID = visibleRounds.first?.id
        window.pageUp()
        if let anchorID {
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }

    private var canLoadFromDisk: Bool {
        hasTruncatedHead && onLoadEarlierHistory != nil
    }

    private var showsHistorySection: Bool {
        history.isLoading || history.lastLoadedDelta != nil
            || hiddenEarlierCount > 0 || canLoadFromDisk || history.reachedStart
    }

    /// Vier Zustände (Prototyp Rev 2): Button → Spinner → „✓ N geladen" →
    /// „Anfang der Konversation". Sichtbares Feedback für JEDEN Klick.
    @ViewBuilder
    private func historySection(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 7) {
            if history.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verlauf wird geladen …")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
                .padding(.vertical, 5)
            } else {
                if let delta = history.lastLoadedDelta {
                    Text(delta > 0 ? "✓ \(delta) ältere Nachrichten geladen" : "✓ Verlauf aktualisiert")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AgentTheme.statusWorking)
                }
                if hiddenEarlierCount > 0 {
                    TranscriptHistoryPill(title: "\(hiddenEarlierCount) frühere Runden anzeigen", detail: nil) {
                        pageUp(proxy: proxy)
                    }
                } else if canLoadFromDisk {
                    TranscriptHistoryPill(title: "Früheren Verlauf laden", detail: loadHint) {
                        // Das Aufdecken der nachgeladenen Runden übernimmt
                        // syncWindow (Kopf-Wachstums-Pfad) nach dem Reload.
                        onLoadEarlierHistory?()
                    }
                } else if history.reachedStart {
                    TranscriptHistoryStartMarker()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
    }

    /// Gegenstück am unteren Rand, sobald das Fenster nach oben geblättert
    /// wurde: zurück zu den neuesten Runden (Tail-Fenster + ans Ende
    /// scrollen).
    @ViewBuilder
    private func laterSection(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 7) {
            TranscriptHistoryPill(
                title: "Zu den neuesten Runden",
                detail: "\(window.hiddenLaterCount) ausgeblendet"
            ) {
                window.jumpToTail()
                if let lastID = timeline.rounds.last?.id {
                    DispatchQueue.main.async {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
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
