import SwiftUI

/// Belegzeilen einer Subagent-Ergebnis-Karte: geänderte Dateien, Commits,
/// Testlauf und offene Fragen. Stammt aus der abgelösten Timeline-
/// Report-Ansicht; genutzt von `SubagentJobDetailView`.
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
