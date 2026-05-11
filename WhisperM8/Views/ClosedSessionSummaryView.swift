import SwiftUI

/// Detail-View einer geschlossenen / nicht-attached Session. Zeigt eine kurze
/// Headline + ausführliche Beschreibung, statt der bisherigen rein technischen
/// "Session metadata loaded" Hinweise. Resume- und Session-ID-Hinweise bleiben
/// als Footer kleingedruckt erhalten, damit Power-User weiterhin Zugriff
/// haben.
struct ClosedSessionSummaryView: View {
    let session: AgentChatSession
    let errorMessage: String?
    let isGenerating: Bool
    /// Ruft den Summarizer auf. `force = true` bedeutet "Neu generieren"-Klick;
    /// `false` ist der „passive" Anstoß beim Öffnen.
    var onGenerate: (_ force: Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(12)
                        .background(AgentTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AgentTheme.border, lineWidth: 1))
                }

                if let summary = session.summary {
                    summaryBody(summary)
                } else if isGenerating {
                    generatingPlaceholder
                } else {
                    emptyPlaceholder
                }

                technicalFooter
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AgentTheme.background)
    }

    @ViewBuilder
    private func summaryBody(_ summary: AgentSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Text(summary.headline)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                regenerateButton
            }

            Divider().background(AgentTheme.border)

            Text(summary.details)
                .font(.system(size: 13))
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text("Automatisch zusammengefasst · \(relativeDate(summary.generatedAt))")
                    .font(.system(size: 11))
            }
            .foregroundStyle(AgentTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var generatingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Zusammenfassung wird generiert …")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AgentTheme.textPrimary)
            }
            Text("Wir lesen das Transcript dieser Session und fragen \(session.provider.displayName) nach einer kurzen Zusammenfassung. Das dauert in der Regel ein paar Sekunden.")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var emptyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Noch keine Zusammenfassung verfügbar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AgentTheme.textPrimary)
            Text("Wenn diese Session ein vollständiges Transcript bei \(session.provider.displayName) hinterlassen hat, kann WhisperM8 daraus eine kurze Zusammenfassung erzeugen.")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onGenerate(true)
            } label: {
                Label("Zusammenfassung erzeugen", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var regenerateButton: some View {
        if isGenerating {
            ProgressView().controlSize(.small)
        } else {
            Button {
                onGenerate(true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Zusammenfassung neu generieren")
        }
    }

    @ViewBuilder
    private var technicalFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().background(AgentTheme.border)
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Diese Session ist aktuell nicht verbunden. ")
                + Text("Resume").bold()
                + Text(" oben in der Header-Leiste verbindet sie wieder.")
            }
            .font(.system(size: 11))
            .foregroundStyle(AgentTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            if let externalSessionID = session.externalSessionID {
                Text("Session-ID: \(externalSessionID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AgentTheme.textTertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 12)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
