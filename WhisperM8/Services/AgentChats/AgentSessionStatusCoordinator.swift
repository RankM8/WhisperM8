import Foundation

/// Snapshot der statusrelevanten Einstellungen — als Seam injizierbar, damit
/// Koordinator-Tests ohne UserDefaults laufen.
struct AgentStatusPreferences {
    var hooksEnabled: Bool
    var stopNotificationEnabled: Bool
    var awaitingNotificationEnabled: Bool
    var stopSoundEnabled: Bool
    var stopSoundName: String

    static func current() -> AgentStatusPreferences {
        let prefs = AppPreferences.shared
        return AgentStatusPreferences(
            hooksEnabled: prefs.isClaudeHooksEnabled,
            stopNotificationEnabled: prefs.isAgentStopNotificationEnabled,
            awaitingNotificationEnabled: prefs.isAgentAwaitingNotificationEnabled,
            stopSoundEnabled: prefs.isAgentStopSoundEnabled,
            stopSoundName: prefs.agentStopSoundName
        )
    }
}

/// App-weiter Besitzer des Session-Status: konsumiert Hook-Events,
/// Transcript-Entscheidungen und Prozess-Lifecycle, führt sie durch die pure
/// `AgentSessionStateMachine` und schreibt als EINZIGER in den
/// `AgentSessionRuntimeStatusStore`. Effekte (Notification, Ton, Auto-Naming)
/// entstehen ausschließlich aus Zustandswechseln — dadurch sind sie
/// dedupliziert, egal ob Stop-Hook und Transcript-Decider beide feuern.
///
/// Bewusst ein Singleton statt per-Fenster-`@State` (der frühere Zuschnitt):
/// Fenster sind reine Konsumenten. Damit zeigen alle Fenster denselben
/// Status, und ein geschlossenes Ursprungsfenster reißt das Tracking nicht
/// mehr ab (PTYs leben in der globalen `AgentTerminalRegistry` weiter).
@MainActor
final class AgentSessionStatusCoordinator {
    static let shared = AgentSessionStatusCoordinator()

    /// Wartezeit nach dem Launch, bis wir ohne `SessionStart`-Hook degradiert
    /// auf `ready` gehen (Hooks stumm/deaktiviert).
    nonisolated static let defaultLaunchGraceSeconds: TimeInterval = 6

    let statusStore = AgentSessionRuntimeStatusStore()
    let hookBridge: ClaudeHookBridge
    let autoNamer: AgentSessionAutoNamer

    private let store: AgentSessionStore
    private let watcher: AgentSessionRuntimeWatcher
    private let notificationPoster: AgentUserNotificationPosting
    private let playSound: (String) -> Void
    private let loadPreferences: () -> AgentStatusPreferences
    private let launchGraceSeconds: TimeInterval

    /// Registry-Update beim SessionStart-Binding — als Property austauschbar,
    /// damit Tests keine echte Terminal-Registry brauchen.
    var terminalExternalIDUpdater: (UUID, String) -> Void = { sessionID, externalID in
        AgentTerminalRegistry.shared.controller(for: sessionID)?.updateExternalSessionID(externalID)
    }

    private(set) var states: [UUID: AgentSessionLifecycleState] = [:]
    private var notificationThrottle = AgentNotificationThrottle()
    private var launchGraceTasks: [UUID: Task<Void, Never>] = [:]

    init(
        store: AgentSessionStore = AgentSessionStore(),
        hookBridge: ClaudeHookBridge? = nil,
        notificationPoster: AgentUserNotificationPosting = UNAgentUserNotificationPoster(),
        playSound: @escaping (String) -> Void = { SystemSoundCatalog.play($0) },
        loadPreferences: @escaping () -> AgentStatusPreferences = { AgentStatusPreferences.current() },
        launchGraceSeconds: TimeInterval = AgentSessionStatusCoordinator.defaultLaunchGraceSeconds
    ) {
        self.store = store
        self.hookBridge = hookBridge ?? ClaudeHookBridge()
        self.notificationPoster = notificationPoster
        self.playSound = playSound
        self.loadPreferences = loadPreferences
        self.launchGraceSeconds = launchGraceSeconds
        self.autoNamer = AgentSessionAutoNamer(store: store)
        self.watcher = AgentSessionRuntimeWatcher()

        self.hookBridge.setDecisionHandler { [weak self] localID, event in
            self?.handleHookEvent(localID: localID, event: event)
        }
        watcher.onDecision = { [weak self] sessionID, decision in
            self?.handleTranscriptDecision(sessionID: sessionID, decision: decision)
        }
    }

