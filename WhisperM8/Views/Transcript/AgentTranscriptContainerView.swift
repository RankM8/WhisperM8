import AppKit
import SwiftUI

/// Die Verlaufsansicht einer Session: schmale Meta-Leiste, optional die
/// Summary-Karte, darunter der Verlauf als CLI-formatierter Text.
///
/// **Eine Ansicht statt drei.** Bis 01.08.2026 gab es hier einen Umschalter
/// Terminal | Chat | Roh. Alle drei bauten pro Nachricht eine SwiftUI-
/// Hierarchie, alle drei brauchten deshalb harte Deckel gegen das Layout
/// (2000 Zeichen pro Block, 160 Runden, 2000 Snapshot-Zeilen) — und alle
/// drei hingen an `.defaultScrollAnchor(.bottom)`, das SwiftUI zwingt, jede
/// Item-Höhe vorauszuberechnen. Mit sechs Grid-Panes hat das die App
/// dauerhaft eingefroren: Main Thread endlos in `StackLayout.prioritize`,
/// 100 % CPU, kein Fortschritt.
///
/// Jetzt rendert `TranscriptTextRenderer` einen flachen Zeilenstrom, den
/// `TranscriptTextView` als EIN `NSTextView` (TextKit 2) darstellt. Gelayoutet
/// wird nur der sichtbare Ausschnitt — die Kosten hängen an der Fensterhöhe
/// statt an der Länge des Verlaufs. Textauswahl über alles, ⌘F und Kopieren
/// gibt es dadurch nativ.
struct AgentTranscriptContainerView: View {
    let transcript: AgentChatTranscript?
    let session: AgentChatSession
    /// Läuft gerade ein Turn? → Live-Indikator unten.
    var isWorking: Bool = false
    /// Nachlade-Hook des Owners (vergrößert dessen Tail-Lesefenster) — nur
    /// relevant wenn `transcript.hasTruncatedHead`.
    var onLoadEarlierHistory: (() -> Void)?
    /// Lade-Feedback + Fenster-Hinweis des Owners (vier Zustände).
    var history: TranscriptHistoryState = .idle
    var loadHint: String?
    /// Summary-Karte über dem Verlauf (Chat-Sessions; Subagents haben die
    /// Ergebnis-Karte in ihrer eigenen Detail-View).
    var showsSummaryCard: Bool = false

    /// Fertig gebauter Verlaufstext. Wird off-main erzeugt (siehe `rebuild`)
    /// und hier nur gehalten — das Setzen im NSTextView ist billig.
    @State private var document = NSAttributedString()
    /// Zählt hoch, sobald ein neuer Stand steht; die View vergleicht nur
    /// dieses Token statt des gesamten Textes.
    @State private var revision = 0
    @State private var lineCount = 0

    private var isEmpty: Bool {
        transcript?.messages.isEmpty ?? true
    }

    var body: some View {
        Group {
            if isEmpty {
                TranscriptEmptyStateView(transcript: transcript, session: session)
            } else {
                VStack(spacing: 0) {
                    metaStrip
                    if showsSummaryCard {
                        SessionSummaryCard(session: session)
                            .background(AgentTheme.background)
                    }
                    historyStrip
                    if revision == 0 {
                        // Der Text baut noch (off-main).
                        VStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TranscriptTextView(document: document, revision: revision)
                    }
                    if isWorking {
                        liveStrip
                    }
                }
                .background(AgentTheme.background)
            }
        }
        .task(id: rebuildTaskID) {
            await rebuild()
        }
    }

    // MARK: - Aufbau

    /// Inhaltsbasierte Rebuild-ID: Die Zahl allein reicht nicht — beim
    /// Wechsel zwischen zwei Chats mit gleicher Nachrichtenzahl bliebe sonst
    /// der alte Text stehen.
    private var rebuildTaskID: String {
        guard let transcript, let first = transcript.messages.first, let last = transcript.messages.last else {
            return "leer"
        }
        return "\(transcript.messages.count)-\(first.id.uuidString)-\(last.id.uuidString)"
    }

    /// Rendern und Attributieren laufen komplett off-main und sind
    /// abbrechbar: Ein Sessionwechsel verwirft den laufenden Aufbau, statt
    /// ihn zu Ende zu rechnen (`Task.isCancelled`-Prüfung nach dem Bau).
    private func rebuild() async {
        guard let transcript, !transcript.messages.isEmpty else {
            document = NSAttributedString()
            revision = 0
            lineCount = 0
            return
        }
        let built = await Task.detached(priority: .userInitiated) { () -> (NSAttributedString, Int) in
            let lines = TranscriptTextRenderer.render(transcript)
            return (TranscriptTextDocument.make(lines: lines), lines.count)
        }.value
        guard !Task.isCancelled else { return }
        document = built.0
        lineCount = built.1
        revision &+= 1
    }

    // MARK: - Chrome

    /// Ersetzt den früheren Modus-Umschalter: keine Auswahl mehr, sondern
    /// die Herkunft des Verlaufs und sein Umfang.
    private var metaStrip: some View {
        HStack(spacing: 8) {
            Text(metaLabel)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(AgentTheme.textTertiary)
            Spacer()
            if let loadHint, transcript?.hasTruncatedHead == true {
                Text(loadHint)
                    .font(.system(size: 10))
                    .foregroundStyle(AgentTheme.textTertiary)
            }
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
        if lineCount > 0 {
            parts.append("\(lineCount) Zeilen")
        }
        return parts.joined(separator: " · ")
    }

    /// Vier Zustände wie bisher: Button → Spinner → „✓ N geladen" → „Anfang
    /// der Konversation". Der Unterschied zu früher: Das Lesefenster begrenzt
    /// nur noch, wie viel GELADEN ist — dargestellt wird davon alles, ohne
    /// Kürzung mitten im Text.
    @ViewBuilder
    private var historyStrip: some View {
        if showsHistorySection {
            VStack(spacing: 7) {
                if history.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Verlauf wird geladen …")
                            .font(.system(size: 11))
                            .foregroundStyle(AgentTheme.textTertiary)
                    }
                } else {
                    if let delta = history.lastLoadedDelta {
                        Text(delta > 0 ? "✓ \(delta) ältere Nachrichten geladen" : "✓ Verlauf aktualisiert")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(AgentTheme.statusWorking)
                    }
                    if canLoadFromDisk {
                        TranscriptHistoryPill(title: "Früheren Verlauf laden", detail: loadHint) {
                            onLoadEarlierHistory?()
                        }
                    } else if history.reachedStart {
                        TranscriptHistoryStartMarker()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AgentTheme.background)
        }
    }

    private var canLoadFromDisk: Bool {
        (transcript?.hasTruncatedHead ?? false) && onLoadEarlierHistory != nil
    }

    private var showsHistorySection: Bool {
        history.isLoading || history.lastLoadedDelta != nil || canLoadFromDisk || history.reachedStart
    }

    /// Pulsierender „arbeitet"-Hinweis unter dem Verlauf.
    private var liveStrip: some View {
        HStack(spacing: 7) {
            TimelinePulsingDot(color: AgentTheme.statusWorking)
            Text("arbeitet …")
                .font(.system(size: 11.5))
                .foregroundStyle(AgentTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(AgentTheme.surface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AgentTheme.border),
            alignment: .top
        )
    }
}
