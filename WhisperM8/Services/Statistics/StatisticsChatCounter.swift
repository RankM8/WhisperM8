import Foundation

/// Zählt neu gestartete Chats und trägt die Zeit vor der Statistik einmalig
/// aus `createdAt` der gespeicherten Sessions nach.
///
/// Doppelzählung wird an zwei Stellen verhindert:
/// - Das Nachtragen zählt nur Sessions, die VOR dem Start der Erfassung
///   entstanden sind (`cutoff`); alles danach zählt der Live-Zähler.
/// - Wurden die Daten gelöscht, nachdem in diesem Lauf schon nachgetragen
///   war, zählt der Live-Zähler nicht mehr mit: Der nächste Start trägt alle
///   bis dahin gespeicherten Sessions ohnehin erneut nach.
final class StatisticsChatCounter: @unchecked Sendable {
    /// Ein Tag mit nachgetragenen Chats.
    struct DayCounts: Equatable, Sendable {
        var kinds: [String: Int] = [:]
        var projects: [String: Int] = [:]
    }

    private let store: StatisticsStore
    private let calendar: Calendar
    // Nur auf der Store-Queue lesen und schreiben (in `update`-Closures);
    // der Lock schützt nur gegen Zugriffe von außen in Tests.
    private let lock = NSLock()
    private var backfillSettledThisRun = false

    init(store: StatisticsStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    // MARK: - Reine Logik

    /// Art des Chats für „Womit gearbeitet wurde“. `nil` = zählt nicht als Chat
    /// (Terminal, Agent View, Subagent-Job).
    static func kind(of session: AgentChatSession) -> StatsChatKind? {
        switch session.kind ?? .chat {
        case .terminal, .agentView, .subagentJob:
            return nil
        case .backgroundChat:
            return .background
        case .chat:
            if session.provider == .codex { return .codex }
            return session.claudeBackendModel == nil ? .claude : .gpt
        }
    }

    /// Projektname = letzter Pfadteil, wie bei den Token-Zahlen.
    static func projectName(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Chats je Tag aus dem Workspace, nur was vor `cutoff` entstanden ist.
    /// Gezählt werden nur in WhisperM8 angelegte Sessions (`createdManually`),
    /// wie beim Live-Zähler; von Platte entdeckte Fremd-Sessions nicht.
    static func backfillCounts(
        workspace: AgentWorkspace,
        before cutoff: Date,
        calendar: Calendar
    ) -> [String: DayCounts] {
        let paths = Dictionary(workspace.projects.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        var result: [String: DayCounts] = [:]
        for session in workspace.sessions where session.createdManually == true && session.createdAt < cutoff {
            guard let kind = kind(of: session) else { continue }
            let key = StatisticsTime.dayKey(for: session.createdAt, calendar: calendar)
            result[key, default: DayCounts()].kinds[kind.rawValue, default: 0] += 1
            if let path = paths[session.projectID], let project = projectName(forPath: path) {
                result[key, default: DayCounts()].projects[project, default: 0] += 1
            }
        }
        return result
    }

    // MARK: - Zählen

    /// Ein neuer Chat ist entstanden. Kehrt sofort zurück.
    func recordLive(_ session: AgentChatSession, projectPath: String) {
        guard session.createdManually == true, let kind = Self.kind(of: session) else { return }
        let project = Self.projectName(forPath: projectPath)
        let key = StatisticsTime.dayKey(for: session.createdAt, calendar: calendar)
        store.update { [self] db in
            // Daten wurden in diesem Lauf gelöscht: Der nächste Start trägt
            // diese Session aus `createdAt` nach — hier zu zählen hieße doppelt.
            if !db.chatsBackfilled, backfillSettled { return }
            db.updateDay(key) { day in
                day.chatsStarted[kind.rawValue, default: 0] += 1
                if let project { day.projectChats[project, default: 0] += 1 }
            }
        }
    }

    /// Trägt einmalig die Chats vor `cutoff` nach. Liest den Workspace erst,
    /// wenn das wirklich nötig ist, und nie auf dem Main-Thread.
    func backfillIfNeeded(before cutoff: Date, workspace: @escaping @Sendable () -> AgentWorkspace) async {
        let current = await store.snapshot()
        if current.chatsBackfilled {
            store.update { [self] _ in backfillSettled = true }
            return
        }
        let counts = Self.backfillCounts(workspace: workspace(), before: cutoff, calendar: calendar)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.update { [self] db in
                defer { continuation.resume() }
                backfillSettled = true
                guard !db.chatsBackfilled else { return }
                for (key, day) in counts {
                    db.updateDay(key) { stats in
                        for (kind, count) in day.kinds { stats.chatsStarted[kind, default: 0] += count }
                        for (project, count) in day.projects { stats.projectChats[project, default: 0] += count }
                    }
                }
                db.chatsBackfilled = true
            }
        }
    }

    private var backfillSettled: Bool {
        get { lock.withLock { backfillSettledThisRun } }
        set { lock.withLock { backfillSettledThisRun = newValue } }
    }
}