    // MARK: - Lifecycle-API (von den Views gerufen)

    /// `--settings <path>` für einen interaktiven Claude-Launch — leer, wenn
    /// Hooks deaktiviert sind (Launch läuft dann ohne Bridge, Status kommt
    /// aus dem Transcript-Watcher).
    func prepareLaunchArguments(localSessionID: UUID) -> [String] {
        guard loadPreferences().hooksEnabled else { return [] }
        return hookBridge.prepareLaunch(localSessionID: localSessionID)
    }

    /// Settings-Pfad für den `claude --bg`-Spawn (Background-Agents).
    func prepareBackgroundSettingsFile(localSessionID: UUID) -> String? {
        guard loadPreferences().hooksEnabled else { return nil }
        return hookBridge.prepareSettingsFile(localSessionID: localSessionID)
    }

    /// Beginnt das Event-File-Tracking nach erfolgtem Launch/Spawn.
    func hookLaunchDidStart(sessionID: UUID) {
        guard loadPreferences().hooksEnabled else { return }
        hookBridge.startTracking(localSessionID: sessionID)
    }

    /// Prozess (PTY/Spawn) wurde gestartet: Zustand `launching`, Transcript-
    /// Watch anhängen, Grace-Timer für stumme Hooks armieren.
    func sessionLaunched(sessionID: UUID) {
        apply(.processLaunched, to: sessionID)
        attachWatch(sessionID: sessionID)
        scheduleLaunchGrace(sessionID: sessionID)
    }

    /// Externe Session-ID wurde (nach)gebunden — Watch mit frischer ID.
    func externalSessionIDBound(sessionID: UUID) {
        attachWatch(sessionID: sessionID)
    }

    func sessionTerminated(sessionID: UUID, exitCode: Int32?) {
        cancelLaunchGrace(sessionID: sessionID)
        apply(.processTerminated(exitCode: exitCode), to: sessionID)
        watcher.markTerminated(sessionID: sessionID)
        hookBridge.stopTracking(localSessionID: sessionID)
    }

    /// Aktueller Lebenszyklus-Zustand (für Settings-Diagnose/Tests).
    func lifecycleState(for sessionID: UUID) -> AgentSessionLifecycleState? {
        states[sessionID]
    }

    // MARK: - Signal-Quellen

