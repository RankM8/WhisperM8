import Foundation

/// Tracking-Eintrag pro lokalem WhisperM8-Tab. Beschreibt den
/// Beobachtungszustand fuer das interaktive `/resume`-Detection:
/// welches Projekt-CWD, welche externe Session-ID gilt aktuell, seit wann
/// wird beobachtet.
struct ClaudeActiveSessionTrackerEntry: Equatable {
    let localSessionID: UUID
    let projectCwd: String
    var currentExternalID: String?
    let launchedAt: Date
}

/// Ergebnis eines Tracker-Ticks. Pure Daten, ohne Side Effects — wird vom
/// Tracker an den Aufrufer durchgereicht, der dann entscheidet, ob
/// `setExternalSessionID` aufgerufen oder ein UI-Picker gezeigt wird.
enum ClaudeActiveSessionDecision: Equatable {
    /// Keine relevante Aenderung erkannt.
    case unchanged
    /// Eindeutiger Kandidat — sicher zum Rebinden.
    case rebind(newExternalID: String, title: String?)
    /// Mehrere Kandidaten — der Aufrufer soll den Picker zeigen (Phase 6).
    case ambiguous(candidates: [IndexedAgentSession])
}

/// Pure, testbare Entscheidungs-Logik fuer den Tracker. Nimmt eine Liste
/// aller Claude-Sessions im Projekt-CWD + den aktuellen Tracking-Entry und
/// liefert die `ClaudeActiveSessionDecision`. Keine FS-Zugriffe, keine Zeit.
enum ClaudeActiveSessionResolver {
    /// `now` ist parametrisiert fuer Tests. `recentWindow` definiert, wie
    /// frisch eine Datei sein muss, um als Kandidat zu zaehlen — wir
    /// beruecksichtigen nur Sessions, die sich seit Launch des lokalen
    /// Tabs (oder spaeter) modifiziert haben.
    static func decide(
        entry: ClaudeActiveSessionTrackerEntry,
        indexedSessions: [IndexedAgentSession],
        now: Date = Date()
    ) -> ClaudeActiveSessionDecision {
        // Nur Claude-Sessions des Projekt-CWDs. Worktree/subagent filtert der
        // Indexer bereits weg.
        let canonical = AgentSessionStore.canonicalProjectPath(entry.projectCwd)
        let projectSessions = indexedSessions.filter { indexed in
            indexed.provider == .claude
                && AgentSessionStore.canonicalProjectPath(indexed.cwd) == canonical
        }

        // Kandidaten = Sessions, die NICHT die aktuell gebundene ID sind,
        // aber seit Launch des Tabs Aktivitaet hatten. Wir geben einen
        // 5-Sekunden-Slack vor `launchedAt` weil das Filesystem-mtime
        // gelegentlich ein paar Hundert Millisekunden hinterherhinkt.
        let launchedThreshold = entry.launchedAt.addingTimeInterval(-5)
        let candidates = projectSessions.filter { indexed in
            indexed.externalSessionID != entry.currentExternalID
                && indexed.lastActivityAt >= launchedThreshold
        }

        guard !candidates.isEmpty else {
            return .unchanged
        }

        // Wir betrachten die zeitlich juengste Aktivitaet als wahrscheinlichsten
        // Resume-Kandidaten. Nur wenn EIN Kandidat klar dominiert (Aktivitaet
        // mindestens 2 Sekunden frischer als alle anderen), rebinden wir
        // automatisch. Sonst → ambiguous-Picker.
        let sorted = candidates.sorted { $0.lastActivityAt > $1.lastActivityAt }
        if sorted.count == 1 {
            let pick = sorted[0]
            return .rebind(newExternalID: pick.externalSessionID, title: pick.title)
        }
        let leader = sorted[0]
        let runner = sorted[1]
        let gap = leader.lastActivityAt.timeIntervalSince(runner.lastActivityAt)
        if gap >= 2.0 {
            return .rebind(newExternalID: leader.externalSessionID, title: leader.title)
        }
        return .ambiguous(candidates: sorted)
    }
}

