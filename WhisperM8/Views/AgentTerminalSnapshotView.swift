import SwiftUI

/// Read-only Anzeige eines vorher persistierten Terminal-Snapshots. Wird im
/// `AgentSessionDetailView` gezeigt, wenn aktuell kein Controller laeuft
/// (Force Quit, Tab geschlossen, App neu gestartet) — als Ersatz fuer die
/// rein technische Summary-Ansicht.
///
/// Design: optisch terminalartig (monospace, Theme-Farben), klar als
/// "offline" markiert, mit Hinweis darauf wie der User die Session
/// wiederherstellt.
struct AgentTerminalSnapshotView: View {
    let snapshot: AgentTerminalSnapshot
    let session: AgentChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner

            ScrollView {
                Text(displayText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AgentTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(AgentTheme.background)
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(AgentTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentTheme.textPrimary)
                Text(subline)
                    .font(.system(size: 11))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
            Spacer()
            Text(relativeTimestamp)
                .font(.system(size: 11))
                .foregroundStyle(AgentTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AgentTheme.surface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AgentTheme.border),
            alignment: .bottom
        )
    }

    /// Wir bevorzugen den Scrollback (mehr Kontext); falls leer (legacy
    /// snapshot) fallen wir auf Visible-Slice zurueck.
    private var displayText: String {
        if !snapshot.scrollbackText.isEmpty {
            return snapshot.scrollbackText
        }
        return snapshot.visibleText
    }

    private var headlineText: String {
        if snapshot.processWasRunning {
            return "Terminal ist nicht verbunden"
        }
        if let code = snapshot.exitCode, code != 0 {
            return "Letzter Lauf endete mit Code \(code)"
        }
        return "Letzter Lauf beendet"
    }

    private var subline: String {
        "Resume oben in der Header-Leiste startet \(session.provider.displayName) Code erneut."
    }

    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.capturedAt, relativeTo: Date())
    }
}
