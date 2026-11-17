import Combine
import SwiftUI

/// „Mitlesen“ (WM8-110, Paket 3): In einen Claude-Chat, dessen Tab keinen
/// laufenden Prozess hat, schreibt gerade ein anderer Prozess — ein geplanter
/// Lauf (`claude -p`) oder ein `claude` in einem anderen Terminal. Fortsetzen
/// (`claude --resume`) hieße dann zwei Prozesse in einer Sitzung. Bis zum Ende
/// zeigt die App deshalb nur den Verlauf, lädt ihn nach und sperrt jeden Start.
///
/// Belegt wird das nicht über den Status-Speicher der Chats: Der nimmt
/// Registry-Einträge nur für Chats mit eigenem PTY an. Zwei Belege zählen:
/// - ein lebender Eintrag in Claudes Registry zu dieser Sitzung, der kein
///   Hintergrund-Agent ist (`ClaudeRegistryStatusSource`, nur lebende PIDs);
/// - ein Lauf einer geplanten Aufgabe, der laut „Geplant“ mit dieser Sitzung
///   arbeitet (`ScheduledTasksOverviewModel`) — gilt auch, wenn `claude -p`
///   keinen Registry-Eintrag schreibt.
enum AgentSessionReadAlong {
    /// Nachladen des Verlaufs, solange mitgelesen wird. Kostet je Takt eine
    /// Datei-Abfrage (Größe und Änderungszeit) und das Prüfen der Belege (zwei
    /// Abfragen im Speicher); neu gebaut wird der Text nur bei neuen Nachrichten.
    static let refreshInterval: Duration = .seconds(3)

    /// Wer gerade in die Sitzung schreibt.
    struct Writer: Equatable {
        /// Aus der Registry; `nil` = nur aus „Geplant“ bekannt.
        var pid: Int32?
        var account: String?
        /// Name der geplanten Aufgabe, falls es ein Lauf ist.
        var scheduledTask: String?
    }

    /// Rein, getestet. `ownProcessRunning`: Der eigene Tab hat einen laufenden
    /// Prozess — dann ist er selbst der Schreiber. Hintergrund-Agents
    /// (`claude --bg`) öffnet man gerade durch Anhängen, Subagent-Jobs haben
    /// ihren eigenen Weg; nur normale Claude-Chats lesen mit.
    static func writer(session: AgentChatSession, ownProcessRunning: Bool,
                       registry: [ClaudeSessionRecord], activeRunTasks: [String: String]) -> Writer? {
        guard !ownProcessRunning, session.provider == .claude, session.effectiveKind == .chat,
              let external = session.externalSessionID?.lowercased(), !external.isEmpty else { return nil }
        let task = activeRunTasks[external]
        if let record = registry.first(where: { !$0.isBackground && $0.sessionID.lowercased() == external }) {
            return Writer(pid: record.pid, account: record.profileName, scheduledTask: task)
        }
        return task.map { Writer(pid: nil, account: nil, scheduledTask: $0) }
    }

    /// Dieselbe Prüfung gegen die echten Quellen.
    @MainActor
    static func liveWriter(session: AgentChatSession, ownProcessRunning: Bool,
                           registry: ClaudeRegistryStatusSource = .shared,
                           scheduled: ScheduledTasksOverviewModel = .shared) -> Writer? {
        guard let external = session.externalSessionID, !external.isEmpty else { return nil }
        return writer(session: session, ownProcessRunning: ownProcessRunning,
                      registry: registry.records(forExternalSessionID: external),
                      activeRunTasks: scheduled.activeRunTasksBySession)
    }

    /// Anlässe zum Neuprüfen: Registry-Änderung zu dieser Sitzung oder ein
    /// neuer Stand der laufenden Läufe in „Geplant“.
    @MainActor
    static func changes(for externalSessionID: String?) -> AnyPublisher<Void, Never> {
        let external = externalSessionID?.lowercased() ?? ""
        let registry = ClaudeRegistryStatusSource.shared.changes
            .filter { $0 == external }
            .map { _ in () }
        let runs = NotificationCenter.default.publisher(for: ScheduledTasksOverviewModel.activeRunsDidChange)
            .map { _ in () }
        return registry.merge(with: runs).eraseToAnyPublisher()
    }

    static var blockedStartMessage: String {
        String(localized: "This chat is still working in another process, for example a scheduled run. You can read along; continuing works once it is done.")
    }

    /// Text der Leiste: wer schreibt.
    static func bannerText(_ writer: Writer) -> String {
        if let task = writer.scheduledTask {
            return String(localized: "The scheduled task “\(task)” is working in this chat. You are reading along; continuing works once it is done.")
        }
        if let pid = writer.pid, let account = writer.account {
            return String(localized: "Another Claude process (PID \(String(pid)), account \(account)) is working in this chat. You are reading along; continuing works once it is done.")
        }
        return String(localized: "Working in another process. You are reading along; continuing works once it is done.")
    }
}

/// Leiste über dem Verlauf, solange mitgelesen wird. Keine Dauerbewegung: der
/// Punkt ist der gedrosselte Status-Puls (`AgentStatusIndicator`).
struct AgentReadAlongBanner: View {
    let writer: AgentSessionReadAlong.Writer

    var body: some View {
        HStack(spacing: 8) {
            AgentStatusIndicator(status: .working)
            Text(verbatim: AgentSessionReadAlong.bannerText(writer))
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
