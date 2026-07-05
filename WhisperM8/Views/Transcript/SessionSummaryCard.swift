import SwiftUI

/// Zusammenfassungs-Karte über der Timeline (Prototyp chat-summary-ui.html):
/// Headline + Freshness-Chip + Evidenz-Zeilen + Deep-Dive + Aktualisieren.
/// Gepinnt unter der Meta-Leiste — beim Öffnen sofort sichtbar, ohne Scrollen.
struct SessionSummaryCard: View {
    let session: AgentChatSession

    @State private var isGenerating = false
    @State private var isStale = false
    @State private var isDeepDiveExpanded = false

    private var summary: AgentSessionSummary? { session.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            cardTop

            if isGenerating {
                Text("Der Verlauf wird gerade zusammengefasst — die Karte füllt sich gleich.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentTheme.textTertiary)
            } else if let summary {
                Text(summary.headline)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let evidence = summary.evidence, !evidence.isEmpty {
                    evidenceRows(evidence)
                }

                if !summary.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28)) {
                            isDeepDiveExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(isDeepDiveExpanded ? 90 : 0))
                            Text("Deep-Dive")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(AgentTheme.textTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)

                    if isDeepDiveExpanded {
                        TranscriptMarkdownView(text: summary.details)
                            .padding(.top, 6)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(AgentTheme.border), alignment: .top)
                            .transition(.opacity)
                    }
                }
            } else {
                Text("Für diesen Chat gibt es noch keine Zusammenfassung.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentTheme.textTertiary)
                Button {
                    triggerRefresh()
                } label: {
                    Text("✦ Zusammenfassung erzeugen")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(AgentTheme.accentTintSoft, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgentTheme.accentTint, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgentTheme.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .onReceive(NotificationCenter.default.publisher(for: AgentSessionSummarizer.inFlightDidChangeNotification)) { _ in
            refreshRuntimeState()
        }
        .task(id: session.summary) {
            refreshRuntimeState()
        }
    }

    // MARK: - Kopfzeile

    @ViewBuilder
    private var cardTop: some View {
        HStack(spacing: 8) {
            Text("Zusammenfassung")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(AgentTheme.textTertiary)

            if isGenerating {
                chip(text: "✦ Wird erzeugt …", color: AgentTheme.accent, background: AgentTheme.accentTintSoft, border: AgentTheme.accentTint)
            } else if summary != nil {
                if isStale {
                    chip(text: "Veraltet — Transcript ist gewachsen", color: AgentTheme.statusAwaiting,
                         background: AgentTheme.statusAwaiting.opacity(0.07), border: AgentTheme.statusAwaiting.opacity(0.35))
                } else {
                    chip(text: "Aktuell · \(relativeAge)", color: AgentTheme.textTertiary,
                         background: .clear, border: AgentTheme.borderStrong, dotColor: AgentTheme.statusWorking)
                }
            }

            Spacer(minLength: 0)

            if !isGenerating, summary != nil {
                Button {
                    triggerRefresh()
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AgentTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Zusammenfassung neu erzeugen (Headless-CLI)")
            }
        }
    }

    private func chip(text: String, color: Color, background: Color, border: Color, dotColor: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let dotColor {
                Circle().fill(dotColor).frame(width: 5, height: 5)
            }
            Text(text)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(background, in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
    }

    // MARK: - Evidenz

    @ViewBuilder
    private func evidenceRows(_ evidence: AgentSessionSummary.Evidence) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(evidence.commits.enumerated()), id: \.offset) { _, commit in
                evidenceRow(glyph: "⌥", color: AgentTheme.accentDiffPos, text: "\(commit.sha.prefix(7)) \(commit.message)")
            }
            ForEach(Array(evidence.tests.enumerated()), id: \.offset) { _, test in
                evidenceRow(glyph: test.passed ? "✓" : "✗",
                            color: test.passed ? AgentTheme.statusWorking : AgentTheme.statusError,
                            text: test.command)
            }
            ForEach(Array(evidence.filesChanged.prefix(4).enumerated()), id: \.offset) { _, file in
                evidenceRow(glyph: "±", color: AgentTheme.accent, text: file)
            }
            if evidence.filesChanged.count > 4 {
                evidenceRow(glyph: "·", color: AgentTheme.textTertiary, text: "+ \(evidence.filesChanged.count - 4) weitere Dateien")
            }
        }
        .padding(.leading, 2)
    }

    private func evidenceRow(glyph: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(glyph)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 11, alignment: .center)
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(AgentTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Zustand

    private var relativeAge: String {
        guard let generatedAt = summary?.generatedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: generatedAt, relativeTo: Date())
    }

    private func refreshRuntimeState() {
        isGenerating = AgentSessionSummarizer.shared.inFlight.contains(session.id)
        isStale = AgentSessionSummarizer.shared.isSummaryStale(for: session)
    }

    private func triggerRefresh() {
        AgentSessionSummarizer.shared.requestSummary(sessionID: session.id, force: true, reason: "manual")
        isGenerating = true
    }
}
