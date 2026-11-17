import SwiftUI

/// „Mitlesen“ (WM8-110, Paket 3): Ein Claude-Chat ohne Tab, dessen Status
/// aus Claudes Registry „arbeitet“ sagt, wird gerade von einem anderen Prozess
/// geschrieben — etwa einem geplanten Lauf (`claude -p`) oder einem `claude`
/// in einem anderen Terminal. Fortsetzen (`claude --resume`) hieße dann zwei
/// Prozesse in einer Sitzung. Bis zum Ende zeigt die App deshalb nur den
/// Verlauf, lädt ihn nach und sperrt jeden Start. Gilt für alle Chats ohne Tab,
/// nicht nur für geplante Läufe (Plan, Teil 1b).
enum AgentSessionReadAlong {
    /// Nachladen des Verlaufs, solange mitgelesen wird. Kostet je Takt eine
    /// Datei-Abfrage (Größe und Änderungszeit); neu gebaut wird der Text nur,
    /// wenn neue Nachrichten da sind.
    static let refreshInterval: Duration = .seconds(3)

    /// Rein, getestet. Hintergrund-Agents (`claude --bg`) öffnet man gerade
    /// durch Anhängen, Subagent-Jobs haben ihren eigenen Weg; beide bleiben
    /// unberührt.
    static func readsAlong(session: AgentChatSession, hasController: Bool,
                           status: AgentSessionRuntimeStatus?) -> Bool {
        !hasController
            && status == .working
            && session.provider == .claude
            && session.effectiveKind == .chat
    }

    static var blockedStartMessage: String {
        String(localized: "This chat is still working in another process, for example a scheduled run. You can read along; continuing works once it is done.")
    }
}

/// Leiste über dem Verlauf, solange mitgelesen wird. Keine Dauerbewegung: der
/// Punkt ist der gedrosselte Status-Puls (`AgentStatusIndicator`).
struct AgentReadAlongBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            AgentStatusIndicator(status: .working)
            Text("Working in another process. You are reading along; continuing works once it is done.")
                .font(.system(size: 12))
                .foregroundStyle(AgentTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.statusWorking.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}
