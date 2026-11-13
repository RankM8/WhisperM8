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

/// Beobachtet den Schalter `statisticsEnabled` in den UserDefaults, auch
/// Änderungen von außen (`defaults write … statisticsEnabled -bool NO`), die
/// KVO auf `UserDefaults` prozessübergreifend meldet. Mehrere Meldungen kurz
/// hintereinander fasst er zusammen und gibt nur einen echten Wechsel weiter.
final class StatisticsEnabledObserver: NSObject {
    private let defaults: UserDefaults
    private let debounce: TimeInterval
    private let onChange: @MainActor (Bool) -> Void
    private var observing = false
    /// Nur auf dem Main-Thread benutzt.
    private var pending: DispatchWorkItem?
    private var lastValue: Bool

    init(
        defaults: UserDefaults = .standard,
        debounce: TimeInterval = 0.3,
        onChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.defaults = defaults
        self.debounce = debounce
        self.onChange = onChange
        self.lastValue = StatisticsSettings.isEnabled(defaults)
        super.init()
    }

    func start() {
        guard !observing else { return }
        observing = true
        defaults.addObserver(self, forKeyPath: StatisticsPreferenceKeys.enabled, options: [], context: nil)
    }

    func stop() {
        guard observing else { return }
        observing = false
        defaults.removeObserver(self, forKeyPath: StatisticsPreferenceKeys.enabled)
        DispatchQueue.main.async { [weak self] in self?.pending?.cancel() }
    }

    deinit {
        if observing { defaults.removeObserver(self, forKeyPath: StatisticsPreferenceKeys.enabled) }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == StatisticsPreferenceKeys.enabled else { return }
        // KVO meldet auf dem Thread der Änderung; gesammelt wird auf Main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.deliver() }
            }
            self.pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounce, execute: item)
        }
    }

    @MainActor
    private func deliver() {
        let value = StatisticsSettings.isEnabled(defaults)
        guard value != lastValue else { return }
        lastValue = value
        onChange(value)
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
    /// Übernommene Chats, die beim Neustart arbeiteten (Zeitpunkt der Abgabe).
    /// Die Übernahme läuft vor dem Start der Statistik; `activate` holt sie ab.
    private static var handedOverWork: [UUID: Date] = [:]
    private static var systemEvents: StatisticsSystemEventObserver?
    private static var enabledObserver: StatisticsEnabledObserver?

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
        // Hintergrund-Dienste: Protokolle (Token, Subagents, Codex-Limits),
        // Limit-Verlauf der Konten und Git. Jeder folgt selbst dem Schalter.
        StatisticsLogScanner.shared.start()
        StatisticsLimitCollector.shared.start()
        StatisticsGitCollector.shared.start()
        refreshExchangeRateIfEnabled()
        StatisticsRuntime.onEnabledChanged { enabled in
            if enabled { refreshExchangeRateIfEnabled() }
        }
        // Notbremse ohne Neustart: `defaults write` wirkt sofort, nicht erst
        // beim nächsten Start oder wenn die Seite offen ist.
        StatisticsRuntime.setInitialEnabled(StatisticsSettings.isEnabled())
        let observer = StatisticsEnabledObserver { StatisticsRuntime.notifyEnabledChanged($0) }
        observer.start()
        enabledObserver = observer
    }

    /// EZB-Kurs höchstens einmal am Tag, im Hintergrund.
    private static func refreshExchangeRateIfEnabled() {
        guard StatisticsSettings.isEnabled() else { return }
        Task.detached(priority: .background) {
            await StatisticsExchangeRate.refreshIfNeeded()
        }
    }

    /// Beim App-Ende: offene Zeit buchen und die Datei schreiben.
    static func shutdown() {
        guard registered else { return }
        enabledObserver?.stop()
        enabledObserver = nil
        StatisticsLogScanner.shared.stop()
        StatisticsLimitCollector.shared.stop()
        StatisticsGitCollector.shared.stop()
        deactivate()
        StatisticsStore.shared.flush()
    }

    // MARK: - Einhakstellen

    /// Status-Koordinator: Laufzeitstatus einer Session hat sich geändert.
    /// Neustart ohne Chatverlust: Der Chat arbeitete bei der Abgabe; gezählt
    /// wird ab `since`, nicht erst ab dem nächsten Statuswechsel.
    static func noteHandedOverWork(since: Date, for sessionID: UUID) {
        if let agents {
            agents.setWorking(sessionID, working: true)
        } else {
            handedOverWork[sessionID] = since
        }
    }

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
        agents.start(workingSessionIDs: runningAgents, workingSince: handedOverWork)
        handedOverWork = [:]
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
