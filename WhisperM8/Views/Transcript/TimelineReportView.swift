import SwiftUI

/// Gerenderte Darstellung eines Subagent-Reports — statt des rohen
/// JSON-Blobs (Anti-Muster aus dem Screenshot-Review). Wird sowohl in der
/// Timeline (finale agent_message, die als Report parst) als auch in der
/// Ergebnis-Karte der SubagentJobDetailView verwendet.
struct TimelineReportView: View {
    let report: AgentReport
    /// Kompakt (Timeline-Antwort) vs. Karte (mit allen Evidenz-Zeilen).
    var showsStatusLine: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsStatusLine {
                HStack(spacing: 6) {
                    Text(report.status.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(statusColor)
                    Text("Abschluss-Report")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            }
            TranscriptMarkdownView(text: report.summary)
            ReportEvidenceRows(report: report)
        }
    }

    private var statusColor: Color {
        switch report.status {
        case .success: return AgentTheme.statusWorking
        case .partial: return AgentTheme.statusAwaiting
        case .failure: return AgentTheme.statusError
        }
    }

    /// Schneller Vor-Check + toleranter Parse: nur Texte, die wie ein
    /// Report-JSON aussehen, durchlaufen den Decoder.
    static func parseIfReport(_ text: String) -> AgentReport? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("```") else { return nil }
        return AgentReport.parse(lastMessage: text)
    }
}

/// Deterministische Evidenz-Zeilen eines Reports: Dateien, Commits, Tests,
/// offene Fragen — im Op-Zeilen-Stil der Aktivitäts-Details.
struct ReportEvidenceRows: View {
    let report: AgentReport
    /// Die Ergebnis-Karte zeigt offene Fragen separat im Deep-Dive.
    var includeOpenQuestions: Bool = true

    var body: some View {
        if !report.filesChanged.isEmpty || !report.commits.isEmpty
            || report.testsRun != nil || (includeOpenQuestions && !report.openQuestions.isEmpty) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(report.filesChanged.enumerated()), id: \.offset) { _, file in
                    row(glyph: "±", color: AgentTheme.accent, text: file, mono: true)
                }
                ForEach(Array(report.commits.enumerated()), id: \.offset) { _, commit in
                    row(glyph: "⌥", color: AgentTheme.accentDiffPos, text: "\(commit.sha.prefix(7)) \(commit.message)", mono: true)
                }
                if let tests = report.testsRun {
                    row(glyph: tests.passed ? "✓" : "✗",
                        color: tests.passed ? AgentTheme.statusWorking : AgentTheme.statusError,
                        text: tests.command, mono: true)
                }
                if includeOpenQuestions {
                    ForEach(Array(report.openQuestions.enumerated()), id: \.offset) { _, question in
                        row(glyph: "?", color: AgentTheme.statusAwaiting, text: question, mono: false)
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private func row(glyph: String, color: Color, text: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(glyph)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 11, alignment: .center)
            Text(text)
                .font(mono ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                .foregroundStyle(AgentTheme.textSecondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
