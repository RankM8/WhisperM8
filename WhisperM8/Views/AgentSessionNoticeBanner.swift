import SwiftUI

/// Gelbes Meldungsbanner der Chat-Ansicht, ohne Abhängigkeiten (Eingaben
/// rein, Aktionen als Closures), damit es eine Snapshot-Fixture bekommt.
///
/// Fehler (samt „Prozess beenden“ der Codex-Startsperre) und Hinweis des
/// Rückfalls der Übernahme stehen untereinander; keiner verdeckt den anderen.
/// Kein Hover: Text und Knöpfe sind immer sichtbar.
struct AgentSessionNoticeBanner: View {
    /// Zustand des Knopfs „Prozess beenden“ (`nil` = keine Knöpfe).
    enum CodexEndPhase: Equatable { case ready, ending, notEnded, signalFailed }

    let errorMessage: String?
    let fallbackNotice: String?
    var codexEndPhase: CodexEndPhase?
    var onEndProcess: () -> Void = {}
    var onForceQuit: () -> Void = {}
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .textSelection(.enabled)
                    codexEndActions
                }
                if let fallbackNotice {
                    Text(fallbackNotice)
                        .font(.system(size: 12))
                        .foregroundStyle(AgentTheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AgentTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
    }

    @ViewBuilder
    private var codexEndActions: some View {
        if let codexEndPhase {
            HStack(spacing: 8) {
                switch codexEndPhase {
                case .ready:
                    Button("End Process", action: onEndProcess)
                case .ending:
                    ProgressView().controlSize(.small)
                    Text("Ending process…")
                case .notEnded:
                    Text("The process did not end.")
                    Button("Force Quit", action: onForceQuit)
                case .signalFailed:
                    Text("The process could not be ended. Close it where it runs.")
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
        }
    }
}
