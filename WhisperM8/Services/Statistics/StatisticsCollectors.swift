import Foundation

/// Offen, solange die Statistik zählt. Threadsicher, weil `createSession`
/// nicht an den Main-Thread gebunden ist.
final class StatisticsCollectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openedAt: Date?

    var isOpen: Bool { lock.withLock { openedAt != nil } }

    func open(at date: Date) {
        lock.withLock { openedAt = openedAt ?? date }
    }

    func close() {
        lock.withLock { openedAt = nil }
    }
}

/// Fassade für die Zähler von Zeit, Chats und Diktaten. Startet beim App-Start,
/// folgt dem Schalter „Statistik erfassen“ und bucht beim App-Ende ab.
///
/// Die Einhakstellen in Status-Koordinator, Session-Store und Diktat rufen nur
/// die statischen `note…`-Funktionen; solange nichts gestartet ist (Tests,
/// Test-Instanz, Statistik aus), kehren die sofort zurück.
@MainActor
enum StatisticsCollectors {
    nonisolated static let gate = StatisticsCollectionGate()
    nonisolated static let chats = StatisticsChatCounter(store: .shared)

    private static var registered = false
    private static var activity: StatisticsActivityTracker?
    private static var agents: StatisticsAgentTracker?
    private static var systemEvents: StatisticsSystemEventObserver?

    /// Beim App-Start. Läuft nicht in Test-Instanzen und Unit-Tests.
    static func start() {
        guard !registered, !AppInstance.isTestInstance, NSClassFromString("XCTestCase") == nil else { return }
        registered = true
        StatisticsRuntime.onEnabledChanged { enabled in
            if enabled {
                activate(runningAgents: currentlyWorkingSessions())
            } else {
                deactivate()
            }
        }
        // Beim Start arbeitet noch kein Chat; den Koordinator hier nicht anfassen.
        if StatisticsSettings.isEnabled() { activate(runningAgents: []) }
    }

    /// Beim App-Ende: offene Zeit buchen und die Datei schreiben.
    static func shutdown() {
        deactivate()
        StatisticsStore.shared.flush()
    }

    // MARK: - Einhakstellen

    /// Status-Koordinator: Laufzeitstatus einer Session hat sich geändert.
    static func noteAgentStatus(_ status: AgentSessionRuntimeStatus?, for sessionID: UUID) {
        agents?.setWorking(sessionID, working: status == .working)
    }

    /// `AgentSessionStore.createSession`: ein neuer Chat ist angelegt.
    nonisolated static func noteChatCreated(_ session: AgentChatSession, projectPath: String) {
        guard gate.isOpen else { return }
        chats.recordLive(session, projectPath: projectPath)
    }

    /// Diktat fertig (`saveRunReport`).
    nonisolated static func noteDictation(
        status: TranscriptRunStatus,
        audioDuration: TimeInterval,
        rawText: String?,
        finalText: String?,
        modeName: String
    ) {
        guard gate.isOpen else { return }
        StatisticsDictationRecorder.record(
            status: status,
            audioDuration: audioDuration,
            rawText: rawText,
            finalText: finalText,
            modeName: modeName,
            at: Date(),
            store: .shared
        )
    }

    // MARK: - Intern

    private static func activate(runningAgents: Set<UUID>) {
        guard activity == nil else { return }
        let now = Date()
        gate.open(at: now)

        let activity = StatisticsActivityTracker(store: .shared, environment: .live)
        let agents = StatisticsAgentTracker(store: .shared, environment: .live)
        let observer = StatisticsSystemEventObserver()
        observer.start { event in
            activity.handle(event)
            agents.handle(event)
        }
        activity.start()
        agents.start(workingSessionIDs: runningAgents)
        self.activity = activity
        self.agents = agents
        self.systemEvents = observer

        Task.detached(priority: .utility) {
            await chats.backfillIfNeeded(before: now) { AgentSessionStore().loadWorkspace() }
        }
    }

    private static func deactivate() {
        gate.close()
        systemEvents?.stop()
        activity?.stop()
        agents?.stop()
        systemEvents = nil
        activity = nil
        agents = nil
    }

    private static func currentlyWorkingSessions() -> Set<UUID> {
        let statuses = AgentSessionStatusCoordinator.shared.statusStore.statuses
        return Set(statuses.compactMap { $0.value == .working ? $0.key : nil })
    }
}
