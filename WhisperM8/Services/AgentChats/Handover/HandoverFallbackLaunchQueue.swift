import Foundation

// MARK: - Rückfall der Übernahme: auch unterdrückte Grid-Panes starten

/// Chats, die der Rückfall der Übernahme fortsetzen will (Befund 3, Dex).
///
/// Im Grid startet sonst nur die Fokus-Pane einen vorgemerkten Chat
/// (`suppressesAutoActivation`, Plan F9); nach einem Rückfall blieben gerade
/// die Chats stehen, die der Neustart retten sollte. Nur Chats aus dieser
/// Warteschlange dürfen deshalb auch in einer unterdrückten Pane starten,
/// nacheinander mit kurzem Abstand. Absturz-Wiederaufnahme, Preset-Wechsel und
/// normales Öffnen eines Grids füllen sie nie und bleiben, wie sie sind.
@MainActor
final class HandoverFallbackLaunchQueue {
    static let shared = HandoverFallbackLaunchQueue()

    private let now: () -> Date
    /// Abstand zwischen zwei Starts.
    let spacing: TimeInterval
    /// Danach zählt ein Eintrag nicht mehr (Pane erst viel später geöffnet).
    let lifetime: TimeInterval
    private var queued: [UUID: Date] = [:]
    /// Hinweise aus dem Rückfall für das Meldungsbanner (Punkt 11).
    fileprivate var notices: [UUID: String] = [:]
    private var nextSlot = Date.distantPast
    /// In diesem Start zum Fortsetzen vorgemerkt (der Rückfall kommt in zwei
    /// Schüben); zählt für den Sammelstart-Planer wie ein laufender Chat.
    private(set) var scheduledThisLaunch: Set<UUID> = []

    init(now: @escaping () -> Date = Date.init, spacing: TimeInterval = 0.5, lifetime: TimeInterval = 300) {
        self.now = now
        self.spacing = spacing
        self.lifetime = lifetime
    }

    func schedule(_ ids: [UUID]) {
        let at = now()
        for id in ids {
            queued[id] = at
            scheduledThisLaunch.insert(id)
        }
    }

    /// Verzögerung für den Start einer unterdrückten Pane, oder `nil`, wenn
    /// der Chat nicht (mehr) vom Rückfall vorgemerkt ist. Jeder Eintrag gilt
    /// genau einmal.
    func takeLaunchSlot(for id: UUID) -> TimeInterval? {
        guard let at = queued.removeValue(forKey: id) else { return nil }
        let current = now()
        guard current.timeIntervalSince(at) < lifetime else { return nil }
        let start = max(current, nextSlot)
        nextSlot = start.addingTimeInterval(spacing)
        return start.timeIntervalSince(current)
    }

    /// Der Chat startete auf anderem Weg (Fokus-Pane, Tab): Eintrag verwerfen.
    func forget(_ id: UUID) {
        queued[id] = nil
    }
}

// MARK: - Rückfall für Chats ohne Sitzungs-ID (Punkt 11)

/// Was der Rückfall der Übernahme mit einem Chat tut (Entscheidung Jarvis,
/// 13.11.2026). Ein gestarteter Chat ohne gebundene Sitzungs-ID lässt sich
/// nicht fortsetzen (`missingExternalSessionID`). Hatte er nachweislich noch
/// keinen Turn, ist nichts zu verlieren: frisch starten. Hatte er Turns,
/// bliebe sein Verlauf ohne Tab: gestoppt lassen. Beides mit Hinweis.
/// Nur im Rückfall der Übernahme; normaler Resume-Weg und
/// Absturz-Wiederaufnahme bleiben unverändert.
enum HandoverFallbackStart: Equatable {
    case resume
    case startFresh
    case keepStopped

