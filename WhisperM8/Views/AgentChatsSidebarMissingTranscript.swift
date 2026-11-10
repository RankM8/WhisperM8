import SwiftUI

/// Markierung rechts in der Sidebar-Zeile, wenn zu einem geschlossenen Chat
/// keine Verlaufsdatei auf der Platte liegt. Zwei Fälle, die früher beide
/// „Verlauf gelöscht“ hießen:
///
/// - Der Chat hatte Verlauf (`AgentTranscriptPresence.hadHistory`): Der
///   Provider hat die Datei gelöscht, fortsetzen geht nicht mehr.
/// - Es wurde nie eine Nachricht gesendet: Dann gab es nie eine Datei. Der
///   Chat ist leer und lässt sich ganz normal starten.
struct MissingTranscriptBadge: View {
    let session: AgentChatSession

    var body: some View {
        Image(systemName: Self.symbolName(for: session))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AgentTheme.textTertiary)
            .help(Self.hint(for: session))
            .accessibilityLabel(Text(verbatim: Self.hint(for: session)))
    }

    static func symbolName(for session: AgentChatSession) -> String {
        AgentTranscriptPresence.hadHistory(session) ? "questionmark.circle" : "circle.dashed"
    }

    static func hint(for session: AgentChatSession) -> String {
        AgentTranscriptPresence.hadHistory(session)
            ? String(localized: "History deleted, can't be continued")
            : String(localized: "Empty chat, no message was sent")
    }
}
