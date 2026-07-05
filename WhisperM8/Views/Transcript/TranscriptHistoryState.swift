import SwiftUI

/// Zustand des „Früheren Verlauf laden"-Mechanismus — vom Owner der
/// Transcript-Ansicht gepflegt (AgentSessionDetailView / SubagentJobDetailView)
/// und in Timeline + Roh-Ansicht identisch gerendert. Die vier UI-Zustände
/// aus docs/design/chat-summary-ui.html Rev 2:
/// Vorhanden (Button) → Lädt (Spinner, gesperrt) → „✓ N geladen" → Anfang.
struct TranscriptHistoryState: Equatable {
    /// Ein Nachladen läuft — Button gesperrt, Spinner sichtbar.
    var isLoading = false
    /// Feedback nach einem Nachladen: wie viele Messages dazukamen.
    /// Bleibt stehen, bis die nächste Aktion ihn ersetzt — der User sieht
    /// so IMMER, dass der Klick gewirkt hat (der alte „nichts passiert"-Bug).
    var lastLoadedDelta: Int?
    /// `true` sobald ein Nachladen den Dateianfang erreicht hat.
    var reachedStart = false

    static let idle = TranscriptHistoryState()
}

/// Runder Nachlade-Button (Pill mit Rahmen — „echter Button, kein
/// Geistertext"). Geteilt von Timeline- und Roh-Ansicht.
struct TranscriptHistoryPill: View {
    let title: String
    let detail: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AgentTheme.textTertiary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if let detail {
                    Text("· \(detail)")
                        .font(.system(size: 11))
                        .foregroundStyle(AgentTheme.textTertiary)
                }
            }
            .foregroundStyle(isHovering ? AgentTheme.textPrimary : AgentTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(isHovering ? AgentTheme.panel : AgentTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(AgentTheme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// „Anfang der Konversation" — Marker mit Trennlinien links/rechts.
struct TranscriptHistoryStartMarker: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Text("Anfang der Konversation")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(AgentTheme.textTertiary)
            line
        }
        .padding(.vertical, 6)
    }

    private var line: some View {
        Rectangle()
            .fill(AgentTheme.borderStrong)
            .frame(width: 56, height: 1)
    }
}