    static func decide(for session: AgentChatSession, hadTurn: Bool, claudeRecoverable: Bool) -> HandoverFallbackStart {
        let hasID = !(session.externalSessionID?.isEmpty ?? true)
        guard session.hasLaunchedInitialPrompt, !hasID, !session.isTerminal else { return .resume }
        // Claude-Fork setzt von der Quelle fort; ein Claude-Chat, dessen
        // Hook-Ereignisse die Sitzung nennen, wird über sie fortgesetzt.
        if session.provider == .claude,
           claudeRecoverable || !(session.forkSourceSessionID?.isEmpty ?? true) {
            return .resume
        }
        return hadTurn ? .keepStopped : .startFresh
    }

    /// Unabhängiger Beleg (Vic, 13.11.2026): Die drei Quellen unten hängen an
    /// derselben Status-Mechanik, die für Chats ohne ID teilweise blind ist
    /// (Codex hat keine Hook-Datei). Liegt im Projektordner ein ungebundener
    /// Verlauf desselben Anbieters, der nach dem Anlegen des Chats entstand,
    /// könnte es seiner sein: dann gestoppt lassen. Im Zweifel gestoppt; das
    /// kostet einen Klick.
    static func hasUnboundTranscript(
        for session: AgentChatSession,
        projectPath: String,
        indexed: [IndexedAgentSession],
        boundIDs: Set<String>
    ) -> Bool {
        // Claude-Worktrees zählen zum Projekt: canonicalProjectPath schneidet
        // `/.claude/worktrees/<name>` ab.
        let path = AgentSessionStore.canonicalProjectPath(projectPath)
        return indexed.contains {
            guard $0.provider == session.provider,
                  AgentSessionStore.canonicalProjectPath($0.cwd) == path,
                  $0.createdAt >= session.createdAt.addingTimeInterval(-5) else { return false }
            guard boundIDs.contains($0.externalSessionID.lowercased()) else { return true }
            // Altlast (Vic): Die alte Rückfall-Bindung nahm im Fenster um den
            // Start den Verlauf eines Nachbarn. Ein an einen anderen Chat
            // gebundener Verlauf aus diesem Fenster könnte unserer sein.
            return abs($0.createdAt.timeIntervalSince(session.createdAt)) <= misboundWindow
        }
    }

    /// Fenster um das Anlegen des Chats, in dem eine Fehlbindung möglich war.
    static let misboundWindow: TimeInterval = 60

    /// Nachweis eines Turns: `lastTurnAt`, ein Übergang nach „working“ im
    /// Status-Journal oder `UserPromptSubmit` in der Hook-Ereignisdatei.
    static func hadTurn(_ session: AgentChatSession, journal: [ChatsStatusJournalEntry], hookEvents: Data?) -> Bool {
        if session.lastTurnAt != nil { return true }
        if journal.contains(where: { $0.to == "working" }) { return true }
        if let hookEvents, hookEvents.range(of: Data("UserPromptSubmit".utf8)) != nil { return true }
        return false
    }

    var notice: String? {
        switch self {
        case .resume:
            return nil
        case .startFresh:
            return String(localized: "Restarted as a new session after the restart: this chat had no session to continue yet. A prompt it was started with is not sent again.")
        case .keepStopped:
            return String(localized: "Not continued after the restart: this chat has no bound session ID yet, although it already had turns. Its history is kept; start it again once the session is bound, or start a new chat.")
        }
    }
}

extension HandoverFallbackLaunchQueue {
    /// Hinweis für das Meldungsbanner der Chat-Ansicht, genau einmal.
    func takeNotice(for id: UUID) -> String? {
        notices.removeValue(forKey: id)
    }

    func setNotice(_ text: String, for id: UUID) {
        notices[id] = text
        // Schon angezeigte Ansichten holen den Hinweis sofort ab.
        NotificationCenter.default.post(name: Self.noticeDidChange, object: id)
    }

    static let noticeDidChange = Notification.Name("HandoverFallbackLaunchQueue.noticeDidChange")
}