/// Periodischer Watcher der Claude-Transcript-Dateien fuer interaktives
/// `/resume`-Detection. Wenn der Nutzer in einer laufenden Claude-Session
/// innerhalb der TUI `/resume <other>` tippt, wechselt Claude im selben
/// Prozess auf eine andere Conversation-ID. Hooks (Phase 5) sind der schnelle
/// Pfad — dieser Tracker ist der unabhaengige Fallback und funktioniert auch
/// fuer User ohne Hook-Setup.
@MainActor
final class ClaudeActiveSessionTracker {
    typealias DecisionHandler = (UUID, ClaudeActiveSessionDecision) -> Void

    private let pollInterval: TimeInterval
    private let indexerProvider: () -> [IndexedAgentSession]
    private var entries: [UUID: ClaudeActiveSessionTrackerEntry] = [:]
    private var timer: Timer?
    private var decisionHandler: DecisionHandler?

    init(
        pollInterval: TimeInterval = 1.5,
        indexerProvider: @escaping () -> [IndexedAgentSession] = {
            ClaudeSessionIndexer().indexedSessions(limit: 200)
        }
    ) {
        self.pollInterval = pollInterval
        self.indexerProvider = indexerProvider
    }

    /// Setzt den globalen Decision-Handler. Wird vom AgentChatsView in
    /// `onAppear` einmal gesetzt und reagiert auf alle getrackten Tabs.
    func setDecisionHandler(_ handler: @escaping DecisionHandler) {
        self.decisionHandler = handler
    }

    /// Startet das Tracking fuer eine Session. Idempotent: erneutes Track
    /// fuer dieselbe `localID` ueberschreibt den Entry (Launch-Zeitpunkt
    /// reset, currentExternalID aktualisiert).
    func startTracking(
        localSessionID: UUID,
        projectCwd: String,
        currentExternalID: String?
    ) {
        let entry = ClaudeActiveSessionTrackerEntry(
            localSessionID: localSessionID,
            projectCwd: projectCwd,
            currentExternalID: currentExternalID,
            launchedAt: Date()
        )
        entries[localSessionID] = entry
        ensureTimerRunning()
    }

    /// Wird aufgerufen, wenn der Aufrufer die externalSessionID nach einem
    /// `rebind` selbst aktualisiert hat — damit wir die neue ID als
    /// "current" merken und nicht erneut darauf wechseln.
    func updateBoundExternalID(localSessionID: UUID, externalID: String?) {
        guard var entry = entries[localSessionID] else { return }
        entry.currentExternalID = externalID
        entries[localSessionID] = entry
    }

    /// Stoppt das Tracking fuer eine Session. Wenn keine Entries mehr da
    /// sind, wird auch der Timer beendet.
    func stopTracking(localSessionID: UUID) {
        entries.removeValue(forKey: localSessionID)
        if entries.isEmpty {
            stopTimer()
        }
    }

    // MARK: - Internals

    private func ensureTimerRunning() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !entries.isEmpty else { return }
        let indexed = indexerProvider()
        for (localID, entry) in entries {
            let decision = ClaudeActiveSessionResolver.decide(
                entry: entry,
                indexedSessions: indexed
            )
            switch decision {
            case .unchanged:
                continue
            case .rebind(let newID, _):
                Logger.claudeBinding.info("binding_transcript_match localID=\(localID.uuidString, privacy: .public) newID=\(newID, privacy: .public)")
                decisionHandler?(localID, decision)
            case .ambiguous(let candidates):
                Logger.claudeBinding.info("binding_ambiguous localID=\(localID.uuidString, privacy: .public) count=\(candidates.count)")
                decisionHandler?(localID, decision)
            }
        }
    }
}