    /// Hook-Event aus der Bridge. `SessionStart` bindet zusätzlich die
    /// externe Session-ID an die lokale Session (bisher in
    /// `AgentChatsView.handleClaudeHookEvent`).
    func handleHookEvent(localID: UUID, event: ClaudeHookEvent) {
        if event.hookEventName == .sessionStart {
            bindExternalSessionID(localID: localID, event: event)
        }
        if event.hookEventName == .sessionEnd {
            let reason = event.reason ?? "unknown"
            Logger.claudeBinding.info("binding_session_end localID=\(localID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
        }
        guard let signal = AgentSessionSignal(hookEvent: event) else { return }
        apply(signal, to: localID)
    }

    /// Transcript-Watcher-Entscheidung. `turnFinished` stößt zusätzlich das
    /// bestehende Bookkeeping an (Auto-Naming + `lastTurnAt`) — bewusst am
    /// Decider-Pfad belassen: erst wenn das Transkript das Turn-Ende zeigt,
    /// ist es vollständig genug für den Auto-Namer.
    func handleTranscriptDecision(sessionID: UUID, decision: AgentTranscriptStatusDecider.Decision) {
        switch decision.status {
        case .idle:
            apply(.transcriptIdle(turnFinished: decision.turnFinished), to: sessionID)
        case .working, .awaitingInput:
            apply(.transcriptActivity, to: sessionID)
        case .stopped, .errored:
            return // liefert der Decider nicht — defensiv ignorieren
        }
        if decision.turnFinished {
            performTurnFinishedBookkeeping(sessionID: sessionID)
        }
    }

    // MARK: - State-Machine-Anbindung

    private func apply(_ signal: AgentSessionSignal, to sessionID: UUID) {
        let oldState = states[sessionID] ?? .created
        let transition = AgentSessionStateMachine.reduce(state: oldState, signal: signal)
        states[sessionID] = transition.state

        if let status = transition.state.runtimeStatus {
            statusStore.setStatus(status, for: sessionID)
        } else {
            statusStore.clear(sessionID: sessionID)
        }

        for effect in transition.effects {
            perform(effect, sessionID: sessionID)
        }
    }

    private func perform(_ effect: AgentSessionEffect, sessionID: UUID) {
        let preferences = loadPreferences()
        switch effect {
        case .turnCompleted:
            if preferences.stopSoundEnabled {
                playSound(preferences.stopSoundName)
            }
            if preferences.stopNotificationEnabled {
                postNotification(kind: .turnCompleted, sessionID: sessionID)
            }
        case .inputRequested(let reason):
            if preferences.awaitingNotificationEnabled {
                postNotification(kind: .inputRequested(reason), sessionID: sessionID)
            }
        }
    }

    private func postNotification(kind: AgentSessionUserNotification.Kind, sessionID: UUID) {
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else { return }
        let project = workspace.projects.first(where: { $0.id == session.projectID })
        let notification = AgentSessionUserNotification(
            kind: kind,
            localSessionID: sessionID,
            title: session.title,
            projectName: project?.name
        )
        guard notificationThrottle.shouldPost(notification, now: Date()) else { return }
        notificationPoster.post(notification)
    }

    // MARK: - Watch/Binding-Helfer

    /// Hängt den Transcript-Watcher an (idempotent) — vormals
    /// `AgentChatsView.attachWatcher`.
    private func attachWatch(sessionID: UUID) {
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }
        watcher.watch(
            sessionID: session.id,
            provider: session.provider,
            externalSessionID: session.externalSessionID,
            cwd: project.path,
            priorTurnFinishedAt: session.lastTurnAt
        )
    }

    private func bindExternalSessionID(localID: UUID, event: ClaudeHookEvent) {
        guard let newID = event.sessionID, !newID.isEmpty else { return }
        do {
            var didChange = false
            try store.updateSession(id: localID) { session in
                let old = session.externalSessionID
                guard old != newID else { return }
                session.externalSessionID = newID
                didChange = true
                Logger.claudeBinding.info("binding_launch_id_set localID=\(localID.uuidString, privacy: .public) old=\(old ?? "nil", privacy: .public) new=\(newID, privacy: .public)")
            }
            if didChange {
                terminalExternalIDUpdater(localID, newID)
                attachWatch(sessionID: localID)
            }
        } catch {
            Logger.claudeBinding.warning("binding_launch_set_failed localID=\(localID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persistiert `lastTurnAt` und stößt den Auto-Namer an — vormals
    /// `AgentChatsView.handleTurnFinished`.
    private func performTurnFinishedBookkeeping(sessionID: UUID) {
        let workspace = store.loadWorkspace()
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            return
        }

        autoNamer.handleTurnFinished(session: session, cwd: project.path) { _ in }

        do {
            try store.recordTurnEnded(id: sessionID)
        } catch {
            Logger.debug("Failed to record turn ended: \(error.localizedDescription)")
        }
    }

    // MARK: - Launch-Grace (stumme Hooks)

    private func scheduleLaunchGrace(sessionID: UUID) {
        cancelLaunchGrace(sessionID: sessionID)
        let seconds = launchGraceSeconds
        launchGraceTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Reducer neutralisiert das Signal, falls längst nicht mehr
            // `launching` — kein Zustands-Check nötig.
            self?.apply(.launchGraceExpired, to: sessionID)
            self?.launchGraceTasks[sessionID] = nil
        }
    }

    private func cancelLaunchGrace(sessionID: UUID) {
        launchGraceTasks[sessionID]?.cancel()
        launchGraceTasks[sessionID] = nil
    }
}
